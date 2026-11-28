import AVFoundation
import LunettaCore
import Synchronization

public enum RenderError: LocalizedError, Equatable {
    case missingMedia(file: String)
    case readerFailed(String)
    case writerFailed(String)
    case overMemoryBudget(limitMB: Int, usedMB: Int, output: PixelSize)

    public var errorDescription: String? {
        switch self {
        case let .missingMedia(file):
            "The recording can't be rendered: \(file) is missing from its project folder."
        case let .readerFailed(reason):
            "Couldn't read the recording to render it: \(reason)"
        case let .writerFailed(reason):
            "Couldn't write the rendered video: \(reason)"
        case let .overMemoryBudget(limitMB, usedMB, output):
            "Rendering this \(output.width)x\(output.height) video used \(usedMB) MB, over the render memory budget of \(limitMB) MB. "
                + "The limit is a tripwire set above the peak measured in docs/perf/2026-11-28-render.md, so no render should reach it. "
                + "Please report this along with the video's size."
        }
    }
}

public enum ProjectExporter {
    private static let framesBetweenBudgetChecks = 30

    public static func export(
        _ composition: ProjectComposition,
        codec: VideoCodec,
        frameRate: RecordingFrameRate,
        to url: URL,
        scratch: URL,
        budget: MemoryBudget,
        progress: @Sendable (Double) -> Void
    ) async throws(RenderError) {
        do throws(RenderError) {
            try await write(composition, codec: codec, frameRate: frameRate, to: scratch, budget: budget, progress: progress)
            try publish(scratch, at: url)
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw error
        }
        progress(1)
    }

    private static func write(
        _ composition: ProjectComposition,
        codec: VideoCodec,
        frameRate: RecordingFrameRate,
        to scratch: URL,
        budget: MemoryBudget,
        progress: @Sendable (Double) -> Void
    ) async throws(RenderError) {
        progress(0)
        let run = try await ExportRun.prepare(composition, codec: codec, frameRate: frameRate, to: scratch, budget: budget)
        let duration = run.duration.seconds
        await withTaskCancellationHandler {
            async let pumped: Void = run.pump()
            for await seconds in run.frameTimes {
                progress(min(1, max(0, seconds / duration)))
            }
            await pumped
        } onCancel: {
            run.stop()
        }
        try await run.finish(cancelled: Task.isCancelled)
    }

    /// Staged on the save folder's volume first: a move across volumes is a copy, and a copy cut short would leave a
    /// half-written video at `url`.
    private static func publish(_ scratch: URL, at url: URL) throws(RenderError) {
        let files = FileManager.default
        do {
            let staging = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
            defer { try? files.removeItem(at: staging) }
            let staged = staging.appending(path: url.lastPathComponent)
            try files.moveItem(at: scratch, to: staged)
            if files.fileExists(atPath: url.path) {
                _ = try files.replaceItemAt(url, withItemAt: staged)
            } else {
                try files.moveItem(at: staged, to: url)
            }
        } catch {
            throw .writerFailed("couldn't move the rendered video to \(url.path): \(error.localizedDescription)")
        }
    }

    /// The reader outputs and writer inputs are each touched only on their pump's queue, or after both pumps finished.
    private final class ExportRun: @unchecked Sendable {
        let duration: CMTime
        let frameTimes: AsyncStream<Double>
        private let frameTimesContinuation: AsyncStream<Double>.Continuation
        private let reader: AVAssetReader
        private let writer: AVAssetWriter
        private let video: Pump
        private let audio: Pump?
        private let budget: MemoryBudget
        private let outputSize: PixelSize
        private let stopped = Atomic(false)
        private let failure = Mutex<RenderError?>(nil)
        private let framesWritten = Atomic(0)

