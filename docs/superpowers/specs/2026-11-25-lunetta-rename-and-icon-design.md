# Lunetta: rename and app icon

## Why

"Glint" doesn't stick. João wants a name that feels as deliberate as CleanShot, Resend or Vercel, and a visual identity to go with it, before the first public release (#30). Nobody else has the app installed yet, so this is the cheapest moment to change the name, the bundle ID and the look.

## Decisions already made

- **Name: Lunetta.** A *lunette* is a half-moon window; in French, *lunettes* are glasses. Glass, a window, looking. The domain doesn't matter for now.
- **Identity: minimal and calm, like a glass lens catching light.** João picked mockup **P1 · Clear glass**: a dark indigo tile, a large glass lens rising from the bottom-left and cropped by the tile edge, light glancing off its upper-right rim, and a four-point star glint above it.
- **Icon is built in Icon Composer format** (an `.icon` bundle), not a classic PNG set.
- **The rename is one PR.** The icon is a second PR. The GitHub repo is renamed to `joaopcm/lunetta` after both merge.
- **Clean break, no migration.** The bundle ID becomes `com.joaopcm.lunetta`, so macOS treats it as a new app. João grants Screen Recording again and re-enters his S3 keys and settings once. No migration code.

## Goals

1. Every user-visible and code-level "Glint" becomes "Lunetta", in the same casing (`Glint` → `Lunetta`, `glint` → `lunetta`, `GLINT_` → `LUNETTA_`).
2. The app ships with a real icon that matches P1 and looks native on macOS 26, with a good fallback on macOS 15.
3. The menu bar shows Lunetta's own mark instead of the `camera.viewfinder` SF Symbol.
4. CI stays green with the same required check names: `core-linux`, `app-macos`, `ui-macos`.

## Non-goals

- Migrating UserDefaults, Keychain items or TCC grants from `com.joaopcm.glint`.
- Renaming the signing certificates "Glint Local Dev" (`install-local.sh`) and "Glint Development" (`run-dev.sh`, `make-dev-cert.sh`, the `DEV_CERT_P12_BASE64` secret). They're labels, and renaming them means new certs and a new repo secret. *(Builder's call, extended from João's decision on "Glint Local Dev".)*
- Updating `github.com/joaopcm/glint` links in code and README before the repo rename. GitHub redirects them; the icon PR, which lands after the repo rename, points them at `joaopcm/lunetta`. *(Builder's call.)*
- Rewriting history: past commits, merged PRs, closed issues and release notes keep saying Glint.
- A domain, website or in-app restyle (accent colors, typography).

## Anti-goals

- An icon that reads as a CleanShot copy: no curved blade from the bottom-left in CleanShot's blue. Ours is a circle (a lens), in indigo/violet, with a star glint.
- Hand-painted highlights fighting the system's glass. In Icon Composer, macOS draws the specular edge and lighting; the layers should be flat shapes so the system light is the only light.
- Required CI check names changing, which would silently block every PR on branch protection.

## Approaches considered

**Icon**
- *Classic image set* rendered from the P1 SVG: looks exactly like the mockup everywhere, but on macOS 26 it gets no tinted/clear styles and no system glass. Not picked.
- *Icon Composer `.icon`* (picked by João): layered source; macOS 26 renders it as native glass, and `actool` generates an `.icns` fallback for older macOS. Verified in a spike: a hand-written `AppIcon.icon` (`icon.json` + SVG layers) compiled with `xcrun actool --platform macosx --minimum-deployment-target 15.0 --app-icon AppIcon` produced `AppIcon.icns` (16–256 pt) plus `Assets.car`, and set `CFBundleIconFile`/`CFBundleIconName` to `AppIcon`. The fallback image had the system glass edge baked in.

**Rename**
- *One PR* (picked): the codebase is never half-renamed, and reviewing a mechanical diff once is cheaper than twice.
- *Staged* (packages first, then app, then CI): smaller diffs, but main would carry mixed names for days. Not picked.

## Rename: what changes

Measured on `dc958ca`: "glint" appears 681 times across 109 tracked files.

- **Project:** `project.yml` (project name, targets `Glint`/`GlintTests`/`GlintUITests` → `Lunetta`/`LunettaTests`/`LunettaUITests`, schemes `Glint`/`GlintUI` → `Lunetta`/`LunettaUI`, bundle IDs `com.joaopcm.glint[.tests|.uitests]` → `com.joaopcm.lunetta[...]`). The generated `Glint.xcodeproj` is replaced by `Lunetta.xcodeproj`.
- **Packages:** `Packages/GlintCore`, `GlintCapture`, `GlintEditor` → `LunettaCore`, `LunettaCapture`, `LunettaEditor` (directories, `Package.swift` names, products, module imports, test targets).
- **Code:** type and file names (`GlintApp` → `LunettaApp`, `GlintUITestCase` → `LunettaUITestCase`, and the rest), the `MenuBarExtra` title, every user-facing string, the Keychain service name, notification and UserDefaults keys that embed the name.
- **Bucket policy:** `BucketPolicy.publicReadSid` `GlintPublicRead` → `LunettaPublicRead`, and the IAM policy text's `GlintUpload` → `LunettaUpload`. No cleanup of the old statement: after the rename, João deletes `GlintPublicRead` from his bucket policy by hand once (João's decision). The PR description says so.
- **Environment variables:** every `GLINT_*` → `LUNETTA_*` (`GLINT_SIGN_IDENTITY`, `GLINT_COMMIT`, `GLINT_EXECUTABLE`, the `GLINT_MINIO_*` and `GLINT_UI_TEST_*` set). The "Glint Local Dev" default identity name stays.
- **CI and release:** `.github/workflows/*.yml`, `.github/actions/*`, `scripts/*.sh` (bundle IDs passed to `ci-grant-tcc.sh`, app and zip and DMG names, the `ui-xcresult-*` paths). Job names `core-linux`, `app-macos`, `ui-macos` stay as they are.
- **Install:** `scripts/install-local.sh` installs to `~/Applications/Lunetta.app`. It also quits a running `Glint` and moves `~/Applications/Glint.app` to the Trash, so João doesn't end up with both.
- **Docs:** `README.md`, `LICENSE` holder line if it names the app.

