import CoreMedia
import Foundation
import LunettaCore
import OSLog
import ScreenCaptureKit
import Synchronization

public struct ScrollingFrames: Sendable {
    public let frames: AsyncThrowingStream<Frame, any Error>
    public let stop: @Sendable () async -> Void

    public init(frames: AsyncThrowingStream<Frame, any Error>, stop: @escaping @Sendable () async -> Void) {
        self.frames = frames
        self.stop = stop
    }

    static func stopError(_ error: any Error) -> any Error {
        let nsError = error as NSError
        guard nsError.domain == SCStreamErrorDomain, nsError.code == SCStreamError.Code.userDeclined.rawValue else { return error }
        return CaptureError.permissionDenied
    }
}

extension ScreenCapturer {
    /// Task 4 sweep, GitHub PR in Safari, 1400x900 pt area, Mac16,8 + Dell S3225QC @120 Hz: no break while scrolling
    /// normally at 1/120–1/10 s. On a fast flick 1/10 s lost overlap, 1/20 s jumped 1696 of 1800 px, 1/30 s at most 932
    /// (docs/perf/2026-11-scrolling-capture.md).
    static let scrollingFrameInterval = CMTime(value: 1, timescale: 30)
    /// Auto-scrolling page in Safari, same area, 1/30 s: depth 3 and 8 both delivered ~29 fps (33.6–33.9 ms median gap)
    /// with no break at 600, 7000 and 14000 pt/s; 3 holds fewer 2800x1800 surfaces (docs/perf/2026-11-scrolling-capture.md).
    static let scrollingQueueDepth = 3
    /// The sweep's slowest `Stitcher.append` was 108.5 ms; 4 frames arrive at 1/30 s in that time, and 8 is twice that.
    /// Full, it holds 161 MB at 2800x1800 and 651 MB for a whole 6016x3384 display, only while the consumer is behind.
    static let scrollingBufferedFrames = 8

    public func scrollingFrames(of selection: CGRect, displays: [DisplayInfo]) async throws -> ScrollingFrames {
        try await scrollingFrames(of: selection, displays: displays, frameInterval: Self.scrollingFrameInterval, queueDepth: Self.scrollingQueueDepth)
    }

    func scrollingFrames(of selection: CGRect, displays: [DisplayInfo], frameInterval: CMTime, queueDepth: Int) async throws -> ScrollingFrames {
        try Self.requirePermission()
        let (display, area) = try Self.area(of: selection, displays: displays)
        let filter = try await Self.contentFilter(displayID: display.id, hiding: await chromeWindowIDs())
        let configuration = Self.configuration(width: area.width, height: area.height)
        configuration.sourceRect = area.sourceRect
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = frameInterval
        configuration.queueDepth = queueDepth
        // colorSpaceName stays unset: ScreenCaptureKit then tags frames with the display's own color space, the same one
        // captureArea's image carries (probe on a Dell S3225QC, docs/perf/2026-11-scrolling-capture.md).

        let (buffer, frames) = FrameBuffer.make(limit: Self.scrollingBufferedFrames)
        let output = ScrollingFrameOutput(buffer: buffer)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        do {
            try await stream.startCapture()
        } catch {
            throw ScrollingFrames.stopError(error)
        }
        let capture = ScrollingCapture(stream: stream, output: output, buffer: buffer)
        buffer.onTermination { Task { await capture.stop() } }
        return ScrollingFrames(frames: frames, stop: { await capture.stop() })
    }
}

private final class ScrollingCapture: Sendable {
    private let stream: Mutex<SCStream?>
    private let output: ScrollingFrameOutput
    private let buffer: FrameBuffer

    init(stream: sending SCStream, output: ScrollingFrameOutput, buffer: FrameBuffer) {
        self.stream = Mutex(stream)
        self.output = output
        self.buffer = buffer
    }

    func stop() async {
        guard let stream = self.stream.withLock({ $0.take() }) else { return }
        // Throws when the stream already stopped on its own; didStopWithError has finished the frames with that error.
        try? await stream.stopCapture()
        buffer.finish()
    }
}

private final class ScrollingFrameOutput: NSObject, SCStreamOutput, SCStreamDelegate, Sendable {
    let queue = DispatchQueue(label: "com.joaopcm.lunetta.scrolling-frames")
    private let buffer: FrameBuffer

    init(buffer: FrameBuffer) {
        self.buffer = buffer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isCompleteScreenFrame,
              let pixelBuffer = sampleBuffer.imageBuffer, let frame = Frame(pixelBuffer)
        else { return }
        buffer.push(frame)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        buffer.finish(throwing: ScrollingFrames.stopError(error))
    }
}

final class FrameBuffer: Sendable {
    private let continuation: AsyncThrowingStream<Frame, any Error>.Continuation
    private let limit: Int
    private let dropped = Atomic<Int>(0)
    private static let log = Logger(subsystem: "com.joaopcm.lunetta", category: "scrolling-capture")

    private init(limit: Int, continuation: AsyncThrowingStream<Frame, any Error>.Continuation) {
        self.limit = limit
        self.continuation = continuation
    }

    /// The stream is returned rather than kept, so dropping it deinits it and runs `onTermination`.
    static func make(limit: Int) -> (FrameBuffer, AsyncThrowingStream<Frame, any Error>) {
        let (frames, continuation) = AsyncThrowingStream.makeStream(of: Frame.self, bufferingPolicy: .bufferingNewest(limit))
        return (FrameBuffer(limit: limit, continuation: continuation), frames)
    }

    var droppedFrames: Int { dropped.load(ordering: .relaxed) }

    func push(_ frame: Frame) {
        guard case .dropped = continuation.yield(frame) else { return }
        let count = dropped.add(1, ordering: .relaxed).newValue
        Self.log.error(
            "Scrolling capture dropped its oldest frame: the consumer is more than scrollingBufferedFrames=\(self.limit) frames behind (\(count) dropped so far)."
        )
    }

    func finish(throwing error: (any Error)? = nil) {
        continuation.finish(throwing: error)
    }

    func onTermination(_ action: @escaping @Sendable () -> Void) {
        continuation.onTermination = { _ in action() }
    }
}

extension CMSampleBuffer {
    var isCompleteScreenFrame: Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int
        else { return false }
        return SCFrameStatus(rawValue: status) == .complete
    }
}
