#!/usr/bin/env bash
# Build, sign with the local "Glint Development" cert, and (re)launch Glint.
# A stable signature keeps the Screen Recording permission across rebuilds; ad-hoc signing loses it.
# One-time setup (keys stay outside the repo):
#   d=~/.config/glint-dev-cert; mkdir -p "$d"; pw=$(openssl rand -hex 24)
#   openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=Glint Development" \
#     -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" \
#     -keyout "$d/glint-dev.key" -out "$d/glint-dev.pem"
#   openssl pkcs12 -export -legacy -inkey "$d/glint-dev.key" -in "$d/glint-dev.pem" -name "Glint Development" \
#     -passout "pass:$pw" -out "$d/glint-dev.p12"
#   security import "$d/glint-dev.p12" -k ~/Library/Keychains/login.keychain-db -P "$pw" -T /usr/bin/codesign
set -euo pipefail
cd "$(dirname "$0")/.."

cert="$(security find-certificate -c "Glint Development" -Z | awk '/^SHA-1 hash:/ {print $3; exit}')"
[[ -n "$cert" ]] || { echo "error: no 'Glint Development' certificate in the keychain (see header)" >&2; exit 1; }

xcodegen generate >/dev/null
# ENABLE_DEBUG_DYLIB=NO: the Debug-only Glint.debug.dylib would keep the old signature and fail library validation.
xcodebuild -scheme Glint -destination 'platform=macOS' -derivedDataPath build/dev build -quiet ENABLE_DEBUG_DYLIB=NO
# Separate derived data: `xcodebuild test` into ./build would overwrite this signed app with an ad-hoc one.
app=build/dev/Build/Products/Debug/Glint.app
codesign --force --options runtime --entitlements App/Glint.entitlements --sign "$cert" "$app"

pkill -f "$app/Contents/MacOS/Glint" || true
sleep 1
open "$app"
