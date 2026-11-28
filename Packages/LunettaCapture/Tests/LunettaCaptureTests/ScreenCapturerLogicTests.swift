import CoreGraphics
import Foundation
import LunettaCore
import ScreenCaptureKit
import Synchronization
import Testing
@testable import LunettaCapture

private func window(_ id: UInt32) -> CapturableWindow {
    CapturableWindow(id: id, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
}

@Test func windowsFollowZOrderWithUnknownWindowsLast() {
    let sorted = ScreenCapturer.sortedFrontToBack([window(1), window(9), window(2), window(3)], zOrder: [3, 1, 2])
    #expect(sorted.map(\.id) == [3, 1, 2, 9])
}

private let retina = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2)
private let external = DisplayInfo(id: 2, frame: CGRect(x: -1920, y: -200, width: 1920, height: 1080), scale: 1)

@Test func streamConfigurationMatchesAreaCapture() throws {
    let onRetina = try #require(ScreenCapturer.streamConfiguration(for: CGRect(x: 100, y: 200, width: 300, height: 400), on: retina))
    #expect(onRetina.sourceRect == CGRect(x: 100, y: 382, width: 300, height: 400))
    #expect(onRetina.width == 600 && onRetina.height == 800)

    let clipped = try #require(ScreenCapturer.streamConfiguration(for: CGRect(x: -100, y: 0, width: 300, height: 300.25), on: external))
    #expect(clipped.sourceRect == CGRect(x: 1820, y: 579.75, width: 100, height: 300.25))
    #expect(clipped.width == 100 && clipped.height == 300)

    #expect(ScreenCapturer.streamConfiguration(for: CGRect(x: 5000, y: 5000, width: 10, height: 10), on: retina) == nil)
}

@Test func scrollingStreamDeclinedByTheUserReportsMissingPermission() {
    let declined = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
    #expect(ScrollingFrames.stopError(declined) as? CaptureError == .permissionDenied)

    let other = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.attemptToStopStreamState.rawValue)
    #expect((ScrollingFrames.stopError(other) as NSError).code == other.code)
}

@Test func frameBufferKeepsTheNewestFramesWhenTheConsumerFallsBehind() async throws {
    let (buffer, frames) = FrameBuffer.make(limit: 3)
    for value in UInt8(1)...5 {
        buffer.push(Frame(width: 1, height: 1, bytesPerRow: 4, pixels: [value, value, value, 255]))
    }
    buffer.finish()

    var received: [UInt8] = []
    for try await frame in frames { received.append(frame.pixels[0]) }
    #expect(received == [3, 4, 5])
    #expect(buffer.droppedFrames == 2)
}

@Test func droppingTheFramesStreamRunsTheTerminationAction() {
    let terminated = Mutex(false)
    let buffer: FrameBuffer
    do {
        let (made, frames) = FrameBuffer.make(limit: 1)
        buffer = made
        buffer.onTermination { terminated.withLock { $0 = true } }
        withExtendedLifetime(frames) {}
    }
    #expect(terminated.withLock { $0 })
    withExtendedLifetime(buffer) {}
}
