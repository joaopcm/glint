import AVFoundation
import XCTest

final class RecordingPanelUITests: LunettaUITestCase {
    override var pinsRecordingChoices: Bool { false }
    /// The panel saves to Lunetta's real defaults; each test starts Lunetta from the panel's first-run choices.
    override var extraLaunchEnvironment: [String: String] { ["LUNETTA_UI_TEST_FRESH_RECORDING_CHOICES": "1"] }

    @MainActor func testChoicesMadeInThePanelSurviveARelaunchAndAreRecordedAfterRecord() async throws {
        openRecordingPanel()
        center(of: panelControl(AccessibilityID.recordingPanelSystemAudio)).click()
        center(of: panelControl(AccessibilityID.recordingPanelClicks)).click()
        XCTAssertTrue(waitUntilChecked(AccessibilityID.recordingPanelSystemAudio), "clicking System Audio didn't turn it on")
        XCTAssertTrue(waitUntilChecked(AccessibilityID.recordingPanelClicks), "clicking Highlight Clicks didn't turn it on")

        app.terminate()
        app.launchEnvironment = [:]
        app.launch()
        openRecordingPanel()
        XCTAssertTrue(waitUntilChecked(AccessibilityID.recordingPanelSystemAudio), "System Audio was off again after relaunching Lunetta")
        XCTAssertTrue(waitUntilChecked(AccessibilityID.recordingPanelClicks), "Highlight Clicks was off again after relaunching Lunetta")
        XCTAssertFalse(isChecked(panelControl(AccessibilityID.recordingPanelPressedKeys)), "Show Pressed Keys turned on by itself")

        center(of: panelControl(AccessibilityID.recordingPanelRecord)).click()
        waitForOverlay(after: .recordArea)
        XCTAssertFalse(panel.exists, "the panel stayed up over the area picker")
        let topLeft = selectRecordingArea()
        XCTAssertTrue(stopRecordingButton.waitForExistence(timeout: Self.captureTimeout), "no timer in the menu bar after Record and the countdown")
        movePointer(through: topLeft, for: Self.recordingLength)
        center(of: stopRecordingButton).click()

        let movie = try XCTUnwrap(waitForFile(withExtension: "mp4"), "no MP4 in \(saveFolder.path) after recording from the panel")
        let scale = pointerScreen.backingScaleFactor
        try await assertPlayable(movie, size: CGSize(width: 200 * scale, height: 150 * scale))
        let audio = try await AVURLAsset(url: movie).loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 1, "System Audio was turned on in the panel, yet \(movie.lastPathComponent) has \(audio.count) audio track(s)")
    }

    /// CI grants Lunetta Screen Recording only, so Input Monitoring is off like on a fresh Mac.
    @MainActor func testPressedKeysWithoutInputMonitoringNameThePermissionAndHoldBackRecord() throws {
        openRecordingPanel()
        let record = panelControl(AccessibilityID.recordingPanelRecord)
        XCTAssertTrue(record.isEnabled, "Record is disabled with every option off")
        center(of: panelControl(AccessibilityID.recordingPanelPressedKeys)).click()

        let explanation = app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Privacy & Security > Input Monitoring")).firstMatch
        XCTAssertTrue(explanation.waitForExistence(timeout: Self.captureTimeout), "the panel didn't say Show Pressed Keys needs Input Monitoring")
        XCTAssertTrue(app.buttons["Open Input Monitoring Settings"].exists, "the panel names Input Monitoring but offers no way to open it")
        XCTAssertFalse(record.isEnabled, "Record stayed enabled although the keys wouldn't show in the recording")

        center(of: panelControl(AccessibilityID.recordingPanelCancel)).click()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: panel)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: Self.captureTimeout), .completed, "Cancel didn't close the panel")
        XCTAssertFalse(overlay.exists, "Cancel brought up the area picker")
        let files = try FileManager.default.contentsOfDirectory(at: saveFolder, includingPropertiesForKeys: nil)
        XCTAssertTrue(files.isEmpty, "the panel left \(files.map(\.lastPathComponent)) in \(saveFolder.path) without recording")
    }

    @MainActor private var panel: XCUIElement {
        app.descendants(matching: .any).matching(identifier: AccessibilityID.recordingPanel).firstMatch
    }

    @MainActor private func panelControl(_ identifier: String) -> XCUIElement {
        let control = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: Self.captureTimeout), "the recording panel has no \(identifier)")
        return control
    }

    @MainActor private func isChecked(_ checkbox: XCUIElement) -> Bool {
        "\(checkbox.value ?? "")" == "1"
    }

    @MainActor private func waitUntilChecked(_ identifier: String) -> Bool {
        let checkbox = panelControl(identifier)
        let deadline = Date().addingTimeInterval(Self.captureTimeout)
        while Date() < deadline {
            if isChecked(checkbox) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }

    @MainActor private func openRecordingPanel() {
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: Self.captureTimeout), "Lunetta's menu bar icon is missing")
        statusItem.click()
        statusItem.descendants(matching: .menuItem)["Record Screen…"].click()
        XCTAssertTrue(panel.waitForExistence(timeout: Self.captureTimeout), "Record Screen… didn't open the recording panel. Lunetta's accessibility tree:\n\(app.debugDescription)")
    }
}
