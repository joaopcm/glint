import AppKit
import XCTest

final class SettingsTabsUITests: LunettaUITestCase {
    /// The padding stays out of the arguments: the argument domain would shadow what the slider writes.
    override var extraLaunchArguments: [String] {
        ["-windowCaptureWallpaper", "YES"]
    }

    /// Frames are whole points and the canvas is ~400 pt wide, so rounding moves a width ratio by ~0.005.
    /// A slider snapped one 8 pt step short of either end moves it by under 0.016.
    static let ratioTolerance: CGFloat = 0.02

    @MainActor func testEveryTabOpensOnScreenWithItsControls() {
        let landmarks: [(tab: String, id: String?)] = [
            ("General", AccessibilityID.thumbnailCorner("bottomRight")),
            ("Capture", AccessibilityID.wallpaperPaddingSlider),
            ("Recording", AccessibilityID.recordingFormat),
            ("Sounds", AccessibilityID.soundPreview("shutter")),
            ("Shortcuts", AccessibilityID.restoreDefaultShortcuts),
            ("Upload", AccessibilityID.testConnection),
            ("History", nil),
        ]
        openSettingsTab("General")
        let screen = NSScreen.main!
        let menuBarBottom = screen.frame.height - screen.visibleFrame.maxY
        let dockTop = screen.frame.height - screen.visibleFrame.minY
        for (tab, id) in landmarks {
            let button = tabButton(tab)
            XCTAssertTrue(button.waitForExistence(timeout: Self.captureTimeout), "Settings has no \(tab) tab")
            XCTAssertTrue(button.isHittable, "the \(tab) tab is not clickable at \(button.frame); did the toolbar overflow?")
            button.click()
            guard let id else { continue }
            let landmark = element(id)
            XCTAssertTrue(landmark.waitForExistence(timeout: Self.captureTimeout), "the \(tab) tab shows no \(id)")
            XCTAssertTrue(landmark.isHittable, "\(id) on the \(tab) tab is not clickable at \(landmark.frame)")
            XCTAssertGreaterThanOrEqual(landmark.frame.minY, menuBarBottom, "\(id) on the \(tab) tab starts at y \(landmark.frame.minY), under the menu bar")
            XCTAssertLessThanOrEqual(landmark.frame.maxY, dockTop, "\(id) on the \(tab) tab ends at y \(landmark.frame.maxY), under the Dock's top at y \(dockTop)")
        }
    }

    @MainActor func testThumbnailCornerDiagramShowsTheChosenCorner() {
        openSettingsTab("General")
        let right = element(AccessibilityID.thumbnailCorner("bottomRight"))
        XCTAssertTrue(right.waitForExistence(timeout: Self.captureTimeout), "General has no thumbnail corner diagram")
        XCTAssertEqual(right.value as? String, "selected", "the bottom right corner isn't marked, but Lunetta launched with -overlayCorner bottomRight")
        XCTAssertNotEqual(element(AccessibilityID.thumbnailCorner("bottomLeft")).value as? String, "selected", "both corners are marked")
    }

    @MainActor func testPaddingSliderResizesTheWindowInThePreviewOverTheWallpaper() {
        openSettingsTab("Capture")
        let canvas = element(AccessibilityID.wallpaperPaddingPreview)
        XCTAssertTrue(canvas.waitForExistence(timeout: Self.captureTimeout), "the Capture tab has no padding preview")
        // SwiftUI leaves AXValue empty on this "Other" element (run 45811845542), so the label says what's behind the window.
        let readWallpaper = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Padding preview on your wallpaper"), object: canvas)
        if XCTWaiter.wait(for: [readWallpaper], timeout: Self.captureTimeout) != .completed {
            let fallback = element(AccessibilityID.wallpaperPreviewFallback)
            XCTFail("the preview reads \"\(canvas.label)\" instead of showing the wallpaper: \(fallback.exists ? fallback.label : "no reason shown")")
        }

        let slider = app.sliders.matching(identifier: AccessibilityID.wallpaperPaddingSlider).firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: Self.captureTimeout), "the Capture tab has no padding slider")
        XCTAssertTrue(slider.isEnabled, "the padding slider is disabled with -windowCaptureWallpaper YES")

        slider.adjust(toNormalizedSliderPosition: 0)
        let none = waitForWindowShare(near: 1)
        XCTAssertEqual(none, 1, accuracy: Self.ratioTolerance, "at 0 pt the sample window should fill the preview, it takes \(none) of its width")

        slider.adjust(toNormalizedSliderPosition: 1)
        let widest = waitForWindowShare(near: 1000 / 1512)
        XCTAssertEqual(widest, 1000 / 1512, accuracy: Self.ratioTolerance, "at 256 pt a 1000 pt window is 1000/1512 of the capture's width, the preview shows \(widest)")
    }

    @MainActor func testSoundsTabListsEverySoundWithAPlayButton() {
        openSettingsTab("Sounds")
        for sound in ["shutter", "RecordingTick", "RecordingStart", "RecordingStop", "RecordingPause", "RecordingResume", "RecordingDiscard"] {
            let play = element(AccessibilityID.soundPreview(sound))
            XCTAssertTrue(play.waitForExistence(timeout: Self.captureTimeout), "the Sounds tab has no play button for \(sound)")
            XCTAssertTrue(play.isEnabled, "the play button for \(sound) is disabled")
        }
    }

    @MainActor private func tabButton(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "title == %@ OR label == %@", title, title)).firstMatch
    }

    @MainActor private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// The sample window's share of the preview's width, read until it settles near `expected` or the wait runs out.
    @MainActor private func waitForWindowShare(near expected: CGFloat) -> CGFloat {
        let canvas = element(AccessibilityID.wallpaperPaddingPreview)
        let window = element(AccessibilityID.wallpaperPaddingPreviewWindow)
        let deadline = Date().addingTimeInterval(Self.captureTimeout)
        var share: CGFloat = 0
        repeat {
            share = canvas.frame.width > 0 ? window.frame.width / canvas.frame.width : 0
            if abs(share - expected) <= Self.ratioTolerance { return share }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return share
    }
}
