#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<MSG
usage:
  $0 --check-secrets          fail unless every release secret is set
  $0 --dry-run <out-dir>      build, sign ad-hoc and package a DMG; no secrets, no notarization
  $0 <out-dir>                build, sign with Developer ID, notarize, staple and package a DMG
env:
  RELEASE_TAG    optional; when set (vX.Y.Z) it must match CFBundleShortVersionString in App/Info.plist
  BUILD_NUMBER   CFBundleVersion, default 0
MSG
  exit 1
}

required_secrets=(DEVELOPER_ID_P12_BASE64 DEVELOPER_ID_P12_PASSWORD NOTARY_API_KEY_P8_BASE64 NOTARY_API_KEY_ID NOTARY_API_ISSUER_ID)

check_secrets() {
  local missing=()
  for var in "${required_secrets[@]}"; do
    [[ -n "${!var:-}" ]] || missing+=("$var")
  done
  (( ${#missing[@]} == 0 )) && return 0
  echo "error: release secrets missing: ${missing[*]}" >&2
  echo "add each one under Settings > Secrets and variables > Actions; README.md \"Release\" says how to create it:" >&2
  for var in "${missing[@]}"; do
    case "$var" in
      DEVELOPER_ID_P12_BASE64) echo "  $var: base64 of the Developer ID Application certificate + private key exported as .p12" >&2 ;;
      DEVELOPER_ID_P12_PASSWORD) echo "  $var: the password the .p12 was exported with" >&2 ;;
      NOTARY_API_KEY_P8_BASE64) echo "  $var: base64 of the App Store Connect API key file (AuthKey_<id>.p8)" >&2 ;;
      NOTARY_API_KEY_ID) echo "  $var: that API key's Key ID" >&2 ;;
      NOTARY_API_ISSUER_ID) echo "  $var: the Issuer ID shown above the App Store Connect API keys list" >&2 ;;
    esac
  done
  exit 1
}

