import AVFoundation
import XCTest

final class RecordingPanelUITests: LunettaUITestCase {
    override var pinsRecordingChoices: Bool { false }

    /// The panel saves to Lunetta's real defaults, which every later test launches with; none of these may leak.
    private static let panelKeys = [
        "recordSystemAudio", "recordMicrophone", "recordingInputID", "recordingInputName",
        "showPressedKeys", "showMouseClicks", "recordingMode",
    ]

    override func setUpWithError() throws {
        Self.forgetPanelChoices()
        try super.setUpWithError()
    }

    override func tearDownWithError() throws {
        try super.tearDownWithError()
        Self.forgetPanelChoices()
    }

    @MainActor func testChoicesMadeInThePanelAreSavedAndRecordedAfterRecord() async throws {
        openRecordingPanel()
        center(of: panelControl(AccessibilityID.recordingPanelSystemAudio)).click()
        center(of: panelControl(AccessibilityID.recordingPanelClicks)).click()
        XCTAssertTrue(waitUntilSaved("recordSystemAudio", is: true), "turning on System Audio in the panel didn't save it")
        XCTAssertTrue(waitUntilSaved("showMouseClicks", is: true), "turning on Highlight Clicks in the panel didn't save it")

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
        XCTAssertTrue(waitUntilSaved("showPressedKeys", is: true), "turning on Show Pressed Keys in the panel didn't save it")

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

    @MainActor private func openRecordingPanel() {
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: Self.captureTimeout), "Lunetta's menu bar icon is missing")
        statusItem.click()
        statusItem.descendants(matching: .menuItem)["Record Screen…"].click()
        XCTAssertTrue(panel.waitForExistence(timeout: Self.captureTimeout), "Record Screen… didn't open the recording panel. Lunetta's accessibility tree:\n\(app.debugDescription)")
    }

    @MainActor private func waitUntilSaved(_ key: String, is expected: Bool) -> Bool {
        let deadline = Date().addingTimeInterval(Self.captureTimeout)
        while Date() < deadline {
            if Self.savedValue(key) == (expected ? "1" : "0") { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }

    /// A fresh `defaults` process each time: the runner's own CFPreferences cache kept answering with what it read
    /// before Lunetta saved, so a saved choice looked missing and deleting it did nothing (run 45816994479).
    private static func savedValue(_ key: String) -> String {
        defaults(["read", lunettaBundleID, key])
    }

    private static func forgetPanelChoices() {
        for key in panelKeys {
            defaults(["delete", lunettaBundleID, key])
        }
    }

    @discardableResult private static func defaults(_ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return "defaults \(arguments.joined(separator: " ")) didn't run: \(error.localizedDescription)"
        }
        process.waitUntilExit()
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
