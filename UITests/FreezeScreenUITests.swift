import AppKit
import XCTest

final class FreezeScreenUITests: GlintUITestCase {
    override var extraLaunchArguments: [String] { ["-freezeScreenWhileSelecting", "YES"] }

    /// A window that closes while the overlay is up stands in for a menu or tooltip that vanishes when focus moves.
    /// Synthetic clicks into a menu Finder is tracking don't behave like a user's (run 45430403154), so the test owns the window.
    @MainActor func testFrozenAreaCaptureKeepsAWindowThatClosedWhileSelecting() {
        let area = CGRect(x: 200, y: 200, width: 300, height: 200)
        let window = showMagentaWindow(atTopLeftOffset: area)

        press(.area)
        waitForOverlay(after: .area)
        window.orderOut(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let inner = area.insetBy(dx: 20, dy: 20)
        point(onOverlayAt: CGVector(dx: inner.minX, dy: inner.minY))
            .press(forDuration: 0.1, thenDragTo: point(onOverlayAt: CGVector(dx: inner.maxX, dy: inner.maxY)))
        let png = waitForPNGs(count: 1, after: .area)[0]

        let share = pixelShare(of: png) { r, g, b in r > 200 && g < 80 && b > 200 }
        XCTAssertGreaterThan(share, 0.95, "the frozen capture lost the window that closed after the hotkey (\(Int(share * 100))% magenta)")
    }

    /// `offset` is from the pointer screen's top-left, in points, like `point(onOverlayAt:)`.
    @MainActor private func showMagentaWindow(atTopLeftOffset offset: CGRect) -> NSWindow {
        let screen = pointerScreen.frame
        let frame = CGRect(x: screen.minX + offset.minX, y: screen.maxY - offset.maxY, width: offset.width, height: offset.height)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
        window.level = .floating
        window.orderFrontRegardless()
        addTeardownBlock { @MainActor in window.orderOut(nil) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        return window
    }
}
