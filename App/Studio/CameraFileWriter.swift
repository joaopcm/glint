import AVFoundation

struct CameraTake: Sendable {
    let url: URL
    let startHostTime: Double
}

/// Writes the camera's frames to one H.264 file at the session's 1280x720 preset. The file's clock starts at the first
/// frame, and `startHostTime` says when that was on the host clock, the one ScreenCaptureKit stamps its frames with.
final class CameraFileWriter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    static let size = CGSize(width: 1280, height: 720)

    private let url: URL
    private let clock: CMClock?
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let lock = NSLock()
    private var startHostTime: Double?
    private var finishing = false

    init(url: URL, session: AVCaptureSession) throws {
        self.url = url
        clock = session.synchronizationClock
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Self.size.width,
            AVVideoHeightKey: Self.size.height,
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        super.init()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        append(sampleBuffer)
    }

    func append(_ buffer: CMSampleBuffer) {
        lock.withLock { appendLocked(buffer) }
    }

    private func appendLocked(_ buffer: CMSampleBuffer) {
        guard !finishing, writer.status != .failed else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(buffer)
        if startHostTime == nil {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: time)
            startHostTime = hostSeconds(of: time)
        }
        guard input.isReadyForMoreMediaData else { return }
        input.append(buffer)
    }

    func finish() async -> CameraTake? {
        let started = lock.withLock {
            finishing = true
            return startHostTime
        }
        guard let started else { return nil }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { return nil }
        return CameraTake(url: url, startHostTime: started)
    }

    private func hostSeconds(of time: CMTime) -> Double {
        guard let clock else { return time.seconds }
        return CMSyncConvertTime(time, from: clock, to: CMClockGetHostTimeClock()).seconds
    }
}
