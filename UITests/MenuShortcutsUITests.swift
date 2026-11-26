import AppKit
import ApplicationServices
import Carbon.HIToolbox
import XCTest

final class MenuShortcutsUITests: LunettaUITestCase {
    /// Capture Area is cleared in Lunetta's own defaults instead of pinned, like `ShortcutRecorderUITests`: a pinned argument
    /// would hide what the recorder saves (run 45520447954).
    override var pinnedHotkeys: [Hotkey] { Hotkey.allCases.filter { $0 != .area } }

    override func setUpWithError() throws {
        CFPreferencesSetAppValue("KeyboardShortcuts_captureArea" as CFString, nil, Self.lunettaBundleID as CFString)
        CFPreferencesAppSynchronize(Self.lunettaBundleID as CFString)
        try super.setUpWithError()
    }

    @MainActor func testMenuShowsTheBoundShortcutThroughRebindingAndClearing() {
        XCTAssertEqual(shortcutInOpenMenu(for: "Capture Area"), "⇧⌘2", "Capture Area should show its default")
        closeMenu()

        openSettingsTab("Shortcuts")
        let captureArea = recorder(showing: "⇧⌘2")
        XCTAssertTrue(captureArea.waitForExistence(timeout: Self.captureTimeout), "no shortcut recorder shows the Capture Area default ⇧⌘2")
        captureArea.click()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        postKey(kVK_ANSI_9, flags: [.maskControl, .maskAlternate, .maskCommand])
        XCTAssertTrue(recorder(showing: "⌃⌥⌘9").waitForExistence(timeout: Self.captureTimeout),
                      "the Capture Area recorder did not record ⌃⌥⌘9, it shows \(captureArea.value ?? "nothing")")
        app.typeKey("w", modifierFlags: .command)

        XCTAssertEqual(shortcutInOpenMenu(for: "Capture Area"), "⌃⌥⌘9", "Capture Area should show the rebound shortcut")
        closeMenu()

        openSettingsTab("Shortcuts")
        app.buttons["Clear Capture Area shortcut"].click()
        XCTAssertTrue(recorder(showing: "Record Shortcut").waitForExistence(timeout: Self.captureTimeout), "clearing Capture Area left a shortcut in its recorder")
        app.typeKey("w", modifierFlags: .command)

        XCTAssertNil(shortcutInOpenMenu(for: "Capture Area"), "Capture Area should show no shortcut once cleared")
        closeMenu()
    }

    /// With the menu open, the press can reach both the item's key equivalent and the global hotkey; only one may capture.
    @MainActor func testShortcutCapturesOnceWhileTheMenuShowsIt() {
        XCTAssertEqual(shortcutInOpenMenu(for: "Capture Full Screen"), "⇧⌘1")
        press(.fullScreen)
        waitForPNGs(count: 1, after: .fullScreen)
        assertPNGCount(1)
    }

    @MainActor private func recorder(showing shortcut: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "value == %@", shortcut)).firstMatch
    }

    @MainActor private func closeMenu() {
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Opens the menu bar menu and reads the item's key equivalent through Accessibility: XCUITest has no API for it.
    @MainActor private func shortcutInOpenMenu(for title: String, file: StaticString = #filePath, line: UInt = #line) -> String? {
        guard AXIsProcessTrusted() else {
            XCTFail("""
                the UI test runner can't read Lunetta's menu through Accessibility (kTCCServiceAccessibility). \
                CI grants it with scripts/ci-grant-tcc.sh. locally, allow LunettaUITests-Runner in \
                System Settings > Privacy & Security > Accessibility and run again
                """, file: file, line: line)
            return nil
        }
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: Self.captureTimeout), "Lunetta's menu bar icon is missing", file: file, line: line)
        statusItem.click()
        XCTAssertTrue(statusItem.descendants(matching: .menuItem)[title].waitForExistence(timeout: Self.captureTimeout),
                      "menu has no \"\(title)\"", file: file, line: line)

        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: Self.lunettaBundleID).first?.processIdentifier,
              let extras = element(kAXExtrasMenuBarAttribute, of: AXUIElementCreateApplication(pid)),
              let item = menuItem(titled: title, under: extras)
        else {
            XCTFail("Accessibility shows no \"\(title)\" item under Lunetta's menu bar icon", file: file, line: line)
            return nil
        }
        guard let key = attribute(kAXMenuItemCmdCharAttribute, of: item) as? String, !key.isEmpty else { return nil }
        let modifiers = (attribute(kAXMenuItemCmdModifiersAttribute, of: item) as? Int) ?? 0
        var symbols = ""
        if modifiers & Int(kAXMenuItemModifierControl) != 0 { symbols += "⌃" }
        if modifiers & Int(kAXMenuItemModifierOption) != 0 { symbols += "⌥" }
        if modifiers & Int(kAXMenuItemModifierShift) != 0 { symbols += "⇧" }
        if modifiers & Int(kAXMenuItemModifierNoCommand) == 0 { symbols += "⌘" }
        return symbols + key.uppercased()
    }

    private func menuItem(titled title: String, under parent: AXUIElement) -> AXUIElement? {
        if attribute(kAXRoleAttribute, of: parent) as? String == kAXMenuItemRole,
           attribute(kAXTitleAttribute, of: parent) as? String == title {
            return parent
        }
        let children = attribute(kAXChildrenAttribute, of: parent) as? [AXUIElement] ?? []
        return children.lazy.compactMap { self.menuItem(titled: title, under: $0) }.first
    }

    private func element(_ name: String, of parent: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, of: parent), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
