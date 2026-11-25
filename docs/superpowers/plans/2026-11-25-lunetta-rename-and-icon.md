# Lunetta rename and icon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename Glint to Lunetta (PR 1), then ship the P1 app icon and menu bar mark (PR 2).

**Architecture:** PR 1 is a mechanical rename: `git mv` every path containing "Glint", then one case-preserving text substitution with the exempt strings shielded, plus one hand edit (install script cleans up the old app). PR 2 adds an Icon Composer bundle and an asset catalog to the `App` sources, which `actool` compiles.

**Tech Stack:** Swift 6, SwiftUI `MenuBarExtra`, XcodeGen 2.47.0, Xcode 26.6 on `macos-26` CI, Icon Composer `.icon` format.

**Spec:** `docs/superpowers/specs/2026-11-25-lunetta-rename-and-icon-design.md`

## Global Constraints

- `Glint` → `Lunetta`, `glint` → `lunetta`, `GLINT_` → `LUNETTA_`. Bundle IDs `com.joaopcm.lunetta[.tests|.uitests]`.
- Exempt: `Glint Local Dev`, `Glint Development`, `github.com/joaopcm/glint`, the spec, this plan.
- Required check names `core-linux`, `app-macos`, `ui-macos` don't change.
- Minimum macOS 15.0. No migration code. No code comments except "why" with receipts.
- Commits, PR text, issue text: write-like-joao, then humanizer. No Co-Authored-By, no "Generated with" line.
- Linux has no Xcode: only `swift test` in `Packages/LunettaCore` runs locally. CI verifies the rest.

## Review Focus

1. Content-length fixtures: `AppTests/URLSessionS3TransportCacheTests.swift` serves `glint\n` with `Content-Length: 6`; after the rename the body is 8 bytes. Fix the header to 8.
2. TCC grants in `ci.yml` use the new bundle IDs, or every UI test hangs on the permission prompt.
3. `Info.plist` key `GlintCommit` → `LunettaCommit` must change in the plist, `BuildInfo.swift`, `ci.yml` and `install-local.sh` together, or the build label check fails.
4. Installing over a machine with the old app: `install-local.sh` quits a running Glint and trashes `~/Applications/Glint.app`; when neither exists it does nothing and doesn't fail.
5. `.icon` is a directory with an extension: XcodeGen must add it as one file reference in Resources, not recurse into it.

---

## PR 1: rename

### Task 1: Issues

- [ ] File "Rename Glint to Lunetta" and "Give Lunetta its app icon and menu bar mark" in `joaopcm/glint` (text via write-like-joao + humanizer). Record both URLs.

### Task 2: Rename paths

**Files:** every tracked path containing `Glint` (`git ls-files | grep Glint`): `Packages/Glint{Core,Capture,Editor}` and their `Sources/`/`Tests/` subdirs, `App/GlintApp.swift`, `App/Glint.entitlements`, `GlintSettings.swift`, `GlintSettingsTests.swift`, `UITests/GlintUITestCase.swift`, `UITests/GlintUITests.entitlements`.

- [ ] `git mv` directories deepest first, then files, replacing `Glint` with `Lunetta` in the basename.
- [ ] Check: `git ls-files | grep -i glint` prints only the spec.

### Task 3: Rename contents

- [ ] Over `git grep -l -i glint` minus the spec and this plan: shield the three exempt strings with placeholders, apply `GLINT`→`LUNETTA`, `Glint`→`Lunetta`, `glint`→`lunetta`, unshield.
- [ ] Fix `Content-Length: 6` → `8` in `AppTests/URLSessionS3TransportCacheTests.swift` (Review Focus 1).
- [ ] Read the diff of comments the substitution touched; keep any that are still true.
- [ ] Check: `git grep -n -i glint` returns only the exempt strings, the spec, this plan.
- [ ] Check: `cd Packages/LunettaCore && swift test` passes (MinIO suites skip without `LUNETTA_MINIO_*`).

### Task 4: Install script retires the old app

**Files:** `scripts/install-local.sh`

- [ ] Before installing, if a process named `Glint` runs, quit it by bundle ID `com.joaopcm.glint` with the same wait loop and 10 s tripwire the Lunetta quit uses (receipt: the existing measured 0.08–0.16 s).
- [ ] If `~/Applications/Glint.app` exists, move it to the Trash through Finder (`osascript -e 'tell application "Finder" to delete POSIX file "…"'`) and print that it did.
- [ ] Check: `bash -n scripts/install-local.sh`. These two `Glint` mentions are the only ones outside the exemptions; the PR body says so.

### Task 5: Ship PR 1

- [ ] Commit (write-like-joao + humanizer), push `chore/rename-to-lunetta`, open PR closing the rename issue. Body tells João to delete `GlintPublicRead` from his bucket policy by hand after installing.
- [ ] CI green on `core-linux`, `app-macos`, `ui-macos` (rerun once on "job was not acquired by Runner"). Squash-merge, close issue.

## PR 2: icon

### Task 6: App icon

**Files:** Create `App/AppIcon.icon/icon.json`, `App/AppIcon.icon/Assets/lens.svg`, `App/AppIcon.icon/Assets/glint.svg`. Modify `project.yml` (`ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` on the app target).

- [ ] `icon.json`: fill `linear-gradient` `#2A2E6E` → `#090B22` top to bottom; group 1 = `lens.svg`, glass on; group 2 = `glint.svg`, glass on, neutral shadow; `supported-platforms.squares` includes macOS.
- [ ] `lens.svg`: 1024 viewBox, circle (420, 650) r 400, flat linear gradient `#8EBBFF` (upper right) → `#2A237A` (lower left), no highlights.
- [ ] `glint.svg`: 1024 viewBox, four-point star at (718, 262), small star at (790, 371), flat white.
- [ ] CI `app-macos` passes. Download `Lunetta-<sha>` artifact, check `Contents/Resources/AppIcon.icns` exists and Info.plist has `CFBundleIconFile`/`CFBundleIconName` = `AppIcon`.

### Task 7: Menu bar mark

**Files:** Create `App/Assets.xcassets/Contents.json`, `App/Assets.xcassets/MenuBarIcon.imageset/{Contents.json,MenuBarIcon.svg}`. Modify `App/LunettaApp.swift`.

- [ ] Imageset: the spec's SVG (18×18, `currentColor` → black), `template-rendering-intent: template`, `preserves-vector-representation: true`.
- [ ] `MenuBarExtra("Lunetta", image: "MenuBarIcon")` replaces `systemImage: "camera.viewfinder"`.
- [ ] If `joaopcm/lunetta` exists by now, point `github.com/joaopcm/glint` links at it.
- [ ] Ship as in Task 5 from a fresh branch off main. Report that nobody has looked at the icon yet.

## Unresolved questions

None blocking. Icon Composer's `icon.json` schema is written from memory; CI's `actool` is the judge.
