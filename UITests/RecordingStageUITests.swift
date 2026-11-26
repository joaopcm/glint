import AVFoundation
import XCTest

final class RecordingStageUITests: LunettaUITestCase {
    override var pinsRecordingChoices: Bool { false }
    /// The stage saves to Lunetta's real defaults; each test starts Lunetta from the first-run choices.
    override var extraLaunchEnvironment: [String: String] { ["LUNETTA_UI_TEST_FRESH_RECORDING_CHOICES": "1"] }

    @MainActor func testTheShortcutStagesTheAreaToResizeThenRecordsItWithTheToolbarsChoices() async throws {
        press(.recordScreen)
        waitForOverlay(after: .recordScreen)
        let topLeft = selectRecordingArea()
        XCTAssertTrue(stage.waitForExistence(timeout: Self.captureTimeout), "no stage after picking an area with \(Hotkey.recordScreen.rawValue)")
        XCTAssertFalse(stopRecordingButton.exists, "recording started before Record")

        let corner = CGPoint(x: topLeft.x + 200, y: topLeft.y + 150)
        screenPoint(corner).press(forDuration: 0.1, thenDragTo: screenPoint(CGPoint(x: corner.x + 60, y: corner.y + 40)))
        center(of: stageControl(AccessibilityID.recordingStageSystemAudio)).click()
        center(of: stageControl(AccessibilityID.recordingStageClicks)).click()
        center(of: stageControl(AccessibilityID.recordingStageRecord)).click()

        XCTAssertTrue(stopRecordingButton.waitForExistence(timeout: Self.captureTimeout), "no timer in the menu bar after Record and the countdown")
        XCTAssertFalse(stage.exists, "the stage stayed up while recording")
        movePointer(through: topLeft, for: Self.recordingLength)
        center(of: stopRecordingButton).click()

        let movie = try XCTUnwrap(waitForFile(withExtension: "mp4"), "no MP4 in \(saveFolder.path) after recording from the stage")
        let scale = pointerScreen.backingScaleFactor
        try await assertPlayable(movie, size: CGSize(width: 260 * scale, height: 190 * scale))
        let audio = try await AVURLAsset(url: movie).loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 1, "System Audio was turned on in the toolbar, yet \(movie.lastPathComponent) has \(audio.count) audio track(s)")
    }

    /// CI grants Lunetta Screen Recording only, so Input Monitoring is off like on a fresh Mac.
    @MainActor func testPressedKeysWithoutInputMonitoringNameThePermissionAndHoldBackRecord() throws {
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: Self.captureTimeout), "Lunetta's menu bar icon is missing")
        statusItem.click()
        statusItem.descendants(matching: .menuItem)["Record Screen…"].click()
        waitForOverlay(after: .recordScreen)
        selectRecordingArea()
        XCTAssertTrue(stage.waitForExistence(timeout: Self.captureTimeout), "no stage after picking an area from Record Screen…")

        let record = stageControl(AccessibilityID.recordingStageRecord)
        XCTAssertTrue(record.isEnabled, "Record is disabled with every option off")
        center(of: stageControl(AccessibilityID.recordingStagePressedKeys)).click()

        let explanation = app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Privacy & Security > Input Monitoring")).firstMatch
        XCTAssertTrue(explanation.waitForExistence(timeout: Self.captureTimeout), "the stage didn't say Show Pressed Keys needs Input Monitoring")
        XCTAssertTrue(app.buttons["Open Input Monitoring Settings"].exists, "the stage names Input Monitoring but offers no way to open it")
        XCTAssertFalse(record.isEnabled, "Record stayed enabled although the keys wouldn't show in the recording")

        center(of: stageControl(AccessibilityID.recordingStageCancel)).click()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: stage)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: Self.captureTimeout), .completed, "Cancel didn't close the stage")
        XCTAssertFalse(stopRecordingButton.waitForExistence(timeout: Self.noFileWait), "Cancel started a recording")
        let files = try FileManager.default.contentsOfDirectory(at: saveFolder, includingPropertiesForKeys: nil)
        XCTAssertTrue(files.isEmpty, "the stage left \(files.map(\.lastPathComponent)) in \(saveFolder.path) without recording")
    }

    @MainActor private var stage: XCUIElement {
        app.descendants(matching: .any).matching(identifier: AccessibilityID.recordingStage).firstMatch
    }

    @MainActor private func stageControl(_ identifier: String) -> XCUIElement {
        let control = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: Self.captureTimeout), "the stage has no \(identifier)")
        return control
    }
}
