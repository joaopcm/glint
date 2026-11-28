import CoreMedia
import Foundation
import LunettaCore
import ScreenCaptureKit
import Synchronization

public struct ScrollingFrames: Sendable {
    public let frames: AsyncThrowingStream<Frame, any Error>
    public let stop: @Sendable () async -> Void

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
    /// Same sweep at 1/60 s: depth 3 and 8 both had no break while scrolling normally and kept a 16.7 ms median frame
    /// gap; 3 holds fewer 2800x1800 surfaces.
    static let scrollingQueueDepth = 3

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

        let (frames, continuation) = AsyncThrowingStream.makeStream(of: Frame.self)
        let output = ScrollingFrameOutput(continuation: continuation)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        do {
            try await stream.startCapture()
        } catch {
            throw ScrollingFrames.stopError(error)
        }
        let capture = ScrollingCapture(stream: stream, output: output, continuation: continuation)
        continuation.onTermination = { _ in Task { await capture.stop() } }
        return ScrollingFrames(frames: frames, stop: { await capture.stop() })
    }
}

private final class ScrollingCapture: Sendable {
    private let stream: Mutex<SCStream?>
    private let output: ScrollingFrameOutput
    private let continuation: AsyncThrowingStream<Frame, any Error>.Continuation

    init(stream: sending SCStream, output: ScrollingFrameOutput, continuation: AsyncThrowingStream<Frame, any Error>.Continuation) {
        self.stream = Mutex(stream)
        self.output = output
        self.continuation = continuation
    }

    func stop() async {
        guard let stream = self.stream.withLock({ $0.take() }) else { return }
        // Throws when the stream already stopped on its own; didStopWithError has finished the frames with that error.
        try? await stream.stopCapture()
        continuation.finish()
    }
}

private final class ScrollingFrameOutput: NSObject, SCStreamOutput, SCStreamDelegate, Sendable {
    let queue = DispatchQueue(label: "com.joaopcm.lunetta.scrolling-frames")
    private let continuation: AsyncThrowingStream<Frame, any Error>.Continuation

    init(continuation: AsyncThrowingStream<Frame, any Error>.Continuation) {
        self.continuation = continuation
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isCompleteScreenFrame,
              let pixelBuffer = sampleBuffer.imageBuffer, let frame = Frame(pixelBuffer)
        else { return }
        continuation.yield(frame)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        continuation.finish(throwing: ScrollingFrames.stopError(error))
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
