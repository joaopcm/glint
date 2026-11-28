import AVFoundation
import Testing
@testable import Lunetta

private func frame(at seconds: Double) throws -> CMSampleBuffer {
    var pixels: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720, kCVPixelFormatType_32BGRA, nil, &pixels)
    var format: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: try #require(pixels), formatDescriptionOut: &format)
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 30),
        presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 1_000_000_000),
        decodeTimeStamp: .invalid
    )
    var buffer: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: try #require(pixels),
        formatDescription: try #require(format),
        sampleTiming: &timing,
        sampleBufferOut: &buffer
    )
    return try #require(buffer)
}

@Test func aTakeStartsAtItsFirstBufferOnTheHostClock() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("camera-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try CameraFileWriter(url: url, session: AVCaptureSession())
    let start = CMClockGetTime(CMClockGetHostTimeClock()).seconds
    for index in 0..<3 { writer.append(try frame(at: start + Double(index) / 30)) }

    let take = try #require(await writer.finish())

    #expect(take.url == url)
    #expect(abs(take.startHostTime - start) < 0.001)
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    #expect(tracks.count == 1)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: try #require(tracks.first), outputSettings: nil)
    reader.add(output)
    #expect(reader.startReading())
    var frames = 0
    while let sample = output.copyNextSampleBuffer() { frames += CMSampleBufferGetNumSamples(sample) }
    #expect(frames == 3)
}

@Test func aTakeWithoutFramesLeavesNothingToKeep() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("camera-\(UUID().uuidString).mp4")
    let writer = try CameraFileWriter(url: url, session: AVCaptureSession())
    #expect(await writer.finish() == nil)
}
