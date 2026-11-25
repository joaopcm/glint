import AppKit
import XCTest

final class MenuAndSettingsUITests: LunettaUITestCase {
    /// Saved low on the 1024x768 screen, bottom at y 150 and top at y 450: a taller tab grows the window down from its top.
    override var extraLaunchArguments: [String] {
        ["-bucketEndpoint", "not-a-url", "-NSWindow Frame com_apple_SwiftUI_Settings_window", "272 150 480 300 0 0 1024 768 "]
    }

    @MainActor func testMenuShowsCaptureItemsSettingsVersionAndQuit() {
        let menu = openMenu()
        for title in ["Capture Area", "Capture Window", "Capture Full Screen", "Capture Text", "Record Area", "Record Window", "Record System Audio", "Record Microphone", "Settings…", "Quit Lunetta"] {
            let item = menu.descendants(matching: .menuItem)[title]
            XCTAssertTrue(item.waitForExistence(timeout: Self.captureTimeout), "menu has no \"\(title)\"")
            XCTAssertTrue(item.isEnabled, "\"\(title)\" is disabled")
        }
        let version = menu.descendants(matching: .menuItem).matching(NSPredicate(format: "title MATCHES %@", #"^Lunetta \S+ \(\S+\) \S+$"#)).firstMatch
        XCTAssertTrue(version.exists, "menu has no \"Lunetta <version> (<build>) <commit>\" line")
        XCTAssertFalse(version.isEnabled, "the version line should be greyed out")
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor func testSettingsOpensInFrontFromTheMenu() {
        for attempt in 1...2 {
            openMenu().descendants(matching: .menuItem)["Settings…"].click()
            XCTAssertTrue(settingsWindowContent.waitForExistence(timeout: Self.captureTimeout), "Settings did not open (attempt \(attempt))")
            XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.bundleIdentifier, Self.lunettaBundleID, "Settings is not in front (attempt \(attempt))")
            app.typeKey("w", modifierFlags: .command)
            XCTAssertTrue(waitForNonExistence(settingsWindowContent), "Settings did not close (attempt \(attempt))")
        }
    }

    @MainActor func testSettingsShowsDefaultShortcuts() {
        openSettingsTab("Shortcuts")
        for shortcut in ["⇧⌘2", "⌃⇧⌘2", "⇧⌘1", "⌥⇧⌘2", "⌥⇧⌘5", "⌃⌥⇧⌘5"] {
            let recorder = app.descendants(matching: .any).matching(NSPredicate(format: "value == %@", shortcut)).firstMatch
            XCTAssertTrue(recorder.waitForExistence(timeout: Self.captureTimeout), "no shortcut recorder shows \(shortcut)")
        }
    }

    @MainActor func testUploadTabTestsTheConnectionWithoutTouchingTheNetworkWhenTheEndpointIsBad() {
        // The Settings toolbar tab is a button titled "Upload" whose label is sometimes empty (ui.xcresult of run 45478719380).
        openSettingsTab("Upload")

        let testConnection = app.descendants(matching: .any).matching(identifier: AccessibilityID.testConnection).firstMatch
        XCTAssertTrue(testConnection.waitForExistence(timeout: Self.captureTimeout), "the Upload tab has no Test Connection button")
        testConnection.click()

        let upload = app.descendants(matching: .any).matching(identifier: AccessibilityID.connectionStep("upload")).firstMatch
        XCTAssertTrue(upload.waitForExistence(timeout: Self.captureTimeout), "Test Connection showed no upload row")
        let shown = "\(upload.value ?? "") \(upload.label)"
        XCTAssertTrue(shown.contains("failed") && shown.contains("The endpoint URL not-a-url isn't an http:// or https:// URL with a host."), "upload row reads: \(shown)")
    }

    /// #104: switching tabs grew Settings off the bottom of the screen; Test Connection sat at y 751 in run 45616804705.
    @MainActor func testSettingsStaysOnScreenWhenATallerTabOpens() {
        openSettingsTab("General")
        let uploadTab = app.buttons.matching(NSPredicate(format: "title == %@ OR label == %@", "Upload", "Upload")).firstMatch
        uploadTab.click()
        let testConnection = app.descendants(matching: .any).matching(identifier: AccessibilityID.testConnection).firstMatch
        XCTAssertTrue(testConnection.waitForExistence(timeout: Self.captureTimeout), "the Upload tab has no Test Connection button")
        let screen = NSScreen.main!
        let dockTop = screen.frame.height - screen.visibleFrame.minY
        XCTAssertTrue(testConnection.isHittable, "Test Connection is not clickable at \(testConnection.frame)")
        XCTAssertLessThanOrEqual(testConnection.frame.maxY, dockTop, "Test Connection ends at y \(testConnection.frame.maxY), under the Dock's top at y \(dockTop)")
    }

    /// Settings reopens on whichever tab an earlier test left it on, so look for the tab bar, not one tab's content.
    @MainActor private var settingsWindowContent: XCUIElement {
        app.buttons.matching(NSPredicate(format: "title == %@ OR label == %@", "General", "General")).firstMatch
    }

    /// SwiftUI also lists these items in the app's own menus, so look them up under the menu bar icon only.
    @MainActor private func openMenu() -> XCUIElement {
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: Self.captureTimeout), "Lunetta's menu bar icon is missing")
        statusItem.click()
        return statusItem
    }

    @MainActor private func waitForNonExistence(_ element: XCUIElement) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter.wait(for: [gone], timeout: Self.captureTimeout) == .completed
    }
}
