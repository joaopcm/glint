# Plan 1: capture foundation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A menu bar app that captures an area, a window, or the display under the cursor from a global hotkey and saves a PNG to disk, built and signed by CI with a stable identity.

**Architecture:** XcodeGen `project.yml` generates the app target. Pure logic (naming, settings, geometry) lives in `Packages/GlintCore` and is tested on Linux and macOS. ScreenCaptureKit code lives in `Packages/GlintCapture` (macOS only). The app target owns AppKit UI: menu bar, selection overlay, settings window.

**Tech Stack:** Swift 6, SwiftUI + AppKit, ScreenCaptureKit, ImageIO, Swift Testing, XcodeGen, `KeyboardShortcuts` (sindresorhus, MIT), GitHub Actions `macos-15`.

**Spec:** `docs/superpowers/specs/2026-11-22-glint-design.md`

## Roadmap (one plan each, written when the previous one ships)

1. **Capture foundation** (this plan)
2. Quick-access overlay, OCR, magnifier, freeze-screen setting
3. Cloud upload (SigV4 in `GlintCore`, settings, history)
4. Annotation editor
5. Screen recording
6. Release: Developer ID, notarization, DMG, Sparkle (when the Apple account exists)

## Global Constraints

- Minimum macOS 15.0 (`MACOSX_DEPLOYMENT_TARGET = 15.0`).
- Menu bar app: `LSUIElement = YES`, no Dock icon.
- No App Sandbox. Hardened Runtime on (needed for notarization later).
- Bundle ID `com.joaopcm.glint`.
- No server, no telemetry, no network calls in this plan.
- `GlintCore` imports only `Foundation` and must build and test on Linux.
- `.xcodeproj` is generated, never committed.
- Every failure the user can hit is shown with the reason and the path or code involved, never "something went wrong".
- Commits: conventional, lowercase, imperative, no agent credit, no `Co-Authored-By`.
- Code comments: none unless they explain a why the code can't (see repo owner's policy).

## Builder calls in this plan (spec left them open)

- Default save folder: `~/Desktop` (matches macOS and CleanShot).
- Filename: `Glint 2026-11-22 at 15.04.05.png`. On collision: `Glint 2026-11-22 at 15.04.05 (2).png`.
- Default hotkeys: area `⇧⌘2`, window `⌃⇧⌘2`, full screen `⇧⌘1`. None clash with system `⇧⌘3/4/5`.
- License: MIT.

## Review Focus

1. **Mixed-scale displays** (Retina laptop + 1x external): a capture on each display comes out at that display's native pixel size. Pinned by `scaleForDisplay` tests in Task 4 and the QA checklist in Task 8.
2. **Displays left of or above the main one** (negative global coordinates): the captured region matches the selection exactly. Pinned by `negativeOriginDisplay` tests in Task 4.
3. **Screen recording permission missing or revoked:** the user sees a dialog that opens the right System Settings pane, never a blank or wallpaper-only PNG. Pinned in Task 5 (`ensurePermission`) and QA in Task 8.
4. **Click without drag / Esc during selection:** cancels; no file written. Pinned by `zeroAreaSelectionIsCancel` in Task 4.
5. **Save folder deleted or not writable:** alert names the path and the OS error; capture is not silently dropped. Pinned by `writeFailsWithPath` in Task 5.

---

### Task 1: repo skeleton, Linux + macOS CI

**Files:**
- Create: `project.yml`, `App/GlintApp.swift`, `App/Info.plist`, `App/Glint.entitlements`
- Create: `Packages/GlintCore/Package.swift`, `Packages/GlintCore/Sources/GlintCore/GlintCore.swift`, `Packages/GlintCore/Tests/GlintCoreTests/SmokeTests.swift`
- Create: `Packages/GlintCapture/Package.swift`, `Packages/GlintCapture/Sources/GlintCapture/GlintCapture.swift`
- Create: `.github/workflows/ci.yml`, `.gitignore`, `LICENSE` (MIT, "João Melo"), `README.md` (replace)

