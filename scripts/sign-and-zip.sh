#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <app-path> <out-zip>" >&2
  exit 1
fi

app_path="$1"
out_zip="$2"
entitlements="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/App/Glint.entitlements"

for var in DEV_CERT_P12_BASE64 DEV_CERT_PASSWORD; do
  if [[ -z "${!var:-}" ]]; then
    echo "error: env var $var is not set (repo secret missing or unavailable to this run)" >&2
    exit 1
  fi
done
[[ -d "$app_path" ]] || { echo "error: app not found at $app_path" >&2; exit 1; }
[[ -f "$entitlements" ]] || { echo "error: entitlements not found at $entitlements" >&2; exit 1; }

work_dir="$(mktemp -d)"
keychain="$work_dir/glint-signing.keychain-db"
keychain_password="$(uuidgen)"
original_keychains="$(security list-keychains -d user | tr -d '"')"
cleanup() {
  security list-keychains -d user -s $original_keychains >/dev/null 2>&1 || true
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  rm -rf "$work_dir"
}
trap cleanup EXIT

echo "$DEV_CERT_P12_BASE64" | base64 --decode > "$work_dir/cert.p12"

security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 3600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$work_dir/cert.p12" -k "$keychain" -P "$DEV_CERT_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" >/dev/null

cert_hash="$(security find-certificate -a -Z "$keychain" | awk '/^SHA-1 hash:/ {print $3}')"
[[ -n "$cert_hash" ]] || { echo "error: no certificate found in keychain after importing the p12" >&2; exit 1; }

security list-keychains -d user -s "$keychain" $original_keychains

codesign --force --options runtime \
  --entitlements "$entitlements" \
  --sign "$cert_hash" --keychain "$keychain" \
  "$app_path"
codesign --verify --strict --verbose=2 "$app_path"

ditto -c -k --keepParent "$app_path" "$out_zip"