        static func prepare(
            _ composition: ProjectComposition,
            codec: VideoCodec,
            frameRate: RecordingFrameRate,
            to scratch: URL,
            budget: MemoryBudget
        ) async throws(RenderError) -> ExportRun {
            let asset = composition.asset
            let reader: AVAssetReader
            let videoTracks: [AVAssetTrack]
            let audioTracks: [AVAssetTrack]
            let audioFormat: AudioFormat?
            let duration: CMTime
            do {
                reader = try AVAssetReader(asset: asset)
                videoTracks = try await asset.loadTracks(withMediaType: .video)
                audioTracks = try await asset.loadTracks(withMediaType: .audio)
                audioFormat = try await widestFormat(of: audioTracks)
                duration = try await asset.load(.duration)
            } catch {
                throw .readerFailed(error.localizedDescription)
            }
            let writer: AVAssetWriter
            do {
                let files = FileManager.default
                if files.fileExists(atPath: scratch.path) { try files.removeItem(at: scratch) }
                writer = try AVAssetWriter(outputURL: scratch, fileType: .mp4)
            } catch {
                throw .writerFailed(error.localizedDescription)
            }

            let videoComposition = composition.videoComposition.mutableCopy() as! AVMutableVideoComposition
            videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate.rawValue))
            let videoOutput = AVAssetReaderVideoCompositionOutput(
                videoTracks: videoTracks,
                videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            )
            videoOutput.videoComposition = videoComposition
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
                AVVideoWidthKey: composition.outputSize.width,
                AVVideoHeightKey: composition.outputSize.height,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
                AVVideoCompressionPropertiesKey: [AVVideoExpectedSourceFrameRateKey: frameRate.rawValue],
            ])
            let video = try Pump(from: videoOutput, reader: reader, to: videoInput, writer: writer)

            var audio: Pump?
            if let audioFormat {
                let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: audioFormat.settings(kAudioFormatLinearPCM))
                audioOutput.audioMix = composition.audioMix
                let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioFormat.settings(kAudioFormatMPEG4AAC))
                audio = try Pump(from: audioOutput, reader: reader, to: audioInput, writer: writer)
            }

            guard reader.startReading() else { throw .readerFailed(reason(reader.error)) }
            guard writer.startWriting() else { throw .writerFailed(reason(writer.error)) }
            writer.startSession(atSourceTime: .zero)
            return ExportRun(
                duration: duration, reader: reader, writer: writer, video: video, audio: audio, budget: budget, outputSize: composition.outputSize
            )
        }

        private init(duration: CMTime, reader: AVAssetReader, writer: AVAssetWriter, video: Pump, audio: Pump?, budget: MemoryBudget, outputSize: PixelSize) {
            self.duration = duration
            (frameTimes, frameTimesContinuation) = AsyncStream.makeStream(of: Double.self)
            self.reader = reader
            self.writer = writer
            self.video = video
            self.audio = audio
            self.budget = budget
            self.outputSize = outputSize
        }

        func pump() async {
            await withDiscardingTaskGroup { group in
                if let audio {
                    group.addTask { await audio.run { _ in !self.stopped.load(ordering: .relaxed) } }
                }
                await video.run { [self] sample in
                    guard !stopped.load(ordering: .relaxed) else { return false }
                    frameTimesContinuation.yield(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
                    let written = framesWritten.add(1, ordering: .relaxed).newValue
                    guard written % ProjectExporter.framesBetweenBudgetChecks == 0 else { return true }
                    do throws(RenderError) {
                        try budget.check(output: outputSize)
                        return true
                    } catch {
                        fail(error)
                        return false
                    }
                }
                frameTimesContinuation.finish()
            }
        }

        func stop() {
            stopped.store(true, ordering: .relaxed)
        }

        func finish(cancelled: Bool) async throws(RenderError) {
            let error = failure.withLock { $0 } ?? (cancelled ? .writerFailed("cancelled") : nil)
            if let error {
                reader.cancelReading()
                writer.cancelWriting()
                throw error
            }
            guard writer.status == .writing else {
                reader.cancelReading()
                throw .writerFailed(reason(writer.error))
            }
            guard reader.status == .completed else {
                writer.cancelWriting()
                throw .readerFailed(reason(reader.error))
            }
            await writer.finishWriting()
            guard writer.status == .completed else { throw .writerFailed(reason(writer.error)) }
        }

        private func fail(_ error: RenderError) {
            failure.withLock { $0 = $0 ?? error }
            stop()
        }

        private static func widestFormat(of tracks: [AVAssetTrack]) async throws -> AudioFormat? {
            var widest: AudioFormat?
            for track in tracks {
                for description in try await track.load(.formatDescriptions) {
                    guard let format = AudioFormat(description), format.channels > widest?.channels ?? 0 else { continue }
                    widest = format
                }
            }
            return widest
        }
    }

    private final class Pump: @unchecked Sendable {
        private let output: AVAssetReaderOutput
        private let input: AVAssetWriterInput
        private let queue: DispatchQueue
        private let finished = Atomic(false)

        init(from output: AVAssetReaderOutput, reader: AVAssetReader, to input: AVAssetWriterInput, writer: AVAssetWriter) throws(RenderError) {
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw .readerFailed("AVFoundation can't read \(output.mediaType.rawValue) from the composition") }
            reader.add(output)
            guard writer.canAdd(input) else { throw .writerFailed("AVFoundation can't write \(input.mediaType.rawValue) with these settings") }
            writer.add(input)
            self.output = output
            self.input = input
            queue = DispatchQueue(label: "com.joaopcm.lunetta.render.\(output.mediaType.rawValue)")
        }

        func run(while keepGoing: @escaping @Sendable (CMSampleBuffer) -> Bool) async {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                input.requestMediaDataWhenReady(on: queue) { [self] in
                    guard !finished.load(ordering: .relaxed) else { return }
                    while input.isReadyForMoreMediaData {
                        guard let sample = output.copyNextSampleBuffer(), input.append(sample), keepGoing(sample) else {
                            finished.store(true, ordering: .relaxed)
                            input.markAsFinished()
                            done.resume()
                            return
                        }
                    }
                }
            }
        }
    }

    private struct AudioFormat {
        let sampleRate: Double
        let channels: Int
        let layout: Data?

        init?(_ description: CMFormatDescription) {
            guard let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { return nil }
            sampleRate = stream.mSampleRate
            channels = Int(stream.mChannelsPerFrame)
            var layoutSize = 0
            layout = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &layoutSize).map { Data(bytes: $0, count: layoutSize) }
        }

        func settings(_ formatID: AudioFormatID) -> [String: Any] {
            var settings: [String: Any] = [AVFormatIDKey: formatID, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels]
            settings[AVChannelLayoutKey] = layout
            return settings
        }
    }
}

private func reason(_ error: (any Error)?) -> String {
    error?.localizedDescription ?? "AVFoundation gave no reason"
}
