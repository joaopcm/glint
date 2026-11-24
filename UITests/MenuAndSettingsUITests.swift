import AppKit
import XCTest

final class MenuAndSettingsUITests: GlintUITestCase {
    override var extraLaunchArguments: [String] { ["-bucketEndpoint", "not-a-url"] }

    @MainActor func testMenuShowsCaptureItemsSettingsVersionAndQuit() {
        let menu = openMenu()
        for title in ["Capture Area", "Capture Window", "Capture Full Screen", "Capture Text", "Record Area", "Record Window", "Record System Audio", "Record Microphone", "Settings…", "Quit Glint"] {
            let item = menu.descendants(matching: .menuItem)[title]
            XCTAssertTrue(item.waitForExistence(timeout: Self.captureTimeout), "menu has no \"\(title)\"")
            XCTAssertTrue(item.isEnabled, "\"\(title)\" is disabled")
        }
        let version = menu.descendants(matching: .menuItem).matching(NSPredicate(format: "title MATCHES %@", #"^Glint \S+ \(\S+\) \S+$"#)).firstMatch
        XCTAssertTrue(version.exists, "menu has no \"Glint <version> (<build>) <commit>\" line")
        XCTAssertFalse(version.isEnabled, "the version line should be greyed out")
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor func testSettingsOpensInFrontFromTheMenu() {
        for attempt in 1...2 {
            openMenu().descendants(matching: .menuItem)["Settings…"].click()
            XCTAssertTrue(settingsWindowContent.waitForExistence(timeout: Self.captureTimeout), "Settings did not open (attempt \(attempt))")
            XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.bundleIdentifier, Self.glintBundleID, "Settings is not in front (attempt \(attempt))")
            app.typeKey("w", modifierFlags: .command)
            XCTAssertTrue(waitForNonExistence(settingsWindowContent), "Settings did not close (attempt \(attempt))")
        }
    }

    @MainActor func testSettingsShowsDefaultShortcuts() {
        openMenu().descendants(matching: .menuItem)["Settings…"].click()
        XCTAssertTrue(settingsWindowContent.waitForExistence(timeout: Self.captureTimeout))
        for shortcut in ["⇧⌘2", "⌃⇧⌘2", "⇧⌘1", "⌥⇧⌘2", "⌥⇧⌘5", "⌃⌥⇧⌘5"] {
            let recorder = app.descendants(matching: .any).matching(NSPredicate(format: "value == %@", shortcut)).firstMatch
            XCTAssertTrue(recorder.exists, "no shortcut recorder shows \(shortcut)")
        }
    }

    @MainActor func testUploadTabTestsTheConnectionWithoutTouchingTheNetworkWhenTheEndpointIsBad() {
        openMenu().descendants(matching: .menuItem)["Settings…"].click()
        XCTAssertTrue(settingsWindowContent.waitForExistence(timeout: Self.captureTimeout))
        // The Settings toolbar tab is a button titled "Upload" whose label is sometimes empty (ui.xcresult of run 45478719380).
        let uploadTab = app.buttons.matching(NSPredicate(format: "title == %@ OR label == %@", "Upload", "Upload")).firstMatch
        XCTAssertTrue(uploadTab.waitForExistence(timeout: Self.captureTimeout), "Settings has no Upload tab")
        uploadTab.click()

        let testConnection = app.descendants(matching: .any).matching(identifier: AccessibilityID.testConnection).firstMatch
        XCTAssertTrue(testConnection.waitForExistence(timeout: Self.captureTimeout), "the Upload tab has no Test Connection button")
        testConnection.click()

        let result = app.descendants(matching: .any).matching(identifier: AccessibilityID.connectionTestResult).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: Self.captureTimeout), "Test Connection showed no result")
        let shown = "\(result.value ?? "") \(result.label)"
        XCTAssertTrue(shown.contains("The endpoint URL not-a-url isn't an http:// or https:// URL with a host."), "result reads: \(shown)")
    }

    @MainActor private var settingsWindowContent: XCUIElement {
        app.staticTexts["Save folder"]
    }

    /// SwiftUI also lists these items in the app's own menus, so look them up under the menu bar icon only.
    @MainActor private func openMenu() -> XCUIElement {
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: Self.captureTimeout), "Glint's menu bar icon is missing")
        statusItem.click()
        return statusItem
    }

    @MainActor private func waitForNonExistence(_ element: XCUIElement) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter.wait(for: [gone], timeout: Self.captureTimeout) == .completed
    }
}
