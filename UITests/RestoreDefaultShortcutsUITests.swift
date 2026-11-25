import AppKit
import XCTest

final class RestoreDefaultShortcutsUITests: GlintUITestCase {
    /// Capture Area is left to Glint's own defaults instead of pinned, like `ShortcutRecorderUITests`: a pinned argument
    /// would hide what Restore Defaults saves (run 45520447954).
    override var pinnedHotkeys: [Hotkey] { Hotkey.allCases.filter { $0 != .area } }

    @MainActor func testRestoreDefaultsBringsBackAClearedShortcutThatThenCaptures() {
        openSettingsTab("Shortcuts")

        let restore = app.descendants(matching: .any).matching(identifier: AccessibilityID.restoreDefaultShortcuts).firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: Self.captureTimeout), "Settings has no Restore Defaults button")
        let cleared = recorder(showing: "Record Shortcut")
        if !cleared.exists {
            app.buttons["Clear Capture Area shortcut"].click()
        }
        XCTAssertTrue(cleared.waitForExistence(timeout: Self.captureTimeout), "clearing Capture Area did not leave its recorder showing Record Shortcut")
        restore.click()

        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: cleared)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: Self.captureTimeout), .completed, "Restore Defaults left Capture Area cleared")
        app.typeKey("w", modifierFlags: .command)

        press(.area)
        XCTAssertTrue(overlay.waitForExistence(timeout: Self.captureTimeout), "the restored ⇧⌘2 did not start an area capture")
        pressEscape()
    }

    @MainActor private func recorder(showing shortcut: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "value == %@", shortcut)).firstMatch
    }
}