**Interfaces:**
- Produces: SwiftPM products `GlintCore` and `GlintCapture` (`platforms: [.macOS(.v15)]`, tools version 6.0); scheme `Glint`; app target `Glint`.

- [ ] **Step 1: Install Swift on the Linux dev box**

Run: `curl -O https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz && tar zxf swiftly-*.tar.gz && ./swiftly init --quiet-shell-followup && . ~/.local/share/swiftly/env.sh && swift --version`
Expected: `Swift version 6.x`.

- [ ] **Step 2: Write `SmokeTests.swift`**

```swift
import Testing
@testable import GlintCore

@Test func packageBuilds() { #expect(GlintCore.name == "Glint") }
```

- [ ] **Step 3: Run it, expect FAIL** (`GlintCore` undefined)

Run: `cd Packages/GlintCore && swift test`

- [ ] **Step 4: Add `public enum GlintCore { public static let name = "Glint" }`, run `swift test`, expect PASS.**

- [ ] **Step 5: Write `project.yml`**

One `application` target `Glint`, sources `App`, deployment target `15.0`, `info.path: App/Info.plist` with `LSUIElement: true`, `entitlements.path: App/Glint.entitlements` (empty dict, no sandbox), settings `PRODUCT_BUNDLE_IDENTIFIER: com.joaopcm.glint`, `ENABLE_HARDENED_RUNTIME: YES`, `CODE_SIGN_IDENTITY: "-"`, `CODE_SIGN_STYLE: Manual`. Packages: `GlintCore` and `GlintCapture` by `path`, `KeyboardShortcuts` from `https://github.com/sindresorhus/KeyboardShortcuts` `from: 2.0.0`. Also a `bundle.unit-test` target `GlintTests` (sources `AppTests`, host app `Glint`). `.gitignore` covers `*.xcodeproj`, `.build/`, `DerivedData/`, `build/`.

- [ ] **Step 6: `GlintApp.swift`: a SwiftUI `App` with a `MenuBarExtra("Glint", systemImage: "camera.viewfinder")` holding a "Quit Glint" button.**

- [ ] **Step 7: Write `ci.yml`**

Two jobs on `push` and `pull_request`:
- `core-linux` (`ubuntu-latest`, `swift-actions/setup-swift` with Swift 6): `cd Packages/GlintCore && swift test`.
- `app-macos` (`macos-15`): `brew install xcodegen`, `xcodegen generate`, `xcodebuild -scheme Glint -destination 'platform=macOS' -derivedDataPath build test`, then `swift test` in both packages.

- [ ] **Step 8: Push the branch, confirm both jobs green**

Run: `gh run watch --exit-status $(gh run list --branch <branch> --limit 1 --json databaseId -q '.[0].databaseId')`
Expected: exit 0.

- [ ] **Step 9: Commit** `chore: scaffold app, packages and ci`

---

### Task 2: stable self-signed signing and installable artifact

**Files:**
- Create: `scripts/make-dev-cert.sh`, `scripts/sign-and-zip.sh`
- Modify: `.github/workflows/ci.yml`
- Modify: `README.md` (install section)

**Interfaces:**
- Produces: CI artifact `Glint-<short-sha>.zip` containing a signed `Glint.app`; repo secrets `DEV_CERT_P12_BASE64`, `DEV_CERT_PASSWORD`.

- [ ] **Step 1: `make-dev-cert.sh`** generates, with `openssl`, an RSA 2048 self-signed cert, CN `Glint Development`, 3650 days, `keyUsage=critical,digitalSignature`, `extendedKeyUsage=critical,codeSigning`, exported to `.p12` with a random password. Prints the base64 p12 and password. Run it on the Linux box once, store with `gh secret set DEV_CERT_P12_BASE64` and `gh secret set DEV_CERT_PASSWORD`. Never commit the p12.

- [ ] **Step 2: `sign-and-zip.sh <app-path> <out-zip>`**: create a temp keychain, import the p12 (`security import ... -T /usr/bin/codesign`), `security set-key-partition-list -S apple-tool:,apple:,codesign: ...`, `codesign --force --options runtime --entitlements App/Glint.entitlements --sign "Glint Development" --keychain <tmp> <app>`, `codesign --verify --strict <app>`, `ditto -c -k --keepParent <app> <out-zip>`, delete the keychain.

