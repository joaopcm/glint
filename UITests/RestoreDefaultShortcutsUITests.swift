import AppKit
import XCTest

final class RestoreDefaultShortcutsUITests: GlintUITestCase {
    /// Capture Area is cleared in Glint's own defaults instead of pinned, like `ShortcutRecorderUITests`: a pinned argument
    /// would hide what Restore Defaults saves (run 45520447954).
    override var pinnedHotkeys: [Hotkey] { Hotkey.allCases.filter { $0 != .area } }

    override func setUpWithError() throws {
        CFPreferencesSetAppValue("KeyboardShortcuts_captureArea" as CFString, kCFBooleanFalse, Self.glintBundleID as CFString)
        CFPreferencesAppSynchronize(Self.glintBundleID as CFString)
        try super.setUpWithError()
    }

    @MainActor func testRestoreDefaultsBringsBackAClearedShortcutThatThenCaptures() {
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: Self.captureTimeout), "Glint's menu bar icon is missing")
        statusItem.click()
        statusItem.descendants(matching: .menuItem)["Settings…"].click()
        // Settings reopens on the last tab, and an earlier test leaves it on Upload (run 45524565702).
        let generalTab = app.buttons.matching(NSPredicate(format: "title == %@ OR label == %@", "General", "General")).firstMatch
        XCTAssertTrue(generalTab.waitForExistence(timeout: Self.captureTimeout), "Settings has no General tab")
        generalTab.click()

        let restore = app.descendants(matching: .any).matching(identifier: AccessibilityID.restoreDefaultShortcuts).firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: Self.captureTimeout), "Settings has no Restore Defaults button")
        XCTAssertFalse(recorder(showing: "⇧⌘2").exists, "Capture Area should start cleared")
        restore.click()

        XCTAssertTrue(recorder(showing: "⇧⌘2").waitForExistence(timeout: Self.captureTimeout), "Restore Defaults did not bring back ⇧⌘2")
        app.typeKey("w", modifierFlags: .command)

        press(.area)
        XCTAssertTrue(overlay.waitForExistence(timeout: Self.captureTimeout), "the restored ⇧⌘2 did not start an area capture")
        pressEscape()
    }

    @MainActor private func recorder(showing shortcut: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "value == %@", shortcut)).firstMatch
    }
}
