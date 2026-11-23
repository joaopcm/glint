# QA Checks in CI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every QA check in `docs/qa/plan-1-checklist.md` that doesn't need João's Mac runs in CI, so a green PR means only the hardware checks are left to do by hand.

**Architecture:** Logic checks become unit tests in the suites that already exist (`GlintCore`, `GlintCapture`, `GlintTests`). Checks that need the real app become an XCUITest target, `GlintUITests`, in its own scheme `GlintUI`, run by a new `ui-macos` CI job. Before the tests run, that job writes the Screen Recording grant into the runner's system TCC database. The spike on `spike/ci-screen-recording` (run 45262298278) proved that grant works for an ad-hoc signed app on `macos-15`. Tests drive Glint the way a user does: Finder is frontmost, the test presses the real hotkeys, then checks the PNGs in a temp save folder and the accessibility tree.

**Tech Stack:** Swift 6, XCTest/XCUITest (UI), Swift Testing (unit), XcodeGen, GitHub Actions `macos-15` with Xcode 16.4.

**Spec:** `docs/qa/plan-1-checklist.md` (what each check expects) and `docs/superpowers/specs/2026-11-22-glint-design.md`.

## Global Constraints

- Deployment target macOS 15.0, `SWIFT_VERSION` 6.0. CI uses `/Applications/Xcode_16.4.app` and XcodeGen 2.47.0 (sha256 pinned in `ci.yml`).
- App bundle id `com.joaopcm.glint`. Hotkeys: area `⇧⌘2`, window `⌃⇧⌘2`, full screen `⇧⌘1`.
- Saved names match `^Glint \d{4}-\d{2}-\d{2} at \d{2}\.\d{2}\.\d{2}( \(\d+\))?\.png$`.
- UI tests never write outside their own temp folder. Every launch passes `-saveFolderPath <temp>` (the argument domain overrides the user's defaults).
- Checks that stay manual: 1-7, 10, 11a, 12, 15, 17-20, 23, 25, 26, 29, 31, 34, 42, 43, 52, 55, 57, 61, 63, 64. They need Retina, several displays, a trackpad, Gatekeeper, the first-run TCC prompt, CleanShot X, a cursor check, or human eyes.
- Every timeout cites its receipt. Measured in spike run 45262298278: the app gets the grant and writes the PNG in 53 ms (`20:48:53.302` → `20:48:53.355`).
- Commit messages: no `Co-Authored-By` line (João's rule overrides the harness default).

## Check map

| Checks | Where | Task |
|---|---|---|
| 28, 36, 44 (one display), 22/35 with Finder | UI smoke | 1 |
| 37, 38, 39, 40, 41 | `CaptureCoordinatorTests`, `PasteboardTests` | 2 |
| 13, 14, 56, 58 (persistence), 16/17 (readout = capture), 62 | `UserDefaultsStoreTests`, `ScreenCapturerLogicTests`, `ThumbnailLayoutTests` | 3 |
| 8, 9, 11 + CI build-label gate | `MenuAndSettingsUITests` | 4 |
| 16/17 on the runner's 1x display, 21, 24, 27, 30, 30a, 30b, 32, 33 | `CaptureUITests` | 5 |
| 45-51, 53, 54, 60 | `QuickAccessUITests` | 6 |

Already covered by existing tests, so no new test is needed: 18/19 (`appKitRectOnDisplayAboveMain`, `appKitRectOnDisplayLeftOfMain`), 53/56 layout (`ThumbnailLayoutTests`), 59 (`ThumbnailAutoDismissTests`), 36 naming (`CaptureNamingTests`).

## Review Focus

1. **A second Glint is running** (the installed `/Applications/Glint.app` on João's Mac, which has the same bundle id and hotkeys). The test must fail loudly, not capture through the wrong app. `setUp` terminates every `com.joaopcm.glint` instance before launch. Task 1's `testSetUpLeavesOneGlintRunning` pins this.
2. **The TCC grant silently stops working** after a runner image update. Every capture would then hit the permission alert and each test would time out with a vague message. The grant script re-reads the row and exits non-zero, naming the db, service and bundle id (Task 1, Step 4). The PNG wait names the alert if one is on screen (Task 1, `waitForPNGs`).
3. **The hotkey never arrives** (XCUITest key events don't reach the Carbon hotkey). The failure has to name the hotkey and say the overlay or file never appeared. `press(_:)` failures and `waitForPNGs` messages include the hotkey name (Task 1).
4. **A test writes to the Desktop.** `testSaveFolderIsTheTempFolder` asserts that the PNG landed in the temp folder and that the Desktop file count is unchanged (Task 1).
5. **Leftover UI between tests** (pinned windows, Preview, an open overlay) breaks the next test. `tearDown` terminates Glint, the annotate test terminates Preview, and `setUp` ends with `XCTAssertFalse(overlay.exists)`, so a leak fails the next test at its first line.

---

### Task 1: UI test target, CI job and smoke test

The riskiest piece goes first. If XCUITest key events don't fire Glint's Carbon hotkeys on the runner, stop and report back before Tasks 4-6. The fallback is to click the menu bar items (`app.statusItems`), which skips the hotkey path but still goes through the real overlay.

**Files:**
- Create: `App/AccessibilityID.swift`
- Modify: `App/Overlay/SelectionOverlayController.swift` (`OverlayPanel.init`)
- Modify: `project.yml` (target `GlintUITests`, scheme `GlintUI`)
- Create: `UITests/GlintUITestCase.swift`, `UITests/SmokeUITests.swift`
- Create: `scripts/ci-grant-screen-recording.sh`
- Create: `.github/actions/setup-xcode/action.yml`
- Modify: `.github/workflows/ci.yml`
- Modify: `README.md` (Test section)

**Interfaces:**
- Produces:
  - `enum AccessibilityID { static let selectionOverlay = "glint.selectionOverlay" }`. The file is compiled into both `Glint` and `GlintUITests`.
  - `class GlintUITestCase: XCTestCase` with `app: XCUIApplication`, `finder: XCUIApplication`, `saveFolder: URL`, `overlay: XCUIElement` (first window with id `selectionOverlay`), `enum Hotkey { case area, window, fullScreen }`, `func press(_: Hotkey)`, `func waitForPNGs(count: Int, after hotkey: Hotkey?) -> [URL]`, `func assertNoNewPNG(file:line:)`, `func pixelSize(of: URL) -> CGSize`, `func assertFinderFrontmost(file:line:)`, `var pointerScreen: NSScreen`.
  - `static let captureTimeout: TimeInterval = 10` (≈190× the 53 ms receipt), `static let noFileWait: TimeInterval = 2` (≈38× the receipt).

- [ ] **Step 1: Write the smoke tests in `UITests/SmokeUITests.swift`**

```swift
final class SmokeUITests: GlintUITestCase {
    func testFullScreenHotkeyWritesDisplaySizedPNGAndKeepsFinderFrontmost() {
        press(.fullScreen)
        let png = waitForPNGs(count: 1, after: .fullScreen)[0]
        XCTAssertNotNil(png.lastPathComponent.range(of: #"^Glint \d{4}-\d{2}-\d{2} at \d{2}\.\d{2}\.\d{2}\.png$"#, options: .regularExpression))
        let screen = pointerScreen
        XCTAssertEqual(pixelSize(of: png), CGSize(width: screen.frame.width * screen.backingScaleFactor,
                                                  height: screen.frame.height * screen.backingScaleFactor))
        XCTAssertTrue(app.images["Screenshot \(png.lastPathComponent)"].waitForExistence(timeout: Self.captureTimeout))
        assertFinderFrontmost()
    }

    func testSaveFolderIsTheTempFolder() throws {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let before = try FileManager.default.contentsOfDirectory(atPath: desktop.path).count
        press(.fullScreen)
        XCTAssertEqual(waitForPNGs(count: 1, after: .fullScreen)[0].deletingLastPathComponent().standardizedFileURL, saveFolder.standardizedFileURL)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: desktop.path).count, before)
    }

    func testSetUpLeavesOneGlintRunning() {
        XCTAssertEqual(NSRunningApplication.runningApplications(withBundleIdentifier: "com.joaopcm.glint").count, 1)
    }
}
```

- [ ] **Step 2: Implement `GlintUITestCase`**

`setUp`: set `continueAfterFailure = false`. Terminate every running `com.joaopcm.glint` and wait until it's gone (`NSRunningApplication.isTerminated`, 5 s; the receipt is the first green run, so update it then). Create `saveFolder` under `FileManager.default.temporaryDirectory/GlintUITests-<UUID>`. Launch with `["-saveFolderPath", saveFolder.path, "-copyToClipboardAfterCapture", "NO", "-overlayAutoDismiss", "NO", "-overlayCorner", "bottomRight", "-thumbnailWidth", "240"]`. Run `finder.activate()`, then `XCTAssertFalse(overlay.exists)`.

`tearDown`: `app.terminate()`, remove `saveFolder`.

`press(_:)`: `finder.typeKey("1" | "2", modifierFlags:)` with the global-constraint chords.

`waitForPNGs`: poll `saveFolder` for `.png` files until `count` is reached or `captureTimeout` runs out. On timeout, fail with a message that names the hotkey, the folder, the files found, and whether `app.dialogs.firstMatch` exists along with its text (this covers the permission-alert case).

`assertNoNewPNG`: wait `noFileWait`, then assert the count is unchanged.

`pointerScreen`: the `NSScreen` whose frame contains `NSEvent.mouseLocation`.

`pixelSize`: read `kCGImagePropertyPixelWidth` and `kCGImagePropertyPixelHeight` through `CGImageSource`.

- [ ] **Step 3: Add the target and scheme to `project.yml`**

Target `GlintUITests`: `type: bundle.ui-testing`, `platform: macOS`, `sources: [UITests, App/AccessibilityID.swift]`, `dependencies: [{target: Glint}]`, settings `GENERATE_INFOPLIST_FILE: YES`, `PRODUCT_BUNDLE_IDENTIFIER: com.joaopcm.glint.uitests`, `TEST_TARGET_NAME: Glint`. Scheme `GlintUI`: build `Glint` and `GlintUITests`, test `[GlintUITests]`. Leave scheme `Glint` unchanged so `app-macos` stays fast. In `OverlayPanel.init`, add `setAccessibilityIdentifier(AccessibilityID.selectionOverlay)`.

- [ ] **Step 4: Write `scripts/ci-grant-screen-recording.sh <bundle-id>...`**

For each id, run the spike's insert (`service 'kTCCServiceScreenCapture', client <id>, client_type 0, auth_value 2, auth_reason 4, auth_version 1, indirect_object_identifier 'UNUSED', flags 0`) on `/Library/Application Support/com.apple.TCC/TCC.db` with `sudo sqlite3`. Then `select auth_value` for that row. If it isn't `2`, print `TCC grant missing: kTCCServiceScreenCapture for <id> in <db>; every UI test would hit the permission alert` and exit 1. Finish with `sudo automationmodetool enable-automationmode-without-authentication`; the spike showed the runner reports "DOES NOT REQUIRE user authentication".

- [ ] **Step 5: Factor the CI setup out and add the `ui-macos` job**

Move "Select Xcode" and "Install XcodeGen" (with their env values unchanged) into the composite action `.github/actions/setup-xcode/action.yml`, and use it from `app-macos`. New job `ui-macos` on `macos-15`: checkout, `./.github/actions/setup-xcode`, `xcodegen generate`, then `scripts/ci-grant-screen-recording.sh com.joaopcm.glint com.joaopcm.glint.uitests.xctrunner` (grant the runner too, in case TCC blames it as the responsible process). Then `xcodebuild -scheme GlintUI -destination 'platform=macOS' -derivedDataPath build -resultBundlePath ui.xcresult test`. On failure, upload `ui.xcresult`; it holds XCUITest's screenshots. Leave `timeout-minutes` out until Step 7.

- [ ] **Step 6: Push the branch and check that `ui-macos` passes all three smoke tests**

Run: `gh run watch --repo joaopcm/glint $(gh run list --repo joaopcm/glint --branch <branch> --workflow ci --limit 1 --json databaseId -q '.[0].databaseId') --exit-status`
Expected: exit 0, with `ui-macos` passing `SmokeUITests` (3 tests). If the full-screen test times out with no dialog, it's the hotkey risk above: stop and report.

- [ ] **Step 7: Set `timeout-minutes` on `ui-macos` to 3× the green run's job duration**

Cite the run id and the measured duration in the commit message. Update the 5 s terminate wait in `setUp` the same way. Add a README "Test" line: `xcodegen generate && xcodebuild -scheme GlintUI -destination 'platform=macOS' test`. It takes over the keyboard and pointer while it runs, and the first local run needs Screen Recording granted to the Debug build.

- [ ] **Step 8: In the checklist, tag checks 28, 36 and 44 with `CI: SmokeUITests`, then commit**

---

### Task 2: Saving and clipboard checks as unit tests

**Files:**
- Modify: `AppTests/CaptureCoordinatorTests.swift`
- Create: `AppTests/PasteboardTests.swift`

**Interfaces:**
- Consumes: the existing `Harness`. Add an init parameter `clipboardOn: Bool = false` so a spy closure can be passed while the setting is off. Today the setting is derived from `copyToClipboard != nil`. Replace that.

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor @Test func secondCaptureInTheSameSecondGetsCounterSuffix() async throws  // check 37
// run(.area) twice with the harness's fixed `now`; files sorted == [base + ".png", base + " (2).png"], first file's bytes unchanged after the second run

@MainActor @Test func missingSaveFolderAlertNamesPathAndOSReason() async throws      // check 38
// replaces writeFailureShowsPathInAlert (same setup, adds the OS reason); createFolder: false; alert.message contains harness.folder.path and "No such file or directory"; no file anywhere under the harness root

@MainActor @Test func readOnlySaveFolderAlertNamesPathAndOSReason() async throws     // check 39
// chmod 0o555 on folder (restore 0o755 in defer); alert.message contains folder.path and "Permission denied"

@MainActor @Test func clipboardOnCopiesTheSavedFile() async throws                   // check 40
// spy records URLs; clipboardOn: true; spy == [folder/<saved name>]

@MainActor @Test func clipboardOffNeverTouchesTheClipboard() async throws            // check 41
// spy passed, clipboardOn: false; spy is empty
```

`AppTests/PasteboardTests.swift`:

```swift
@MainActor @Test func copyPNGFilePutsFileURLAndPNGOnThePasteboard() throws          // checks 40, 47
// NSPasteboard.withUniqueName(); write a 30×20 PNG to temp; copyPNGFile(at:)
// string(forType: .fileURL) == url.absoluteString; data(forType: .png) == the file's bytes; releaseGlobally() in defer
```

- [ ] **Step 2: Run them**

Run: `xcodegen generate && xcodebuild -scheme Glint -destination 'platform=macOS' test -only-testing:GlintTests`
Expected: compile failure on `clipboardOn` and nothing else. Any assertion that fails with existing behavior is a real bug: report it, don't change the expected values.

- [ ] **Step 3: Add `clipboardOn` to `Harness`, then run again**

Expected: all `GlintTests` pass.

- [ ] **Step 4: Tag checks 37-41 with `CI: <test name>` in the checklist, then commit**

---

### Task 3: Persistence, pixel-size and overflow checks as unit tests

**Files:**
- Create: `AppTests/UserDefaultsStoreTests.swift`
- Modify: `Packages/GlintCapture/Tests/GlintCaptureTests/ScreenCapturerLogicTests.swift`
- Modify: `AppTests/ThumbnailLayoutTests.swift`
- Modify: `App/ThumbnailPanel.swift` (only if Step 1's overflow test can't be written against `count`)

- [ ] **Step 1: Write the tests**

```swift
@Test func valuesSurviveANewStoreOnTheSameSuite()                                    // checks 13, 14, 56, 58
// suite "GlintTests-<UUID>"; store A sets saveFolderPath, copyToClipboardAfterCapture true, overlayCorner "bottomLeft", thumbnailWidth 300
// UserDefaults(suiteName:)!.synchronize(); a new UserDefaultsStore on a new UserDefaults(suiteName:) reads all four back; removePersistentDomain in defer

@Test(arguments: [CGFloat(1), 2]) func readoutAndCaptureAgreeOnPixelSize(scale: CGFloat)  // checks 16, 17
// rects {10.25×20.5, 333.5×101.75, 0.5×0.5, 1511.75×981.25}; DisplayGeometry.pixelSize(of:on: DisplayInfo(scale:)) == ScreenCapturer.pixelSize(of:scale: Float(scale)) for every rect

@MainActor @Test func showDropsOldestWhenTheColumnWouldOverflow() throws            // check 62
// fit = Int((screen.visibleFrame.height - margin) / (size(width: 240).height + spacing)) using NSScreen.main
// show fit + 2 PNGs with pointerLocation inside NSScreen.main; presenter.count == fit; all fit + 2 files still exist on disk
```

- [ ] **Step 2: Run them**

Run: `(cd Packages/GlintCapture && swift test) && xcodebuild -scheme Glint -destination 'platform=macOS' test -only-testing:GlintTests`
Expected: PASS. These pin behavior that already exists. A failure is a bug to report, not a value to edit.

- [ ] **Step 3: Tag checks 13, 14, 16, 17, 56, 58 and 62 in the checklist (persistence and readout parts as CI, the on-screen parts stay manual), then commit**

---

### Task 4: Menu and settings UI checks, plus the build-label gate

**Files:**
- Create: `UITests/MenuAndSettingsUITests.swift`
- Modify: `.github/workflows/ci.yml` (`app-macos`, after "Build Release")

**Interfaces:**
- Consumes: `GlintUITestCase` (Task 1).

- [ ] **Step 1: Write the tests**

```swift
func testMenuShowsCaptureItemsSettingsVersionAndQuit()   // check 8
// app.statusItems.firstMatch.click(); menuItems "Capture Area", "Capture Window", "Capture Full Screen", "Settings…", "Quit Glint" exist and are enabled
// one disabled menu item whose title matches ^Glint \S+ \(\S+\) \S+$; type Escape to close

func testSettingsOpensInFrontFromTheMenu()                // check 9
// with Finder frontmost: menu → "Settings…"; app.windows containing a "Save folder" static text waits for existence; app.state == .runningForeground; close it, open again, exists again

func testSettingsShowsDefaultShortcuts()                  // check 11
// open Settings; the recorders labeled "Capture Area", "Capture Window", "Capture Full Screen" show "⇧⌘2", "⌃⇧⌘2", "⇧⌘1"
```

If the runner's defaults ever carry a rebound shortcut, check 11 is wrong by design. The runner image is fresh on every run, so that can't happen in CI. Locally, if it fails, read the failure message first.

- [ ] **Step 2: Run `xcodebuild -scheme GlintUI -destination 'platform=macOS' test -only-testing:GlintUITests/MenuAndSettingsUITests`. Expected: PASS**

- [ ] **Step 3: Add the build-label gate to `app-macos`**

After "Build Release", add `plutil -extract GLINT_COMMIT raw` and `plutil -extract CFBundleVersion raw` on the Release `Info.plist`, asserting they equal the short sha and `github.run_number` (fail with expected vs actual). Mark that follow-up done in `docs/superpowers/plans/2026-11-22-plan-1-followups.md`.

- [ ] **Step 4: Tag checks 8, 9 and 11, then commit**

---

### Task 5: Capture and cancel UI checks

**Files:**
- Create: `UITests/CaptureUITests.swift`

**Interfaces:**
- Consumes: `GlintUITestCase`, `AccessibilityID.selectionOverlay`.
- Window target: the test opens a Finder window on `saveFolder` (`NSWorkspace.shared.open(saveFolder)`) and waits for `finder.windows[saveFolder.lastPathComponent]`. Don't move it; read its `frame` from XCUITest.

- [ ] **Step 1: Write the tests**

```swift
func testAreaDragWritesPNGOfDraggedSizeInPixels()      // checks 16/17 on the runner's display, 21, 36
// press(.area); overlay waits; drag from overlay coordinate (100,100) pt to (300,250) pt
// one PNG; pixelSize == (200, 150) × pointerScreen.backingScaleFactor; overlay no longer exists; assertFinderFrontmost

func testEscCancelsAreaAndWindow()                     // check 30
// for hotkey in [.area, .window]: press; overlay waits; typeKey(.escape); overlay gone; assertNoNewPNG; no dialog

func testRightClickCancelsAreaAndWindow()              // checks 30a, 30b
// area: rightClick on the overlay; window: rightClick over the Finder window; each: overlay gone, assertNoNewPNG
// right click mid-drag stays manual: XCUITest's press(forDuration:thenDragTo:) can't be interrupted by a second button

func testClickWithoutDragWritesNothing()               // check 32
// press(.area); click overlay; overlay gone; assertNoNewPNG

func testHotkeyWhileOverlayUpKeepsOneOverlay()         // check 33
// press(.area); press(.area), press(.window), press(.fullScreen); count of windows with id selectionOverlay == NSScreen.screens.count; Escape; gone; press(.fullScreen) → 1 PNG

func testWindowPickCapturesTheClickedWindow()          // check 24
// press(.window); hover the Finder window center; click; 1 PNG; pixel size ≥ window frame size × scale (shadow included)

func testClickOnEmptyDesktopKeepsOverlay()             // check 27
// press(.window); click a point outside every finder window (top-left of pointerScreen visibleFrame + 40 pt); overlay still exists; assertNoNewPNG; Escape
```

- [ ] **Step 2: Run `-only-testing:GlintUITests/CaptureUITests`. Expected: PASS.** If the window pick test fails because the runner's desktop has another window in front, pick the window under the Finder window's center from the failure screenshot in `ui.xcresult`. Don't move the click point blindly.

- [ ] **Step 3: Tag checks 16, 17 (runner part), 21, 24, 27, 30, 30a (non-drag part), 30b, 32 and 33, then commit**

---

### Task 6: Quick-access overlay UI checks

**Files:**
- Create: `UITests/QuickAccessUITests.swift`

**Interfaces:**
- Consumes: `GlintUITestCase`. Cards are `app.images["Screenshot <file name>"]`. Toolbar buttons are `app.buttons["Copy" | "Save As…" | "Annotate in Preview" | "Pin to Screen" | "Close"]`. A pinned window is `app.windows[<file name>]`.
- Fold-back delay: 1 s in `ThumbnailPresenter.refreshHover`. Tests wait up to 5 s (5× that).

- [ ] **Step 1: Write the tests**

```swift
func testOneThumbnailPerSavedCaptureNoneAfterCancel()   // checks 44, 45
// full screen, area drag, window pick → 3 PNGs, 3 card images exist; press(.area) + Escape → still 3 images; assertFinderFrontmost

func testHoverShowsToolbarAndHidesIt()                  // check 46
// one capture; card.hover() → 5 buttons exist and are hittable; hover pointerScreen center → Copy not hittable

func testCopyPutsFileOnPasteboardAndClosesCard()        // check 47
// hover, click Copy; card gone; NSPasteboard.general string(forType: .fileURL) == png URL absoluteString; data(forType: .png) non-nil

func testSaveAsWritesChosenFileAndCancelKeepsCard()     // check 48
// Save As → app.sheets/dialogs save panel exists; type "renamed" in name field, Return; saveFolder/renamed.png exists, original exists, card gone
// second capture: Save As → Escape; no new file; card still exists; assertFinderFrontmost

func testAnnotateOpensPreviewAndClosesCard()            // check 49
// click Annotate; XCUIApplication(bundleIdentifier: "com.apple.Preview") waits for .runningForeground; card gone; preview.terminate()

func testPinOpensFloatingWindowThatCloses()             // check 50
// click Pin; app.windows[png name] exists; card gone; press(.fullScreen) → new PNG (pinned window not asserted in pixels here, see 60); pinned window close button → window gone

func testCloseRemovesCardKeepsFile()                    // check 51
// click Close; card gone; png still exists

func testPileShowsCountExpandsAndFoldsBack()            // checks 53, 54
// 3 full-screen captures; one element with accessibilityHelp "3 screenshots, click to expand"; click it → 3 cards with distinct frame.minY; hover pointerScreen center → within 5 s, max − min of the cards' minY ≤ 14 pt (the collapsed pile offsets 7 pt per card)

func testThumbnailsNeverInCaptures()                    // checks 21, 60
// capture A (pile visible after 2 prior captures, bottom-right corner); close all cards (Close on each); capture B
// crop both PNGs to the card frames' union (converted to pixels); fraction of differing pixels < 0.01
// press(.window); hover a card; click → no PNG (cards are not offered), assertNoNewPNG; Escape
```

For `testThumbnailsNeverInCaptures`, the 1% threshold is a tripwire over a static wallpaper region. Record the measured fraction from the first green run in the commit message. If it's above 0, say why.

- [ ] **Step 2: Run `-only-testing:GlintUITests/QuickAccessUITests`. Expected: PASS**

- [ ] **Step 3: Tag checks 21, 44-51, 53, 54 and 60 in the checklist, update the checklist header ("Checks tagged `CI:` run on every push; run the rest on a real Mac"), then commit**

- [ ] **Step 4: Push, wait for all three jobs green (`gh run watch ... --exit-status`), open the PR with `/commit-push-pr`**