- [ ] **Step 3: CI** builds Release (`xcodebuild -configuration Release build`) on pushes to `main` and on PRs, runs the script, uploads the zip with `actions/upload-artifact`, and prints `codesign -d -r- Glint.app`.

- [ ] **Step 4: Verify the identity is stable**

Trigger two CI runs (push an empty commit between). Compare the `designated =>` line in both logs.
Expected: identical, of the form `identifier "com.joaopcm.glint" and certificate leaf = H"<hash>"`. If they differ, permissions won't persist: stop and fix before going on.

- [ ] **Step 5: README install section**: download the artifact from the latest green run, unzip, move to `/Applications`, `xattr -d com.apple.quarantine /Applications/Glint.app`.

- [ ] **Step 6: Commit** `ci: sign builds with a stable dev certificate`

---

### Task 3: capture filenames

**Files:**
- Create: `Packages/GlintCore/Sources/GlintCore/Naming/CaptureNaming.swift`
- Test: `Packages/GlintCore/Tests/GlintCoreTests/CaptureNamingTests.swift`

**Interfaces:**
- Produces: `public enum CaptureNaming { public static func baseName(for date: Date, timeZone: TimeZone) -> String; public static func uniqueFileURL(in folder: URL, baseName: String, ext: String, exists: (URL) -> Bool) -> URL }`

- [ ] **Step 1: Tests**

```swift
@Test func baseNameFormat() {
    let d = ISO8601DateFormatter().date(from: "2026-11-22T15:04:05Z")!
    #expect(CaptureNaming.baseName(for: d, timeZone: TimeZone(identifier: "UTC")!) == "Glint 2026-11-22 at 15.04.05")
}
@Test func noCollision() {
    let url = CaptureNaming.uniqueFileURL(in: URL(filePath: "/tmp"), baseName: "Glint x", ext: "png", exists: { _ in false })
    #expect(url.lastPathComponent == "Glint x.png")
}
@Test func collisionAppendsCounter() {
    let taken: Set = ["Glint x.png", "Glint x (2).png"]
    let url = CaptureNaming.uniqueFileURL(in: URL(filePath: "/tmp"), baseName: "Glint x", ext: "png", exists: { taken.contains($0.lastPathComponent) })
    #expect(url.lastPathComponent == "Glint x (3).png")
}
```

- [ ] **Step 2: `swift test`, expect FAIL.**
- [ ] **Step 3: Implement.** `DateFormatter` with `en_US_POSIX`, pattern `yyyy-MM-dd 'at' HH.mm.ss`.
- [ ] **Step 4: `swift test`, expect PASS.**
- [ ] **Step 5: Commit** `feat(core): name captures and avoid collisions`

---

### Task 4: display geometry

ScreenCaptureKit wants a rect in a display's own top-left point space; AppKit gives global bottom-left coordinates anchored to the main screen. Mixing these up is the classic multi-display bug, so it gets its own tested unit.

**Files:**
- Create: `Packages/GlintCore/Sources/GlintCore/Geometry/DisplayGeometry.swift`
- Test: `Packages/GlintCore/Tests/GlintCoreTests/DisplayGeometryTests.swift`

**Interfaces:**
- Produces:
  - `public struct DisplayInfo: Sendable, Equatable { public let id: UInt32; public let frame: CGRect /* AppKit global */; public let scale: CGFloat }`
  - `public enum DisplayGeometry`
    - `static func display(containing point: CGPoint, in displays: [DisplayInfo]) -> DisplayInfo?`
    - `static func display(forSelection rect: CGRect, in displays: [DisplayInfo]) -> DisplayInfo?` (largest intersection area wins)
    - `static func sourceRect(for selection: CGRect, on display: DisplayInfo) -> CGRect?` (selection clipped to display, converted to display-local top-left points; `nil` if empty)
    - `static func pixelSize(of rect: CGRect, on display: DisplayInfo) -> (width: Int, height: Int)`

