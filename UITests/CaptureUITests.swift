import AppKit
import XCTest

final class CaptureUITests: GlintUITestCase {
    @MainActor func testAreaDragWritesPNGOfDraggedSizeInPixels() {
        let scale = pointerScreen.backingScaleFactor
        press(.area)
        waitForOverlay(after: .area)
        let start = point(onOverlayAt: CGVector(dx: 100, dy: 100))
        start.press(forDuration: 0.1, thenDragTo: point(onOverlayAt: CGVector(dx: 300, dy: 250)))
        let png = waitForPNGs(count: 1, after: .area)[0]
        XCTAssertEqual(pixelSize(of: png), CGSize(width: 200 * scale, height: 150 * scale))
        XCTAssertFalse(overlay.exists, "the overlay stayed up after the capture")
        assertFinderFrontmost()
    }

    @MainActor func testEscCancelsAreaWindowAndText() {
        for hotkey in [Hotkey.area, .window, .text] {
            press(hotkey)
            waitForOverlay(after: hotkey)
            pressEscape()
            assertOverlayClosed(after: hotkey)
            assertPNGCount(0)
            XCTAssertFalse(app.dialogs.firstMatch.exists, "Esc after \(hotkey.rawValue) showed a dialog")
        }
    }

    @MainActor func testRightClickCancelsAreaAndWindow() {
        press(.area)
        waitForOverlay(after: .area)
        center(of: overlay).rightClick()
        assertOverlayClosed(after: .area)
        assertPNGCount(0)

        let window = openFinderWindow()
        press(.window)
        waitForOverlay(after: .window)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        assertOverlayClosed(after: .window)
        assertPNGCount(0)
    }

    @MainActor func testClickWithoutDragWritesNothing() {
        press(.area)
        waitForOverlay(after: .area)
        center(of: overlay).click()
        assertOverlayClosed(after: .area)
        assertPNGCount(0)
    }

    @MainActor func testHotkeyWhileOverlayUpKeepsOneOverlay() {
        press(.area)
        waitForOverlay(after: .area)
        press(.area)
        press(.window)
        press(.fullScreen)
        press(.text)
        assertPNGCount(0)
        XCTAssertEqual(overlays.count, NSScreen.screens.count, "a second overlay opened")
        pressEscape()
        assertOverlayClosed(after: .area)
        press(.fullScreen)
        waitForPNGs(count: 1, after: .fullScreen)
        assertPNGCount(1)
    }

    @MainActor func testWindowPickCapturesTheClickedWindow() {
        let window = openFinderWindow()
        let frame = window.frame
        let scale = pointerScreen.backingScaleFactor
        press(.window)
        waitForOverlay(after: .window)
        let center = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.hover()
        center.click()
        let png = waitForPNGs(count: 1, after: .window)[0]
        let size = pixelSize(of: png)
        XCTAssertGreaterThanOrEqual(size.width, frame.width * scale, "the PNG is narrower than the Finder window")
        XCTAssertGreaterThanOrEqual(size.height, frame.height * scale, "the PNG is shorter than the Finder window")
        XCTAssertEqual(topLeftAlpha(of: png), 0, "the corner isn't transparent: this is not a window capture with its shadow")
    }

    @MainActor func testClickOnEmptyDesktopKeepsOverlay() {
        press(.window)
        waitForOverlay(after: .window)
        point(onOverlayAt: CGVector(dx: 40, dy: 80)).click()
        XCTAssertTrue(overlay.exists, "clicking the empty desktop closed the window picker")
        assertPNGCount(0)
        pressEscape()
        assertOverlayClosed(after: .window)
    }
}
