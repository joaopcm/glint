#!/usr/bin/env bash
set -euo pipefail

identity="${LUNETTA_SIGN_IDENTITY:-Glint Local Dev}"
bundle_id="com.joaopcm.lunetta"
install_dir="$HOME/Applications"
installed_app="$install_dir/Lunetta.app"
legacy_name="Glint"
legacy_bundle_id="com.joaopcm.glint"
legacy_app="$install_dir/$legacy_name.app"
quit_timeout_seconds=10

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [[ "$identity" == "-" ]]; then
  echo "warning: LUNETTA_SIGN_IDENTITY=- signs ad-hoc; Screen Recording and Microphone permissions reset on every install" >&2
elif ! security find-identity -v -p codesigning | grep -qF "\"$identity\""; then
  cat >&2 <<MSG
error: no valid code-signing identity named "$identity" in the keychain.
create one with the steps in README.md under "Install a local build",
point LUNETTA_SIGN_IDENTITY at another identity from \`security find-identity -v -p codesigning\`,
or run with LUNETTA_SIGN_IDENTITY=- to sign ad-hoc (permissions reset on every install).
MSG
  exit 1
fi

derived_data="$(mktemp -d)"
trap 'rm -rf "$derived_data"' EXIT

commit="$(git rev-parse --short HEAD)"

xcodegen generate
xcodebuild -scheme Lunetta -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$derived_data" -quiet \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" LUNETTA_COMMIT="$commit" build

built_app="$derived_data/Build/Products/Release/Lunetta.app"

quit_and_wait() {
  local name="$1" id="$2"
  osascript -e "quit app id \"$id\""
  # Measured quit time: 0.08–0.16s over 3 runs on an M-series Mac. 10s only trips on a hung app.
  local waited=0
  while pgrep -x "$name" >/dev/null; do
    if (( waited >= quit_timeout_seconds * 10 )); then
      echo "error: $name still running ${quit_timeout_seconds}s after quit; quit it and rerun" >&2
      exit 1
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
}

was_running=false
if pgrep -x Lunetta >/dev/null; then
  was_running=true
  quit_and_wait Lunetta "$bundle_id"
fi
if pgrep -x "$legacy_name" >/dev/null; then
  was_running=true
  quit_and_wait "$legacy_name" "$legacy_bundle_id"
fi
if [[ -d "$legacy_app" ]]; then
  osascript -e "tell application \"Finder\" to delete POSIX file \"$legacy_app\"" >/dev/null
  echo "moved $legacy_app to the Trash"
fi

mkdir -p "$install_dir"
rm -rf "$installed_app"
ditto "$built_app" "$installed_app"

if [[ "$was_running" == true ]]; then
  open "$installed_app"
fi

echo "installed $installed_app"
echo "commit: $(plutil -extract LunettaCommit raw "$installed_app/Contents/Info.plist")"
codesign -d -r- "$installed_app" 2>&1 | grep '^designated'
