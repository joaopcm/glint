# Glint

Open source screenshot and screen recording app for macOS.

## Features

- Capture an area (`⇧⌘2`), a window (`⌃⇧⌘2`) or the full screen (`⇧⌘1`) to a PNG in your save folder
- Capture Text (`⌥⇧⌘2`): drag over any text on screen and it goes to the clipboard as plain text. Recognition runs on-device, and nothing is saved to disk
- Quick-access thumbnail after each capture: copy, upload, save as, annotate, pin or drag it out
- Upload to your own S3-compatible bucket (AWS S3, Cloudflare R2, MinIO, ...): one click puts the capture there and its public link on the clipboard. Turn on Upload after capture in Settings to skip the click. Your bucket is the only place Glint ever sends anything
- Every shortcut can be changed in Settings

## Status

Early development. Not usable yet.

The work left lives in [GitHub issues](https://github.com/joaopcm/glint/issues), grouped by milestone and sorted by the `priority: p1` to `p3` labels. Each issue has its requirements and acceptance criteria, so it can be picked up on its own.

## Build

Requires macOS 15+, Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
open Glint.xcodeproj
```

## Test

On macOS, run all three suites:

```sh
xcodegen generate && xcodebuild -scheme Glint -destination 'platform=macOS' test
(cd Packages/GlintCore && swift test)
(cd Packages/GlintCapture && swift test)
```

UI tests drive the real app: they press the hotkeys, drag and click, so they take over the keyboard and pointer while they run. The first local run needs Screen Recording granted to the Debug build, and Accessibility granted to `GlintUITests-Runner` so it can press the hotkeys.

```sh
xcodegen generate && xcodebuild -scheme GlintUI -destination 'platform=macOS' test
```

`GlintCore` also builds and tests on Linux. The app and `GlintCapture` need macOS.

## Install a dev build

Every CI run uploads a signed `Glint-<short-sha>` artifact. All builds share one signing certificate, so the Screen Recording permission survives updates.

You unzip twice: GitHub wraps every artifact in its own zip, and inside it is `Glint.zip`, which `ditto` made so the signed bundle keeps its signature and extended attributes.

1. Download the artifact from the latest green run of the `ci` workflow and unzip it.
2. Unzip `Glint.zip` and move `Glint.app` to `/Applications`.
3. Clear the quarantine flag:

```sh
xattr -d com.apple.quarantine /Applications/Glint.app
```

## License

MIT