- [ ] **Step 1: Tests** (main `0,0,1512,982` scale 2; external `-1920,-200,1920,1080` scale 1):

```swift
@Test func mainDisplayFlipsY() {
    #expect(DisplayGeometry.sourceRect(for: CGRect(x: 100, y: 782, width: 200, height: 100), on: main) == CGRect(x: 100, y: 100, width: 200, height: 100))
}
@Test func negativeOriginDisplay() {
    #expect(DisplayGeometry.sourceRect(for: CGRect(x: -1820, y: 680, width: 300, height: 100), on: ext) == CGRect(x: 100, y: 100, width: 300, height: 100))
}
@Test func selectionSpanningDisplaysPicksLargerShareAndClips() {
    let sel = CGRect(x: -100, y: 100, width: 600, height: 100)
    #expect(DisplayGeometry.display(forSelection: sel, in: [main, ext]) == main)
    #expect(DisplayGeometry.sourceRect(for: sel, on: main)?.width == 500)
}
@Test func scaleForDisplay() {
    #expect(DisplayGeometry.pixelSize(of: CGRect(x: 0, y: 0, width: 200, height: 100), on: main) == (400, 200))
    #expect(DisplayGeometry.pixelSize(of: CGRect(x: 0, y: 0, width: 200, height: 100), on: ext) == (200, 100))
}
@Test func zeroAreaSelectionIsCancel() {
    #expect(DisplayGeometry.sourceRect(for: CGRect(x: 10, y: 10, width: 0, height: 0), on: main) == nil)
}
@Test func pointOnExternal() {
    #expect(DisplayGeometry.display(containing: CGPoint(x: -5, y: 0), in: [main, ext]) == ext)
}
```

- [ ] **Step 2: `swift test` on Linux, expect FAIL.**
- [ ] **Step 3: Implement.** Flip: `localY = display.frame.maxY - selection.maxY`; `localX = selection.minX - display.frame.minX`. Round pixel sizes with `.rounded()`.
- [ ] **Step 4: `swift test`, expect PASS.**
- [ ] **Step 5: Commit** `feat(core): map selections to display coordinates`

---

### Task 5: capture engine and PNG writer

**Files:**
- Create: `Packages/GlintCapture/Sources/GlintCapture/ScreenCapturer.swift`, `PNGWriter.swift`, `CapturePermission.swift`
- Test: `Packages/GlintCapture/Tests/GlintCaptureTests/PNGWriterTests.swift`
- Modify: `Packages/GlintCapture/Package.swift` (depend on `../GlintCore`)

**Interfaces:**
- Consumes: `DisplayInfo`, `DisplayGeometry` (Task 4), `CaptureNaming` (Task 3).
- Produces:
  - `public enum CapturePermission { static func isGranted() -> Bool; static func request() -> Bool; static func openSettings() }` (`CGPreflightScreenCaptureAccess`, `CGRequestScreenCaptureAccess`, URL `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`)
  - `public actor ScreenCapturer`
    - `func captureArea(_ selection: CGRect, displays: [DisplayInfo]) async throws -> CGImage`
    - `func captureDisplay(id: UInt32) async throws -> CGImage`
    - `func captureWindow(id: UInt32) async throws -> CGImage`
    - `func shareableWindows() async throws -> [SCWindow]` (on screen, `windowLayer == 0`, not owned by Glint, non-zero frame)
  - `public enum CaptureError: Error, LocalizedError { case permissionDenied, emptySelection, displayNotFound(UInt32), windowNotFound(UInt32), writeFailed(path: String, underlying: String) }`; `errorDescription` names the path / id.
  - `public enum PNGWriter { static func write(_ image: CGImage, to url: URL) throws }` (ImageIO `CGImageDestination`, `UTType.png`)

- [ ] **Step 1: Tests** (run on macOS CI only)

