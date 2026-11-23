# Plan 1 follow-ups

Findings from Plan 1's reviews that were deferred on purpose. Fold them into the plan they belong to.

## Before or during Plan 2

- Split the capture coordinator into "get the image" and "deliver it". OCR saves nothing, and the quick-access overlay needs the URL and image back. `run()` currently always saves and returns `Void`.
- Make the window picker load windows asynchronously so the overlay appears before the `shareableWindows()` query returns. This changes `Selecting.selectWindow`'s signature, so do it before Plan 5 reuses the picker for recording.
- Make `GlintSettings` `@Observable`. `SettingsView` currently holds `@State` copies that go stale if anything else changes settings.
- `PNGWriter`: encode to `Data`, then do an atomic write. That gives the real POSIX reason (disk full, etc.) and no partial files.
- Keep one pixel-size function and one scale source. `DisplayGeometry.pixelSize` and `ScreenCapturer.pixelSize(of:scale:)` duplicate each other, and area capture takes its scale from `NSScreen` while display capture takes it from ScreenCaptureKit.
- `CapturableWindow.title` / `appName` are unused. Use them in the picker or drop them.
- Add a pasteboard seam so the clipboard path is testable (with the quick-access Copy button).
- Test gap: the build-label test doesn't prove CI stamping. Add a `plutil -extract` gate on the Release plist in CI.

## Quick-access overlay (PR #1)

Gaps the PR listed as not fixed:

- The expanded/collapsed state is shared by all displays. Expanding one pile expands the others.
- Growing the cards while the column is open can push it past the top of the screen. Oldest cards are trimmed only when a capture arrives.
- `ThumbnailPresenter.showError` duplicates the activate and hand-back logic in `NSAlertPresenter`.
- With auto-hide on, a card can be removed mid drag-out or while Save As is open. Nothing breaks, but the card goes.
- The upload button and the annotation editor are not built. Annotate opens Preview for now.

Other follow-ups:

- CI builds with Xcode 16.4, so only the macOS 15 fallback of the glass look is compiled in CI. Moving CI to Xcode 26 would cover the `NSGlassEffectView` path too.
- The resize cursor uses the private WindowServer property `SetsCursorInBackground`. If a macOS update drops it, only the cursor hint is lost. Check this on each new macOS major.
- `onSaved` returns the file after it is saved. OCR still needs a capture that skips saving, so the capture and delivery split above is still open.

## macOS 15 private window picker prompt

- On macOS 15, the first capture shows "Glint is requesting to bypass the system private window picker and directly access your screen and audio", on top of the Screen Recording grant (seen in CI run 45266766603). CI pre-approves it in `ScreenCaptureApprovals.plist`; real users will see it and macOS re-asks periodically. Decide whether to live with it or route some captures through `SCContentSharingPicker`.

## Plan 6 (release)

- Sign nested code from the inside out. With a self-signed certificate (no Team ID), hardened runtime library validation will likely block dynamic frameworks such as Sparkle. Check this before adding one.
- Moving to Developer ID changes the designated requirement, so users grant Screen Recording again once. Say so in the release notes.
- Pin GitHub Actions by SHA. Same-repo PRs can edit `scripts/sign-and-zip.sh`, which runs with the signing secrets.
- `sign-and-zip.sh`: read the keychain list into an array (it is word-split today).
- The `app-macos` job's `swift test` uses the runner's toolchain. Only `core-linux` pins Swift.

## Needs a real Mac (see `docs/qa/plan-1-checklist.md`)

- Window capture with shadow: compare pixel size against `screencapture -w`.
- Esc and the crosshair on the non-activating overlay while another app stays frontmost.
- First-run "Open System Settings": can it show the system prompt and Settings at the same time?
- Settings window comes to front from the menu bar.
