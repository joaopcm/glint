#!/usr/bin/env bash
set -euo pipefail

identity="${GLINT_SIGN_IDENTITY:-Glint Local Dev}"
bundle_id="com.joaopcm.glint"
install_dir="$HOME/Applications"
installed_app="$install_dir/Glint.app"
quit_timeout_seconds=10

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [[ "$identity" == "-" ]]; then
  echo "warning: GLINT_SIGN_IDENTITY=- signs ad-hoc; Screen Recording and Microphone permissions reset on every install" >&2
elif ! security find-identity -v -p codesigning | grep -qF "\"$identity\""; then
  cat >&2 <<MSG
error: no valid code-signing identity named "$identity" in the keychain.
create one with the steps in README.md under "Install a local build",
point GLINT_SIGN_IDENTITY at another identity from \`security find-identity -v -p codesigning\`,
or run with GLINT_SIGN_IDENTITY=- to sign ad-hoc (permissions reset on every install).
MSG
  exit 1
fi

derived_data="$(mktemp -d)"
trap 'rm -rf "$derived_data"' EXIT

commit="$(git rev-parse --short HEAD)"

xcodegen generate
xcodebuild -scheme Glint -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$derived_data" -quiet \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" GLINT_COMMIT="$commit" build

built_app="$derived_data/Build/Products/Release/Glint.app"

was_running=false
if pgrep -x Glint >/dev/null; then
  was_running=true
  osascript -e "quit app id \"$bundle_id\""
  # Measured quit time: 0.08–0.16s over 3 runs on an M-series Mac. 10s only trips on a hung app.
  waited=0
  while pgrep -x Glint >/dev/null; do
    if (( waited >= quit_timeout_seconds * 10 )); then
      echo "error: Glint still running ${quit_timeout_seconds}s after quit; quit it and rerun" >&2
      exit 1
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
fi

mkdir -p "$install_dir"
rm -rf "$installed_app"
ditto "$built_app" "$installed_app"

if [[ "$was_running" == true ]]; then
  open "$installed_app"
fi

echo "installed $installed_app"
echo "commit: $(plutil -extract GlintCommit raw "$installed_app/Contents/Info.plist")"
codesign -d -r- "$installed_app" 2>&1 | grep '^designated'