```swift
@Test func writesPNGWithSamePixelSize() throws {
    let img = makeSolidImage(width: 30, height: 20)
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".png")
    try PNGWriter.write(img, to: url)
    let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
    let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
    #expect(props[kCGImagePropertyPixelWidth] as? Int == 30)
}
@Test func writeFailsWithPath() throws {
    let url = URL(filePath: "/nonexistent-\(UUID())/x.png")
    let error = try #require(throws: CaptureError.self) { try PNGWriter.write(makeSolidImage(width: 1, height: 1), to: url) }
    guard case .writeFailed(let path, _) = error else { Issue.record("wrong case: \(error)"); return }
    #expect(path == url.path)
}
```

`makeSolidImage(width:height:) -> CGImage` is a test-file helper: an RGBA `CGContext` filled with one color.

- [ ] **Step 2: Push, expect CI FAIL on `app-macos`.**
- [ ] **Step 3: Implement.**
  - Area: `SCContentFilter(display:excludingWindows:[])` for the chosen display, `SCStreamConfiguration` with `sourceRect` from `DisplayGeometry.sourceRect`, `width/height` from `pixelSize`, `showsCursor = false`, then `SCScreenshotManager.captureImage(contentFilter:configuration:)`.
  - Display: same filter, full frame, pixel size = frame × scale.
  - Window: `SCContentFilter(desktopIndependentWindow:)`, size from `filter.contentRect × filter.pointPixelScale`, `ignoreShadowsSingleWindow = false` (shadow on, transparent background).
  - Every entry point checks `CapturePermission.isGranted()` first and throws `.permissionDenied`.
- [ ] **Step 4: Push, expect CI PASS.**
- [ ] **Step 5: Commit** `feat(capture): capture area, display and window to png`

---

### Task 6: settings

**Files:**
- Create: `Packages/GlintCore/Sources/GlintCore/Settings/Settings.swift`
- Test: `Packages/GlintCore/Tests/GlintCoreTests/SettingsTests.swift`
- Create: `App/Settings/SettingsView.swift`, `App/Settings/UserDefaultsStore.swift`, `App/Shortcuts.swift`

**Interfaces:**
- Produces:
  - `public protocol KeyValueStore: AnyObject { func string(forKey: String) -> String?; func set(_ value: String?, forKey: String); func bool(forKey: String) -> Bool?; func set(_ value: Bool, forKey: String) }`
  - `public final class Settings { init(store: KeyValueStore, defaultSaveFolder: URL); var saveFolder: URL; var copyToClipboardAfterCapture: Bool }` (defaults: `defaultSaveFolder`, `false`)
  - App: `extension KeyboardShortcuts.Name { static let captureArea, captureWindow, captureFullScreen }` with the defaults from "Builder calls".
  - App: `final class UserDefaultsStore: KeyValueStore`; `SettingsView` with save-folder picker (`NSOpenPanel`, directories only), the clipboard toggle, and `KeyboardShortcuts.Recorder` for each of the three shortcuts.

- [ ] **Step 1: Tests** with an in-memory store: defaults when empty; `saveFolder` round-trips through the store as a path; `copyToClipboardAfterCapture` round-trips.
- [ ] **Step 2: `swift test` on Linux, expect FAIL.**
- [ ] **Step 3: Implement `Settings`.** Keys: `saveFolderPath`, `copyToClipboardAfterCapture`.
- [ ] **Step 4: `swift test`, expect PASS.**
- [ ] **Step 5: Add `SettingsView` and open it from a "Settings…" menu item (`⌘,`). Push, CI green.**
- [ ] **Step 6: Commit** `feat: settings for save folder, clipboard and shortcuts`

---

### Task 7: selection overlay, hotkeys, end-to-end capture

**Files:**
- Create: `App/Overlay/SelectionOverlayController.swift`, `App/Overlay/AreaSelectionView.swift`, `App/Overlay/WindowPickerView.swift`
- Create: `App/CaptureCoordinator.swift`
- Test: `AppTests/CaptureCoordinatorTests.swift`
- Modify: `App/GlintApp.swift` (menu items: Capture Area, Capture Window, Capture Full Screen, Settings…, Quit)

