# Glint: design

Status: draft for approval. "Glint" is a working name; renaming the repo later is cheap.

## Intent

An open source screenshot and screen recording app for macOS, as polished as CleanShot X. The author is a happy CleanShot user; nothing is broken there. The point is an open source app with the same feel, plus one-keystroke sharing through a bucket the user owns.

Success: the author replaces CleanShot with Glint for daily use and doesn't miss it.

## Goals (v1)

1. **Area capture**: hotkey, crosshair, drag a rectangle.
2. **Window capture**: hover highlights a window, click captures it (with its shadow, transparent background).
3. **Full-screen capture**: the display under the cursor.
4. **OCR capture**: select an area, recognized text goes to the clipboard.
5. **Screen recording**: area or window, saved as MP4. Optional system audio and mic audio, each a toggle. Stop from the menu bar.
6. **Quick-access overlay**: after every capture, a thumbnail floats in a screen corner with Copy, Save, Annotate, Upload, Close. Drag the thumbnail into any app to drop the file.
7. **Annotation editor**: arrow, rectangle, text, highlighter, blur/pixelate, crop. Objects stay editable until export.
8. **Cloud upload**: upload to the user's own S3-compatible bucket, copy a public link to the clipboard.

## Non-goals (v1)

Scrolling capture, GIF export, pinning screenshots, hiding desktop icons, video trimming/editing, annotating video, numbered-step/spotlight/background tools. Good candidates for v2.

Windows/Linux. Not now, and not designed for.

## Anti-goals

- **No server, no account, no telemetry.** Glint talks to the user's bucket and nothing else.
- **Upload is never required.** Every capture works fully offline; the cloud is opt-in.
- **Nothing that slows capture.** Hotkey-to-crosshair is the moment the app is judged on. A feature that adds latency there doesn't ship.
- **No silent failures.** An upload that fails says why, with the provider's error code and message (`AccessDenied: ...`), not "Upload failed".

## Constraints

- **Development machine is Linux.** macOS code is built and tested on GitHub Actions macOS runners and on the author's Mac. Code that doesn't touch the screen lives in a package that also builds and tests on Linux.
- **Minimum macOS 15 (Sequoia).** Receipt: `SCScreenshotManager` needs macOS 14 and `SCRecordingOutput` (record straight to file) needs macOS 15. One floor for both keeps one code path per feature.
- **macOS 15 re-asks for screen recording permission periodically.** That's OS behavior that CleanShot also hits. We don't fight it; we make the re-grant flow clear.
- **Development builds come from CI.** The author installs the app from GitHub Actions artifacts and doesn't build locally. CI signs every build with one self-signed certificate stored as a repo secret, so the code identity is stable and the screen recording permission and Keychain access survive updates. First launch needs `xattr -d com.apple.quarantine` or right-click → Open.
- **Signing.** Self-signed (above) during development. Before the first public release: Developer ID signing and notarization with the author's Apple Developer account. A stable signature also keeps the screen recording permission across updates.

## Approaches considered

| | Approach | Trade-off |
|---|---|---|
| **Picked** | **Native Swift (SwiftUI + AppKit)** with ScreenCaptureKit, Vision, AVFoundation | Best polish and lowest resource use; overlay, panels and hotkeys are native. Can't build on Linux, so the UI is built and tested in CI and on the Mac. |
| | Tauri (Rust core + web UI) with a Swift capture plugin | Familiar web UI, possible Windows port. But the hard parts still need native code, so there are three languages and a bridge, and the overlay and editor feel slightly off. |
| | Electron | Ruled out: a browser runtime of roughly 150 MB behind every capture and a laggy overlay. |

The author picked native Swift: polish is the whole point, and cross-platform wasn't asked for.

## How it's built

### Shape

A menu bar app (`LSUIElement`, no Dock icon) with a settings window.

```
glint/
  project.yml              XcodeGen spec (text; editable from Linux). .xcodeproj is generated, not committed.
  App/                     macOS app target: AppKit/SwiftUI, menu bar, windows
  Packages/
    GlintCore/             Pure Swift, no AppKit. Builds and tests on Linux + macOS.
      S3/                  SigV4 signer, uploader, error parsing
      Naming/              file names, object keys
      Settings/            settings model + persistence protocol
    GlintCapture/          ScreenCaptureKit, Vision OCR, recording (macOS only)
    GlintEditor/           annotation model + rendering (macOS only)
  .github/workflows/       CI
```

The split exists for one reason: everything that can be tested on Linux is in `GlintCore`, so the bulk of the logic doesn't wait on a macOS runner.

