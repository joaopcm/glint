import AppKit
import XCTest

final class MenuAndSettingsUITests: GlintUITestCase {
    @MainActor func testMenuShowsCaptureItemsSettingsVersionAndQuit() {
        openMenu()
        for title in ["Capture Area", "Capture Window", "Capture Full Screen", "Settings…", "Quit Glint"] {
            let item = app.menuItems[title]
            XCTAssertTrue(item.waitForExistence(timeout: Self.captureTimeout), "menu has no \"\(title)\"")
            XCTAssertTrue(item.isEnabled, "\"\(title)\" is disabled")
        }
        let version = app.menuItems.matching(NSPredicate(format: "title MATCHES %@", #"^Glint \S+ \(\S+\) \S+$"#)).firstMatch
        XCTAssertTrue(version.exists, "menu has no \"Glint <version> (<build>) <commit>\" line")
        XCTAssertFalse(version.isEnabled, "the version line should be greyed out")
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor func testSettingsOpensInFrontFromTheMenu() {
        for attempt in 1...2 {
            openMenu()
            app.menuItems["Settings…"].click()
            XCTAssertTrue(settingsWindowContent.waitForExistence(timeout: Self.captureTimeout), "Settings did not open (attempt \(attempt))")
            XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.bundleIdentifier, Self.glintBundleID, "Settings is not in front (attempt \(attempt))")
            app.typeKey("w", modifierFlags: .command)
            XCTAssertTrue(waitForNonExistence(settingsWindowContent), "Settings did not close (attempt \(attempt))")
        }
    }

    @MainActor func testSettingsShowsDefaultShortcuts() {
        openMenu()
        app.menuItems["Settings…"].click()
        XCTAssertTrue(settingsWindowContent.waitForExistence(timeout: Self.captureTimeout))
        for shortcut in ["⇧⌘2", "⌃⇧⌘2", "⇧⌘1"] {
            let recorder = app.descendants(matching: .any).matching(NSPredicate(format: "value == %@", shortcut)).firstMatch
            XCTAssertTrue(recorder.exists, "no shortcut recorder shows \(shortcut)")
        }
    }

    @MainActor private var settingsWindowContent: XCUIElement {
        app.staticTexts["Save folder"]
    }

    @MainActor private func openMenu() {
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: Self.captureTimeout), "Glint's menu bar icon is missing")
        statusItem.click()
    }

    @MainActor private func waitForNonExistence(_ element: XCUIElement) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter.wait(for: [gone], timeout: Self.captureTimeout) == .completed
    }
}
