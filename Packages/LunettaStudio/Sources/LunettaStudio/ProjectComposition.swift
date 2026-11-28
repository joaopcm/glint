import AVFoundation
import LunettaCore

public struct ProjectComposition {
    public let asset: AVComposition
    public let videoComposition: AVVideoComposition
    public let audioMix: AVAudioMix?
    public let outputSize: PixelSize

    /// Checks every file and value the renderer would otherwise quietly draw without, so a broken project fails here,
    /// naming what's wrong, instead of rendering without its cursor or camera.
    public static func make(project: RecordingProject, folder: URL) async throws(RenderError) -> ProjectComposition {
        do {
            return try await build(project: project, folder: folder)
        } catch let error as RenderError {
            throw error
        } catch {
            throw .readerFailed(error.localizedDescription)
        }
    }

    private static func build(project: RecordingProject, folder: URL) async throws -> ProjectComposition {
        guard SRGBColor(hex: project.overlays.clickColorHex) != nil else {
            throw RenderError.readerFailed("the project's click color \"\(project.overlays.clickColorHex)\" isn't a #RRGGBB color")
        }
        let composition = AVMutableComposition()
        let screenTrack = try addTrack(.video, to: composition)
        var cameraTrack: AVMutableCompositionTrack?
        var audioTracks: [Int: AVMutableCompositionTrack] = [:]
        var sourceSize: PixelSize?
        var logs: [CaptureEventLog] = []
        var partRanges: [(range: CMTimeRange, hasCamera: Bool)] = []
        var partStart = CMTime.zero

        for part in project.parts {
            let screen = try await Media.load(part.screen, in: folder)
            let range = screen.videoRange
            try screen.insert(range, of: screen.video, into: screenTrack, at: partStart)
            sourceSize = sourceSize ?? PixelSize(width: Int(screen.size.width), height: Int(screen.size.height))

            for (index, audio) in screen.audio.enumerated() {
                let heard = audio.range.intersection(range)
                guard !heard.isEmpty else { continue }
                let track = try audioTracks[index] ?? addTrack(.audio, to: composition)
                audioTracks[index] = track
                try screen.insert(heard, of: audio.track, into: track, at: partStart + (heard.start - range.start))
            }

            var hasCamera = false
            if project.overlays.camera, let file = part.camera, let cameraStart = part.cameraStartHostTime {
                let camera = try await Media.load(file, in: folder)
                let offset = CMTime(seconds: cameraStart - part.screenStartHostTime, preferredTimescale: camera.timeScale)
                let shown = CMTimeRange(start: offset, duration: camera.videoRange.duration)
                    .intersection(CMTimeRange(start: .zero, duration: range.duration))
                if !shown.isEmpty {
                    let track = try cameraTrack ?? addTrack(.video, to: composition)
                    cameraTrack = track
                    try camera.insert(
                        CMTimeRange(start: camera.videoRange.start + shown.start - offset, duration: shown.duration),
                        of: camera.video,
                        into: track,
                        at: partStart + shown.start
                    )
                    hasCamera = true
                }
            }

            logs.append(try events(part.events, in: folder))
            partRanges.append((CMTimeRange(start: partStart, duration: range.duration), hasCamera))
            partStart = partStart + range.duration
        }

        let cursors = CursorImageLibrary(folder: folder.appending(path: "cursors"))
        let cursorNames = logs.reduce(into: Set<String>()) { $0.formUnion($1.cursorImageNames) }
        for name in cursorNames.sorted() where cursors.image(named: name) == nil {
            throw RenderError.missingMedia(file: "cursors/\(name)")
        }

        guard let source = sourceSize else { throw RenderError.readerFailed("the project has no recorded parts") }
        let output = RenderSize.output(for: source, capsToUHD: project.output.capsToUHD)
        let renderer = StudioFrameRenderer(project: project, logs: logs, cursors: cursors, sourceSize: source, outputSize: output)
        let timeline = ProjectTimeline(project: project, partDurations: partRanges.map(\.range.duration.seconds))
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = StudioCompositor.self
        videoComposition.renderSize = CGSize(width: output.width, height: output.height)
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(project.output.frameRate.rawValue))
        videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        videoComposition.instructions = partRanges.map { part in
            StudioInstruction(
                timeRange: part.range,
                screenTrackID: screenTrack.trackID,
                cameraTrackID: part.hasCamera ? cameraTrack?.trackID : nil,
                renderer: renderer,
                timeline: timeline
            )
        }
        return ProjectComposition(asset: composition, videoComposition: videoComposition, audioMix: nil, outputSize: output)
    }

    private static func addTrack(_ type: AVMediaType, to composition: AVMutableComposition) throws -> AVMutableCompositionTrack {
        guard let track = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RenderError.readerFailed("AVFoundation couldn't add a \(type.rawValue) track to the composition")
        }
        return track
    }

    private static func events(_ file: String, in folder: URL) throws -> CaptureEventLog {
        let url = folder.appending(path: file)
        guard FileManager.default.fileExists(atPath: url.path) else { throw RenderError.missingMedia(file: file) }
        do {
            return CaptureEventLog.read(jsonLines: try Data(contentsOf: url))
        } catch {
            throw RenderError.readerFailed("\(file): \(error.localizedDescription)")
        }
    }
}

private struct Media {
    let asset: AVURLAsset
    let video: AVAssetTrack
    let videoRange: CMTimeRange
    let size: CGSize
    let timeScale: CMTimeScale
    let audio: [(track: AVAssetTrack, range: CMTimeRange)]

    static func load(_ file: String, in folder: URL) async throws -> Media {
        let url = folder.appending(path: file)
        guard FileManager.default.fileExists(atPath: url.path) else { throw RenderError.missingMedia(file: file) }
        let asset = AVURLAsset(url: url)
        do {
            guard let video = try await asset.loadTracks(withMediaType: .video).first else {
                throw RenderError.readerFailed("\(file) has no video track")
            }
            let (videoRange, size, timeScale) = try await video.load(.timeRange, .naturalSize, .naturalTimeScale)
            var audio: [(track: AVAssetTrack, range: CMTimeRange)] = []
            for track in try await asset.loadTracks(withMediaType: .audio) {
                audio.append((track, try await track.load(.timeRange)))
            }
            return Media(asset: asset, video: video, videoRange: videoRange, size: size, timeScale: timeScale, audio: audio)
        } catch let error as RenderError {
            throw error
        } catch {
            throw RenderError.readerFailed("\(file): \(error.localizedDescription)")
        }
    }

    /// An AVAssetTrack holds its asset weakly, and inserting a track whose asset is gone fails. Inserting through the
    /// Media that owns the asset keeps it alive until the composition has what it needs.
    func insert(_ range: CMTimeRange, of track: AVAssetTrack, into composition: AVMutableCompositionTrack, at time: CMTime) throws {
        try withExtendedLifetime(asset) {
            try composition.insertTimeRange(range, of: track, at: time)
        }
    }
}
