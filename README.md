# Glint

Open source screenshot and screen recording app for macOS.

## Features

- Capture an area (`⇧⌘2`), a window (`⌃⇧⌘2`) or the full screen (`⇧⌘1`) to a PNG in your save folder
- Capture Text (`⌥⇧⌘2`): drag over any text on screen and it goes to the clipboard as plain text. Recognition runs on-device, and nothing is saved to disk
- Record an area (`⌥⇧⌘5`) or a window (`⌃⌥⇧⌘5`) to an MP4 (H.264, or HEVC in Settings). Stop from the menu bar or press the shortcut again. System audio and microphone are separate toggles in the menu, both off by default
- Quick-access thumbnail after each capture: copy, upload, save as, annotate, pin or drag it out
- Upload to your own S3-compatible bucket (AWS S3, Cloudflare R2, MinIO, ...): one click puts the capture there and its public link on the clipboard. Turn on Upload after capture in Settings to skip the click. Your bucket is the only place Glint ever sends anything
- Every shortcut can be changed in Settings

## Performance

Measured 2026-11-24 on an M4 Pro, macOS 27.2.1: idle memory 19 MB vs 55 MB for CleanShot X (median of 3 launches); area overlay 36.1 ms median from hotkey vs 100.5 ms for CleanShot X. Latency is to the window server showing the overlay, not to photons on screen, and CleanShot X was triggered through its URL API, which adds time to its number only. Details in [#3](https://github.com/joaopcm/glint/issues/3#issuecomment-7145993290).

## Status

Early development. Not usable yet.

The work left lives in [GitHub issues](https://github.com/joaopcm/glint/issues), grouped by milestone and sorted by the `priority: p1` to `p3` labels. Each issue has its requirements and acceptance criteria, so it can be picked up on its own.

## Build

Runs on macOS 15+. Building needs Xcode 26+ (the macOS 26 SDK) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

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

A local UI test run quits your installed Glint and doesn't relaunch it, and the Copy test overwrites your clipboard.

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

## Install a local build

```sh
scripts/install-local.sh
```

Builds Release from your checkout, installs it to `~/Applications/Glint.app`, and relaunches Glint if it was running. It signs with a code-signing identity named `Glint Local Dev` (override with `GLINT_SIGN_IDENTITY`), so Screen Recording and Microphone permissions survive rebuilds. `GLINT_SIGN_IDENTITY=-` signs ad-hoc instead, and the permissions reset on every install.

Create the identity once. It's self-signed, trusted only for code signing on your Mac, and the keys never touch the repo:

```sh
d="$(mktemp -d)"
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=Glint Local Dev" \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" \
  -keyout "$d/key.pem" -out "$d/cert.pem"
/usr/bin/openssl pkcs12 -export -inkey "$d/key.pem" -in "$d/cert.pem" -name "Glint Local Dev" \
  -passout pass:glint -out "$d/id.p12"
security import "$d/id.p12" -k ~/Library/Keychains/login.keychain-db -P glint -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db "$d/cert.pem"
rm -rf "$d"
```

`security find-identity -v -p codesigning` should now list `"Glint Local Dev"`.

## License

MIT
