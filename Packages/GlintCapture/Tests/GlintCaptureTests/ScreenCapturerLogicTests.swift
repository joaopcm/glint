import CoreGraphics
import GlintCore
import Testing
@testable import GlintCapture

private func window(_ id: UInt32) -> CapturableWindow {
    CapturableWindow(id: id, frame: CGRect(x: 0, y: 0, width: 100, height: 100), title: nil, appName: nil)
}

@Test func windowsFollowZOrderWithUnknownWindowsLast() {
    let sorted = ScreenCapturer.sortedFrontToBack([window(1), window(9), window(2), window(3)], zOrder: [3, 1, 2])
    #expect(sorted.map(\.id) == [3, 1, 2, 9])
}

@Test func pixelSizeScalesAndRounds() {
    let size = ScreenCapturer.pixelSize(of: CGRect(x: 10, y: 10, width: 100.5, height: 50), scale: 2)
    #expect(size.width == 201)
    #expect(size.height == 100)
}

@Test(arguments: [CGFloat(1), 2])
func readoutAndCaptureAgreeOnPixelSize(scale: CGFloat) {
    let display = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: scale)
    let selections = [
        CGRect(x: 0, y: 0, width: 10.25, height: 20.5),
        CGRect(x: 3, y: 7, width: 333.5, height: 101.75),
        CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
        CGRect(x: 0, y: 0, width: 1511.75, height: 981.25),
    ]
    for selection in selections {
        let readout = DisplayGeometry.pixelSize(of: selection, on: display)
        let captured = ScreenCapturer.pixelSize(of: selection, scale: Float(scale))
        #expect(readout == captured, "selection \(selection) at \(scale)x")
    }
}
