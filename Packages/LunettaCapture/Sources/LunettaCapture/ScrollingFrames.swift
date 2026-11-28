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
    /// Task 0 recorded github-pr (Safari) and notion (Dia) at 1/60 s on Mac16,8, normal scrolling and a fast flick:
    /// every consecutive pair overlapped, largest shift 414 px of 1600 (docs/perf/2026-11-scrolling-capture.md).
    static let scrollingFrameInterval = CMTime(value: 1, timescale: 60)

    public func scrollingFrames(of selection: CGRect, displays: [DisplayInfo]) async throws -> ScrollingFrames {
        try await scrollingFrames(of: selection, displays: displays, frameInterval: Self.scrollingFrameInterval, queueDepth: nil)
    }

    /// `queueDepth` nil keeps ScreenCaptureKit's default, which Task 0's recordings ran with.
    func scrollingFrames(of selection: CGRect, displays: [DisplayInfo], frameInterval: CMTime, queueDepth: Int?) async throws -> ScrollingFrames {
        try Self.requirePermission()
        let (display, area) = try Self.area(of: selection, displays: displays)
        let filter = try await Self.contentFilter(displayID: display.id, hiding: await chromeWindowIDs())
        let configuration = Self.configuration(width: area.width, height: area.height)
        configuration.sourceRect = area.sourceRect
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = frameInterval
        if let queueDepth { configuration.queueDepth = queueDepth }
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
