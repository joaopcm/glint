import CoreGraphics
import LunettaCore
import Testing
@testable import LunettaCapture

private func window(_ id: UInt32) -> CapturableWindow {
    CapturableWindow(id: id, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
}

@Test func windowsFollowZOrderWithUnknownWindowsLast() {
    let sorted = ScreenCapturer.sortedFrontToBack([window(1), window(9), window(2), window(3)], zOrder: [3, 1, 2])
    #expect(sorted.map(\.id) == [3, 1, 2, 9])
}