dry_run=false
case "${1:-}" in
  --check-secrets) [[ $# -eq 1 ]] || usage; check_secrets; echo "all release secrets are set"; exit 0 ;;
  --dry-run) dry_run=true; shift ;;
esac
[[ $# -eq 1 ]] || usage
out_dir="$1"

[[ "$dry_run" == true ]] || check_secrets

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
entitlements="$repo_root/App/Lunetta.entitlements"

version="$(plutil -extract CFBundleShortVersionString raw App/Info.plist)"
if [[ -n "${RELEASE_TAG:-}" && "$RELEASE_TAG" != "v$version" ]]; then
  echo "error: tag $RELEASE_TAG doesn't match CFBundleShortVersionString $version in App/Info.plist; bump it to ${RELEASE_TAG#v} or tag v$version" >&2
  exit 1
fi

work_dir="$(mktemp -d)"
keychain="$work_dir/lunetta-release.keychain-db"
original_keychains=()
cleanup() {
  if [[ -f "$keychain" ]]; then
    security list-keychains -d user -s ${original_keychains[@]+"${original_keychains[@]}"} >/dev/null 2>&1 || true
    security delete-keychain "$keychain" >/dev/null 2>&1 || true
  fi
  rm -rf "$work_dir"
}
trap cleanup EXIT

xcodegen generate
xcodebuild -scheme Lunetta -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$work_dir/dd" -quiet \
  CURRENT_PROJECT_VERSION="${BUILD_NUMBER:-0}" LUNETTA_COMMIT="$(git rev-parse --short HEAD)" build

mkdir -p "$out_dir"
app="$out_dir/Lunetta.app"
rm -rf "$app"
ditto "$work_dir/dd/Build/Products/Release/Lunetta.app" "$app"

if [[ "$dry_run" == true ]]; then
  identity="-"
  timestamp="--timestamp=none"
else
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line#\"}"
    original_keychains+=("${line%\"}")
  done < <(security list-keychains -d user)
  keychain_password="$(uuidgen)"
  echo "$DEVELOPER_ID_P12_BASE64" | base64 --decode > "$work_dir/cert.p12"
  security create-keychain -p "$keychain_password" "$keychain"
  security set-keychain-settings -lut 3600 "$keychain"
  security unlock-keychain -p "$keychain_password" "$keychain"
  security import "$work_dir/cert.p12" -k "$keychain" -P "$DEVELOPER_ID_P12_PASSWORD" -T /usr/bin/codesign
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" >/dev/null
  security list-keychains -d user -s "$keychain" ${original_keychains[@]+"${original_keychains[@]}"}
  identities="$(security find-identity -v -p codesigning "$keychain")"
  identity="$(awk '/"Developer ID Application: / {print $2; exit}' <<<"$identities")"
  if [[ -z "$identity" ]]; then
    echo "error: DEVELOPER_ID_P12_BASE64 holds no valid \"Developer ID Application\" identity; export that certificate with its private key. found:" >&2
    echo "$identities" >&2
    exit 1
  fi
  timestamp="--timestamp"
  echo "$NOTARY_API_KEY_P8_BASE64" | base64 --decode > "$work_dir/notary.p8"
fi

sign() {
  codesign --force --options runtime "$timestamp" --sign "$identity" "$@"
}

nested_code=()
while IFS= read -r path; do
  nested_code+=("$path")
done < <(find "$app/Contents" -depth \( -name '*.framework' -o -name '*.dylib' -o -name '*.xpc' -o -name '*.appex' -o -name '*.app' \) -print)
for path in ${nested_code[@]+"${nested_code[@]}"}; do
  sign "$path"
done
sign --entitlements "$entitlements" "$app"

codesign --verify --deep --strict --verbose=2 "$app"
codesign -d --entitlements - --xml "$app" > "$work_dir/entitlements.plist" 2>/dev/null
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$work_dir/entitlements.plist" >/dev/null 2>&1; then
  echo "error: $app still carries com.apple.security.get-task-allow; notarization rejects it" >&2
  exit 1
fi
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$work_dir/entitlements.plist" 2>&1)" == true ]] || {
  echo "error: $app lost com.apple.security.device.audio-input while re-signing; check $entitlements" >&2
  exit 1
}
[[ "$(codesign -dv "$app" 2>&1)" =~ flags=[^[:space:]]*[\(,]runtime[\),] ]] || { echo "error: $app is signed without the hardened runtime" >&2; exit 1; }

notarize() {
  local file="$1"
  xcrun notarytool submit "$file" --key "$work_dir/notary.p8" --key-id "$NOTARY_API_KEY_ID" --issuer "$NOTARY_API_ISSUER_ID" \
    --wait --output-format plist > "$work_dir/notary.plist"
  local id status
  id="$(plutil -extract id raw "$work_dir/notary.plist")"
  status="$(plutil -extract status raw "$work_dir/notary.plist")"
  if [[ "$status" != Accepted ]]; then
    echo "error: notarization of $(basename "$file") ended $status (submission $id). Apple's log:" >&2
    xcrun notarytool log "$id" --key "$work_dir/notary.p8" --key-id "$NOTARY_API_KEY_ID" --issuer "$NOTARY_API_ISSUER_ID" >&2 || true
    exit 1
  fi
  echo "notarized $(basename "$file") (submission $id)"
}

if [[ "$dry_run" == false ]]; then
  ditto -c -k --keepParent "$app" "$work_dir/Lunetta.zip"
  notarize "$work_dir/Lunetta.zip"
  xcrun stapler staple "$app"
fi

dmg="$out_dir/Lunetta-$version.dmg"
rm -f "$dmg"
mkdir "$work_dir/dmg"
ditto "$app" "$work_dir/dmg/Lunetta.app"
ln -s /Applications "$work_dir/dmg/Applications"
if [[ -n "${DMG_EXPERIMENT:-}" ]]; then
  { ps -Ao pid,pcpu,rss,comm | sort -k2 -nr | head -8; vm_stat | head -6; mdutil -s / 2>&1 | head -3; } || true
  exp() { local label="$1"; shift; local c=0; "$@" >/dev/null 2>&1 || c=$?; hdiutil verify "$dmg" >/dev/null 2>&1 && echo "== $label create=$c verify=OK" || echo "== $label create=$c verify=FAILED"; rm -f "$dmg"; }
  exp convert-first bash -c "hdiutil create -volname 'Lunetta $version' -srcfolder '$work_dir/dmg' -fs HFS+ -format UDRW -ov '$work_dir/rw.dmg' && hdiutil convert '$work_dir/rw.dmg' -format UDZO -ov -o '$dmg'"
  exp udzo-second hdiutil create -volname "Lunetta $version" -srcfolder "$work_dir/dmg" -fs HFS+ -format UDZO -ov "$dmg"
  exp ulfo-third hdiutil create -volname "Lunetta $version" -srcfolder "$work_dir/dmg" -fs HFS+ -format ULFO -ov "$dmg"
  exp udzo-fourth hdiutil create -volname "Lunetta $version" -srcfolder "$work_dir/dmg" -fs HFS+ -format UDZO -ov "$dmg"
  { ps -Ao pid,pcpu,rss,comm | sort -k2 -nr | head -5; } || true
fi
hdiutil create -volname "Lunetta $version" -srcfolder "$work_dir/dmg" -fs HFS+ -format UDZO -ov "$dmg" >/dev/null

if [[ "$dry_run" == false ]]; then
  sign "$dmg"
  notarize "$dmg"
  xcrun stapler staple "$dmg"
fi

hdiutil verify "$dmg" >/dev/null
mount_point="$work_dir/mnt"
mkdir "$mount_point"
hdiutil attach "$dmg" -readonly -nobrowse -mountpoint "$mount_point" >/dev/null
codesign --verify --deep --strict "$mount_point/Lunetta.app" || { hdiutil detach "$mount_point" >/dev/null; echo "error: Lunetta.app inside $dmg fails codesign --verify" >&2; exit 1; }
hdiutil detach "$mount_point" >/dev/null

if [[ "$dry_run" == false ]]; then
  spctl -a -vv "$app"
  spctl -a -vv -t open --context context:primary-signature "$dmg"
  xcrun stapler validate "$app"
  xcrun stapler validate "$dmg"
fi

echo "built $dmg ($([[ "$dry_run" == true ]] && echo "dry run, ad-hoc signed, not notarized" || echo "Developer ID signed, notarized, stapled"))"
