import AppKit
import AVFoundation
import XCTest

final class RecordingStageUITests: LunettaUITestCase {
    override var pinsRecordingChoices: Bool { false }
    /// The stage saves to Lunetta's real defaults; each test starts Lunetta from the first-run choices.
    override var extraLaunchEnvironment: [String: String] { ["LUNETTA_UI_TEST_FRESH_RECORDING_CHOICES": "1"] }

    /// The resize starts on the corner where the move left it; had the move gone to the app underneath, that press
    /// would land outside the area and draw a 60 × 40 pt one instead.
    @MainActor func testTheShortcutStagesTheAreaToMoveAndResizeThenRecordsItWithTheToolbarsChoices() async throws {
        press(.recordScreen)
        waitForOverlay(after: .recordScreen)
        let topLeft = selectRecordingArea()
        XCTAssertTrue(stage.waitForExistence(timeout: Self.captureTimeout), "no stage after picking an area with \(Hotkey.recordScreen.rawValue)")
        XCTAssertFalse(stopRecordingButton.exists, "recording started before Record")

        let middle = CGPoint(x: topLeft.x + 100, y: topLeft.y + 75)
        screenPoint(middle).press(forDuration: 0.1, thenDragTo: screenPoint(CGPoint(x: middle.x + 40, y: middle.y + 30)))
        let corner = CGPoint(x: topLeft.x + 240, y: topLeft.y + 180)
        screenPoint(corner).press(forDuration: 0.1, thenDragTo: screenPoint(CGPoint(x: corner.x + 60, y: corner.y + 40)))
        let staged = CGRect(x: topLeft.x + 40, y: topLeft.y + 30, width: 260, height: 190)

        let input = stageControl(AccessibilityID.recordingStageInput)
        XCTAssertEqual(input.label, "Input: System Default", "the input button doesn't say which input records")
        let record = stageControl(AccessibilityID.recordingStageRecord)
        let titleWidth = ("Record" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width
        XCTAssertGreaterThanOrEqual(record.frame.width, titleWidth + 13 + 2 * 10,
                                    "Record is \(record.frame.width) pt wide, too narrow for its title, its 13 pt symbol and 10 pt of padding a side")
        let margins = try XCTUnwrap(contentMargins(of: record), "Record's screenshot shows nothing drawn on it")
        let tolerance = Int(2 * pointerScreen.backingScaleFactor)
        XCTAssertLessThanOrEqual(abs(margins.leading - margins.trailing), tolerance,
                                 "Record's dot and title sit \(margins.leading) px from its left edge and \(margins.trailing) px from its right")

        let systemAudio = stageControl(AccessibilityID.recordingStageSystemAudio)
        center(of: systemAudio).hover()
        let label = app.descendants(matching: .any).matching(identifier: AccessibilityID.recordingStageActionLabel).firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: Self.captureTimeout), "hovering System Audio showed no label")
        XCTAssertEqual(label.value as? String, "System Audio")
        XCTAssertFalse(label.frame.intersects(staged), "the label at \(label.frame) covers the area at \(staged)")
        keepScreenshot(named: "stage with a hover label")
        center(of: systemAudio).click()
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
        let notice = stageControl(AccessibilityID.recordingStageNotice)
        XCTAssertTrue(notice.frame.contains(explanation.frame), "the message at \(explanation.frame) runs out of its card at \(notice.frame)")
        XCTAssertTrue(pointerScreen.frame.height >= notice.frame.maxY && notice.frame.minY >= 0, "the notice at \(notice.frame) is off screen")
        keepScreenshot(named: "stage with the Input Monitoring notice")

        center(of: stageControl(AccessibilityID.recordingStageCancel)).click()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: stage)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: Self.captureTimeout), .completed, "Cancel didn't close the stage")
        XCTAssertFalse(stopRecordingButton.waitForExistence(timeout: Self.noFileWait), "Cancel started a recording")
        let files = try FileManager.default.contentsOfDirectory(at: saveFolder, includingPropertiesForKeys: nil)
        XCTAssertTrue(files.isEmpty, "the stage left \(files.map(\.lastPathComponent)) in \(saveFolder.path) without recording")
    }

    /// Pixels between each edge of `element` and the nearest column that differs from the background at its edges:
    /// where its icon and title start and stop.
    @MainActor private func contentMargins(of element: XCUIElement) -> (leading: Int, trailing: Int)? {
        guard let image = element.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let middle = height / 2
        let background = (0..<3).map { (Int(pixels[(middle * width) * 4 + $0]) + Int(pixels[(middle * width + width - 1) * 4 + $0])) / 2 }
        // A guess, not a measurement: text and symbols stand far apart from the glass behind them, its own shading doesn't.
        let drawn = (0..<width).filter { x in
            (0..<height).contains { y in (0..<3).contains { abs(Int(pixels[(y * width + x) * 4 + $0]) - background[$0]) > 80 } }
        }
        guard let first = drawn.first, let last = drawn.last else { return nil }
        return (first, width - 1 - last)
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
