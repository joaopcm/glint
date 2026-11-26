# Lunetta

Open source screenshot and screen recording app for macOS.

## Features

- Capture an area (`⇧⌘2`), a window (`⌃⇧⌘2`) or the full screen (`⇧⌘1`) to a PNG in your save folder, with the macOS shutter sound (off in Settings)
- Capture Text (`⌥⇧⌘2`): drag over any text on screen and it goes to the clipboard as plain text. Recognition runs on-device, and nothing is saved to disk. Plays the same shutter sound
- Record an area (`⌥⇧⌘5`) or a window (`⌃⌥⇧⌘5`) to an MP4 (H.264, or HEVC in Settings). A 3 s countdown comes first (Esc cancels it, a click on it starts right away), and everything outside a recorded area dims. While recording, floating controls pause, resume, stop and discard, and the menu bar shows the recorded time; click it or press the shortcut again to stop. None of it shows up in the recording. Countdown and sounds can be turned off in Settings. Record Screen… (`⌥⇧⌘6`) lets you pick an area and keeps it up before recording: drag its grips to resize it, drag inside to move it (or nudge it with the arrow keys), and set system audio, microphone and which input, pressed keys and click highlights in the toolbar under it. Return or Record starts the countdown, Esc drops it. Choices start off and are remembered for the next recording. Record Area, Record Window and their shortcuts skip the stage and use its last choices. If a choice needs a permission Lunetta doesn't have (Microphone, or Input Monitoring for pressed keys), the toolbar says which and won't record until it's fixed
- Quick-access thumbnail after each capture: copy, upload, save as, annotate, pin or drag it out
- Upload to your own S3-compatible bucket (AWS S3, Cloudflare R2, MinIO, ...): one click puts the capture there and its public link on the clipboard. Turn on Upload after capture in Settings to skip the click. Your bucket is the only place Lunetta ever sends anything
- Compress after capture (off by default, in Settings): each capture shrinks on this Mac before it's copied or uploaded, and its thumbnail says by how much. Screenshots become PNGs of up to 256 colors, recordings are encoded again in their own format, and a capture that wouldn't get smaller stays as saved
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
open Lunetta.xcodeproj
```

## Test

On macOS, run all three suites:

```sh
xcodegen generate && xcodebuild -scheme Lunetta -destination 'platform=macOS' test
(cd Packages/LunettaCore && swift test)
(cd Packages/LunettaCapture && swift test)
```

UI tests drive the real app: they press the hotkeys, drag and click, so they take over the keyboard and pointer while they run. The first local run needs Screen Recording granted to the Debug build, and Accessibility granted to `LunettaUITests-Runner` so it can press the hotkeys.

```sh
xcodegen generate && xcodebuild -scheme LunettaUI -destination 'platform=macOS' test
```

A local UI test run quits your installed Lunetta and doesn't relaunch it, and the Copy test overwrites your clipboard.

`LunettaCore` also builds and tests on Linux. The app and `LunettaCapture` need macOS.

## Install a dev build

Every CI run uploads a signed `Lunetta-<short-sha>` artifact. All builds share one signing certificate, so the Screen Recording permission survives updates.

You unzip twice: GitHub wraps every artifact in its own zip, and inside it is `Lunetta.zip`, which `ditto` made so the signed bundle keeps its signature and extended attributes.

1. Download the artifact from the latest green run of the `ci` workflow and unzip it.
2. Unzip `Lunetta.zip` and move `Lunetta.app` to `/Applications`.
3. Clear the quarantine flag:

```sh
xattr -d com.apple.quarantine /Applications/Lunetta.app
```

## Install a local build

```sh
scripts/install-local.sh
```

Builds Release from your checkout, installs it to `~/Applications/Lunetta.app`, and relaunches Lunetta if it was running. It signs with a code-signing identity named `Glint Local Dev` (override with `LUNETTA_SIGN_IDENTITY`), so Screen Recording and Microphone permissions survive rebuilds. `LUNETTA_SIGN_IDENTITY=-` signs ad-hoc instead, and the permissions reset on every install.

Create the identity once. It's self-signed, trusted only for code signing on your Mac, and the keys never touch the repo:

```sh
d="$(mktemp -d)"
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=Glint Local Dev" \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" \
  -keyout "$d/key.pem" -out "$d/cert.pem"
/usr/bin/openssl pkcs12 -export -inkey "$d/key.pem" -in "$d/cert.pem" -name "Glint Local Dev" \
  -passout pass:lunetta -out "$d/id.p12"
security import "$d/id.p12" -k ~/Library/Keychains/login.keychain-db -P lunetta -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db "$d/cert.pem"
rm -rf "$d"
```

`security find-identity -v -p codesigning` should now list `"Glint Local Dev"`.

## Release

Pushing a `v*` tag runs the `release` workflow: it builds Release, signs with Developer ID, notarizes and staples the app and a DMG, checks them with `spctl -a -vv` and `stapler validate`, and publishes `Lunetta-<version>.dmg` to GitHub Releases with the notes in `.github/release-notes.md`. Running it by hand from the Actions tab does the same but uploads the DMG as an artifact instead of publishing. The tag has to match `CFBundleShortVersionString` in `App/Info.plist`, so bump that first.

Check the build and the DMG without any secrets:

```sh
scripts/release.sh --dry-run dist
```

It signs ad-hoc and skips notarization, but checks everything else: nested code signed inside out, hardened runtime on, `get-task-allow` gone (notarization rejects it, and Xcode's ad-hoc Release builds carry it), and the app inside the DMG still verifies. PRs that touch the release files run it in the `release-dry-run` workflow.

The workflow stops before building if any of these repo secrets is missing, and names each one. They all need a paid Apple Developer Program membership:

| Secret | How to get it |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | In Xcode > Settings > Accounts > Manage Certificates, add a "Developer ID Application" certificate. In Keychain Access, export it with its private key as a `.p12`, then `base64 -i cert.p12 \| gh secret set DEVELOPER_ID_P12_BASE64` |
| `DEVELOPER_ID_P12_PASSWORD` | The password you set on that export: `gh secret set DEVELOPER_ID_P12_PASSWORD` |
| `NOTARY_API_KEY_P8_BASE64` | In App Store Connect > Users and Access > Integrations > App Store Connect API, create a team key with the Developer role and download `AuthKey_<id>.p8` (only downloadable once), then `base64 -i AuthKey_<id>.p8 \| gh secret set NOTARY_API_KEY_P8_BASE64` |
| `NOTARY_API_KEY_ID` | The Key ID next to that key |
| `NOTARY_API_ISSUER_ID` | The Issuer ID above the keys list |

Moving from the dev certificate to Developer ID changes Lunetta's designated requirement, so everyone grants Screen Recording (and Microphone) once more after installing the first release. The release notes say so.

## License

MIT
