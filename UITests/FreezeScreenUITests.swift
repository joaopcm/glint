import AppKit
import XCTest

final class FreezeScreenUITests: GlintUITestCase {
    override var extraLaunchArguments: [String] { ["-freezeScreenWhileSelecting", "YES"] }

    @MainActor func testFrozenAreaCaptureKeepsAMenuThatClosesWhenTheOverlayTakesFocus() {
        let fileMenu = finder.menuBars.menuBarItems["File"]
        fileMenu.click()
        let menu = fileMenu.menus.firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: Self.captureTimeout), "Finder's File menu did not open")
        let area = menu.frame.insetBy(dx: 8, dy: 8)

        press(.area)
        waitForOverlay(after: .area)
        drag(across: area)
        let withMenu = waitForPNGs(count: 1, after: .area)[0]

        if menu.exists { pressEscape() }
        press(.area)
        waitForOverlay(after: .area)
        drag(across: area)
        let pngs = waitForPNGs(count: 2, after: .area)
        let withoutMenu = pngs.first { $0 != withMenu }!

        let share = differingPixelShare(withMenu, withoutMenu)
        XCTAssertGreaterThan(share, 0.2, "the frozen capture looks like the screen without the menu (\(Int(share * 100))% of pixels differ)")
    }

    @MainActor private func drag(across rect: CGRect) {
        screenPoint(CGPoint(x: rect.minX, y: rect.minY))
            .press(forDuration: 0.1, thenDragTo: screenPoint(CGPoint(x: rect.maxX, y: rect.maxY)))
    }
}
