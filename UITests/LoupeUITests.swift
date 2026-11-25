import AppKit
import XCTest

final class LoupeUITests: LunettaUITestCase {
    override var showsMagnifier: Bool { true }

    @MainActor func testAreaModeShowsLoupe() {
        press(.area)
        waitForOverlay(after: .area)
        point(onOverlayAt: CGVector(dx: 400, dy: 300)).hover()
        XCTAssertTrue(loupe.waitForExistence(timeout: Self.captureTimeout), "no loupe next to the crosshair in area mode")
        pressEscape()
        assertOverlayClosed(after: .area)
    }

    /// Dragging up-left leaves the pointer at the selection's top-left, so the loupe (below-right of it) sits inside the PNG's area.
    @MainActor func testLoupeNeverAppearsInAreaPNG() {
        let scale = pointerScreen.backingScaleFactor
        press(.area)
        waitForOverlay(after: .area)
        let end = point(onOverlayAt: CGVector(dx: 100, dy: 100))
        let start = point(onOverlayAt: CGVector(dx: 300, dy: 250))
        start.hover()
        XCTAssertTrue(loupe.waitForExistence(timeout: Self.captureTimeout), "no loupe to keep out of the PNG")
        start.press(forDuration: 0.1, thenDragTo: end)
        let area = waitForPNGs(count: 1, after: .area)[0]

        press(.fullScreen)
        let full = waitForPNGs(count: 2, after: .fullScreen).first { $0 != area }!

        let region = CGRect(x: 100 * scale, y: 100 * scale, width: 200 * scale, height: 150 * scale)
        let share = differingPixelShare(area, full, regionOfB: region)
        XCTAssertLessThan(share, 0.01, "the area PNG differs from the same region of a full-screen capture (\(Int(share * 100))% of pixels); the loupe may be in it")
    }
}

final class LoupeOffUITests: LunettaUITestCase {
    /// The loupe's snapshot is the same display grab a capture is, so `noFileWait` is long enough for one to show up.
    @MainActor func testAreaModeShowsOnlyTheCrosshairByDefault() {
        press(.area)
        waitForOverlay(after: .area)
        let start = point(onOverlayAt: CGVector(dx: 100, dy: 100))
        start.hover()
        XCTAssertFalse(loupe.waitForExistence(timeout: Self.noFileWait), "a loupe showed in area mode with the magnifier setting off")
        start.press(forDuration: 0.1, thenDragTo: point(onOverlayAt: CGVector(dx: 300, dy: 250)))
        _ = waitForPNGs(count: 1, after: .area)
    }
}
