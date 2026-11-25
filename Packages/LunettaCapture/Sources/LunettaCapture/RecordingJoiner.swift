import AVFoundation
import Foundation

/// Pausing ends one SCStream recording and resuming starts the next, so a paused recording arrives as parts.
/// Passthrough copies the encoded samples back to back without re-encoding them.
public enum RecordingJoiner {
    public static func join(_ parts: [URL], into url: URL) async throws {
        do {
            let composition = AVMutableComposition()
            var tracks: [String: AVMutableCompositionTrack] = [:]
            var cursor = CMTime.zero
            for part in parts {
                let asset = AVURLAsset(url: part)
                let partRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
                for mediaType in [AVMediaType.video, .audio] {
                    for (index, source) in try await asset.loadTracks(withMediaType: mediaType).enumerated() {
                        let key = "\(mediaType.rawValue)-\(index)"
                        guard let track = tracks[key] ?? composition.addMutableTrack(withMediaType: mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                        if tracks[key] == nil, mediaType == .video {
                            track.preferredTransform = try await source.load(.preferredTransform)
                        }
                        tracks[key] = track
                        let range = try await source.load(.timeRange).intersection(partRange)
                        guard !range.isEmpty else { continue }
                        try track.insertTimeRange(range, of: source, at: cursor + range.start)
                    }
                }
                cursor = cursor + partRange.duration
            }
            guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
                throw CaptureError.recordingFailed(path: url.path, reason: "AVFoundation has no passthrough export for these parts")
            }
            try await export.export(to: url, as: .mp4)
        } catch let error as CaptureError {
            throw error
        } catch {
            throw CaptureError.recordingFailed(path: url.path, reason: error.localizedDescription)
        }
    }
}