### Capture flow

```
hotkey ──► overlay: one transparent borderless panel per display, over the live screen
              area: drag rectangle, live size readout, magnifier
              window: hover highlights window frames from SCShareableContent
       ──► capture the selection (SCScreenshotManager), window capture with shadow
       ──► save to disk ──► quick-access overlay
```

Live overlay by default, so nothing stands between the hotkey and the crosshair. "Freeze screen" (grab displays first, select on the still image) is a setting, as in CleanShot, for catching menus and tooltips. *(Builder call: speed wins the default.)*

Every capture is written to the save folder the moment it's taken, so dismissing the overlay never loses one. "Copy to clipboard after capture" is a setting, off by default. *(Builder call.)*

### OCR

Same overlay as area capture, then `VNRecognizeTextRequest` (accurate level, automatic language detection), joined text to the clipboard, a toast confirms. Runs on-device.

### Recording

`SCStream` + `SCRecordingOutput` to MP4 (H.264 default, HEVC option). The selection overlay is reused for area/window. While recording: a menu bar stop button and a thin border around the recorded region (excluded from the capture). System audio and mic are opt-in toggles on the recording toolbar (ScreenCaptureKit captures both on macOS 15). Recordings land in the save folder like screenshots. *(Builder call: system audio added because CleanShot has it and it's cheap now, awkward later.)*

### Quick-access overlay

A non-activating floating panel in the corner, stacking newest on top. Copy, Save, Annotate, Upload, Close. Drag-out uses the file promise APIs so the thumbnail can drop into Slack, Finder, a browser, etc. Dismiss timing is a setting (default: stays until dismissed, like CleanShot).

### Annotation editor

A window with a canvas and toolbar. Annotations are a list of value-type objects (arrow, rect, text, highlight, blur region, crop) drawn over the base image, editable until export; export flattens to PNG. Blur/pixelate renders from the base image, so it can't be undone by moving the layer. Undo/redo via `UndoManager`. Annotations stay editable while the capture is still in the quick-access overlay; reopening it from there brings the objects back. Export writes the flattened image over the saved capture. Once the overlay item is dismissed, the capture is flat. Re-editable annotation files are v2. *(Builder call.)*

### Cloud upload

Settings: endpoint URL, region, bucket, access key ID, secret key, public base URL (e.g. `https://shots.example.com`), key prefix, path-style toggle (needed for MinIO). Keys go in the Keychain, not in user defaults. A "Test connection" button does a small PUT + DELETE and shows the raw result.

Upload: a single signed PUT with `Content-Type` set and `Content-Disposition: inline`. Object key = prefix + random base62 ID + extension. The ID length is set to make guessing impractical (to be sized in the plan, with the math). The link is `public base URL + key`, copied to the clipboard; a toast confirms.

SigV4 is implemented in `GlintCore` (a small, well-specified algorithm) instead of pulling in an AWS SDK. It's verified against AWS's published SigV4 test vectors on Linux.

Large recordings: a single PUT handles up to 5 GiB (S3 limit). Multipart upload is deferred until a real recording shows we need it. The threshold gets set from a measured recording size, not guessed.

Upload history: a list in settings with link, date, copy, and delete (deletes the object).

Presigned links (S3 caps these at 7 days) are a later option, not the default.

### Hotkeys

The `KeyboardShortcuts` package (sindresorhus, MIT): user-recordable global shortcuts with no Accessibility permission needed. Defaults avoid clashing with the system ⌘⇧3/4/5.

### Performance

Two numbers matter: idle memory, and hotkey-to-crosshair latency. Targets get set by first measuring CleanShot X on the author's Mac (the receipt), then aiming to match or beat it. Both are measured in a repeatable way and kept in `docs/perf.md`.

### Testing and CI

- `GlintCore`: unit tests (Swift Testing), run on Linux locally and on a macOS runner in CI.
- macOS packages: unit tests for anything with logic (annotation model, geometry, naming). Capture and UI are checked by hand on the Mac against a checklist in the plan.
- CI on every PR: build the app and run all tests on `macos-15`.
- Release workflow (later, once the Apple account exists): sign, notarize, staple, publish a DMG to GitHub Releases. Sparkle for auto-update comes with the first public release.

## Left to the builder

- Exact UI layout and visuals of the overlay, toolbar and settings. Use CleanShot as the reference for feel, not as something to copy pixel for pixel.
- Default hotkeys.
- Default save location and filename format.
- Repo license (proposal: MIT).