**Done when:** `git grep -i glint` returns only the two certificate names, `github.com/joaopcm/glint` links, and this spec; `xcodegen generate`, the app tests, the UI tests and `swift test` in each package pass on CI.

## Icon: what gets built

`App/AppIcon.icon/` (Icon Composer format), referenced by the app target so `actool` compiles it:

- **Fill:** linear gradient top to bottom, `#2A2E6E` → `#090B22` (P1's tile).
- **Group 1, lens:** one SVG layer, a circle centered at (420, 650) with radius 400 on the 1024 canvas, cropped by the tile edge. Glass on. Fill is P1's lens gradient (light blue `#8EBBFF` toward the upper right, deep violet `#2A237A` toward the lower left), as a flat gradient with no painted highlights.
- **Group 2, glint:** one SVG layer, the four-point star at (718, 262) with the smaller star at (790, 371). Glass on, slight lift via the group's shadow so it reads above the tile.
- Dark and tinted appearances use Icon Composer's defaults unless they look wrong, in which case add an appearance-specific fill.

The icon is checked by eye in two places: compiled into the app on macOS 26 (Dock, Finder, Settings) and as the generated `.icns` at 16, 32, 128 and 256 pt.

## Menu bar icon

A template image asset (SVG with "Preserves Vector Data", rendered as template) replacing `camera.viewfinder` in `MenuBarExtra`: a rising arc (the lens edge) with a small four-point glint above it, from the P1 mockup. 18 × 18 pt, 1.8 pt main stroke. Starting geometry, from the mockup João approved:

```svg
<svg viewBox="0 0 18 18" fill="none" stroke="currentColor" stroke-linecap="round">
  <path d="M2 16 A9.5 9.5 0 0 1 13.5 6.5" stroke-width="1.8"/>
  <path d="M5 16 A6.5 6.5 0 0 1 12 9.6" stroke-width="1.2" opacity=".5"/>
  <path d="M14.5 1.5 Q14.7 3.8 17 4 Q14.7 4.2 14.5 6.5 Q14.3 4.2 12 4 Q14.3 3.8 14.5 1.5 Z" fill="currentColor" stroke="none"/>
</svg>
```

Template images keep alpha, so the half-opacity secondary arc survives; check that it still reads at real size. It must stay legible on light and dark menu bars and when highlighted.

## Constraints

- Minimum macOS stays 15.0. CI builds with Xcode 26.6 (`.github/actions/setup-xcode`), which supports `.icon`.
- The bundle ID change resets TCC, Keychain and UserDefaults for João's install. The CI TCC grants in `ci.yml` must use the new bundle IDs or every UI test fails on the permission prompt.
- UI tests can't be run locally: they take over the mouse and keyboard. CI is the only place they run.
- No comments in code except "why" comments with receipts.

## Left to the builder

- Exact order of renames inside the PR and how to keep each commit building.
- The final SVG geometry and gradient stops for the icon layers, as long as the result reads as P1 at 1024 and at 32 pt.
- Whether the menu bar glyph's secondary arc stays or goes once seen at real size.
