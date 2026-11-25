import AppKit
import Carbon.HIToolbox
import XCTest

final class ShortcutRecorderUITests: GlintUITestCase {
    /// Capture Area is cleared in Glint's own defaults instead of pinned with `-KeyboardShortcuts_captureArea`: the argument
    /// domain would hide what the recorder saves, and the field would keep showing ⇧⌘2 (run 45520447954).
    override var pinnedHotkeys: [Hotkey] { Hotkey.allCases.filter { $0 != .area } }

    override func setUpWithError() throws {
        CFPreferencesSetAppValue("KeyboardShortcuts_captureArea" as CFString, nil, Self.glintBundleID as CFString)
        CFPreferencesAppSynchronize(Self.glintBundleID as CFString)
        try super.setUpWithError()
    }

    /// #82: a Raycast hyper key sends ⌃⌥⇧⌘, and keypad keys carry the numeric pad flag. The pause stands in for a person
    /// moving from the click to the chord; sindresorhus/KeyboardShortcuts#241 tears the recorder down after the click.
    @MainActor func testRecorderReplacesAShortcutWithHyperAndAKeypadKeyThatThenCaptures() {
        let hyperKeypad1: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand, .maskNumericPad]
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: Self.captureTimeout), "Glint's menu bar icon is missing")
        statusItem.click()
        statusItem.descendants(matching: .menuItem)["Settings…"].click()
        // Settings reopens on the last tab, and an earlier test leaves it on Upload (run 45524565702).
        let generalTab = app.buttons.matching(NSPredicate(format: "title == %@ OR label == %@", "General", "General")).firstMatch
        XCTAssertTrue(generalTab.waitForExistence(timeout: Self.captureTimeout), "Settings has no General tab")
        generalTab.click()
        let captureArea = recorder(showing: "⇧⌘2")
        XCTAssertTrue(captureArea.waitForExistence(timeout: Self.captureTimeout), "no shortcut recorder shows the Capture Area default ⇧⌘2")
        captureArea.click()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        postKey(kVK_ANSI_Keypad1, flags: hyperKeypad1)

        let recorded = recorder(showing: "⌃⌥⇧⌘ Num 1")
        XCTAssertTrue(recorded.waitForExistence(timeout: Self.captureTimeout),
                      "the Capture Area recorder did not record ⌃⌥⇧⌘ Num 1, it shows \(captureArea.value ?? "nothing")")
        app.typeKey("w", modifierFlags: .command)

        postKey(kVK_ANSI_Keypad1, flags: hyperKeypad1)
        XCTAssertTrue(overlay.waitForExistence(timeout: Self.captureTimeout), "⌃⌥⇧⌘ Num 1 did not start an area capture")
        pressEscape()
    }

    @MainActor private func recorder(showing shortcut: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "value == %@", shortcut)).firstMatch
    }
}