**Interfaces:**
- Consumes: `ScreenCapturer`, `PNGWriter`, `CapturePermission`, `CaptureError` (Task 5); `CaptureNaming` (Task 3); `DisplayGeometry`, `DisplayInfo` (Task 4); `Settings`, `KeyboardShortcuts.Name` extensions (Task 6).
- Produces:
  - `enum SelectionResult { case area(CGRect), window(UInt32), cancelled }`
  - `@MainActor final class SelectionOverlayController { func selectArea() async -> SelectionResult; func selectWindow(_ windows: [SCWindow]) async -> SelectionResult }`
  - `@MainActor final class CaptureCoordinator { func run(_ mode: CaptureMode) async }`, `enum CaptureMode { case area, window, fullScreen }`. Saves via `CaptureNaming.uniqueFileURL` into `settings.saveFolder`; copies to `NSPasteboard` if the setting is on; on error shows an `NSAlert` with `error.localizedDescription`; on `.permissionDenied` the alert has an "Open System Settings" button calling `CapturePermission.openSettings()`.

- [ ] **Step 1: Coordinator tests** with the capturer and overlay behind protocols (`Capturing`, `Selecting`) and a fake save folder in the temp dir:
  - `cancelWritesNothing`: overlay returns `.cancelled` → folder stays empty.
  - `areaWritesOnePNG`: overlay returns `.area(...)`, fake capturer returns a 10×10 image → exactly one file named `Glint * at *.png`.
  - `permissionDeniedShowsSettingsAlert`: capturer throws `.permissionDenied` → the alert presenter receives an alert whose buttons include "Open System Settings".
- [ ] **Step 2: Push, expect CI FAIL.**
- [ ] **Step 3: Implement the coordinator and protocols.**
- [ ] **Step 4: Implement the overlay.** One borderless, non-activating `NSPanel` per `NSScreen` at `.screenSaver` level, `collectionBehavior` `[.canJoinAllSpaces, .fullScreenAuxiliary]`, crosshair cursor. Area: drag draws the rect with a dimmed outside and a `W × H` pixel readout (via `DisplayGeometry.pixelSize`). Esc or click without drag → `.cancelled`. Window mode: hover highlights the topmost `SCWindow` under the cursor (frames converted from top-left global to AppKit), click → `.window(id)`, Esc → `.cancelled`. Panels close before capture starts so they never appear in the image.
- [ ] **Step 5: Wire `KeyboardShortcuts.onKeyUp` and menu items to `CaptureCoordinator.run`. Full screen uses `DisplayGeometry.display(containing: NSEvent.mouseLocation, ...)`.**
- [ ] **Step 6: Push, expect CI PASS.**
- [ ] **Step 7: Commit** `feat: capture area, window and full screen from hotkeys`

---

### Task 8: QA on the Mac and the performance baseline

**Files:**
- Create: `docs/qa/plan-1-checklist.md`, `docs/perf.md`

- [ ] **Step 1: Write `docs/qa/plan-1-checklist.md`** covering, each with pass/fail: install from CI artifact; first-run permission flow; permission revoked in System Settings then capture → alert, not a blank PNG; area capture on Retina display has 2× pixel size; area capture on a 1x external display has 1× size; display arranged left/above main → captured region matches selection; selection spanning two displays; window capture has shadow and transparent corners; full screen picks the display under the cursor; Esc and click-without-drag write nothing; save folder deleted → alert names the path; two captures in the same second → `(2)` suffix; install a newer CI build → permission still granted (proves Task 2).
- [ ] **Step 2: Write `docs/perf.md`** with the measurement method: idle memory = `footprint <pid>` after 60 s idle; hotkey-to-crosshair = screen recording at 120 fps, count frames from key-down to crosshair visible, 10 runs, median. Measure CleanShot X first and record it as the receipt; then Glint.
- [ ] **Step 3: João runs the checklist and both measurements on his Mac** and pastes results into the docs. Failures become issues before Plan 2 starts.
- [ ] **Step 4: Commit** `docs: plan 1 qa checklist and perf baseline`
