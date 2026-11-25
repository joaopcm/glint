import XCTest

final class PickerPromptUITests: GlintUITestCase {
    override var pickerPromptExplained: Bool { false }

    /// Cleared in Glint's own defaults instead of passing `-pickerPromptExplained NO`: the argument domain would hide the
    /// `YES` Glint writes after the first capture, and the second capture would explain again (run 45510454936).
    override func setUpWithError() throws {
        CFPreferencesSetAppValue("pickerPromptExplained" as CFString, nil, Self.glintBundleID as CFString)
        CFPreferencesAppSynchronize(Self.glintBundleID as CFString)
        try super.setUpWithError()
    }

    @MainActor var toast: XCUIElement {
        app.descendants(matching: .any).matching(identifier: AccessibilityID.toast).firstMatch
    }

    @MainActor func testFirstCaptureExplainsThePromptOnceOnMajorsThatShowIt() {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let explains = PickerPromptNotice.shouldExplain(macOSMajor: major, alreadyExplained: false)

        press(.area)
        waitForOverlay(after: .area)
        if explains {
            XCTAssertTrue(toast.waitForExistence(timeout: Self.captureTimeout), "no picker prompt explanation on macOS \(major)")
            XCTAssertEqual(toast.value as? String, PickerPromptNotice.message)
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "picker prompt explanation"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        } else {
            XCTAssertFalse(toast.exists, "macOS \(major) isn't measured to show the prompt, yet Glint explained it")
        }
        point(onOverlayAt: CGVector(dx: 100, dy: 100)).press(forDuration: 0.1, thenDragTo: point(onOverlayAt: CGVector(dx: 200, dy: 200)))
        waitForPNGs(count: 1, after: .area)
        XCTAssertTrue(waitUntilGone(toast), "the explanation stayed after the capture finished")

        press(.area)
        waitForOverlay(after: .area)
        XCTAssertFalse(toast.exists, "the explanation showed again on the second capture")
        pressEscape()
        assertOverlayClosed(after: .area)
    }

    @MainActor private func waitUntilGone(_ element: XCUIElement) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter.wait(for: [gone], timeout: Self.captureTimeout) == .completed
    }
}
