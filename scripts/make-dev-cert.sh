#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <output-dir outside the repo>" >&2
  exit 1
fi

out_dir="$1"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "$(realpath -m "$out_dir")" in
  "$repo_root"|"$repo_root"/*)
    echo "error: output dir $out_dir is inside the repo; pick a path outside $repo_root" >&2
    exit 1
    ;;
esac

umask 077
mkdir -p "$out_dir"
chmod 700 "$out_dir"

password="$(openssl rand -hex 24)"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -subj "/CN=Glint Development" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -keyout "$out_dir/glint-dev.key" \
  -out "$out_dir/glint-dev.pem"

openssl pkcs12 -export -legacy \
  -inkey "$out_dir/glint-dev.key" \
  -in "$out_dir/glint-dev.pem" \
  -name "Glint Development" \
  -passout "pass:$password" \
  -out "$out_dir/glint-dev.p12"

base64 -w0 "$out_dir/glint-dev.p12" > "$out_dir/glint-dev.p12.base64"
printf '%s' "$password" > "$out_dir/glint-dev.password"

cat <<MSG
wrote to $out_dir:
  glint-dev.p12, glint-dev.p12.base64, glint-dev.password (plus .key/.pem)
set the repo secrets:
  gh secret set DEV_CERT_P12_BASE64 < $out_dir/glint-dev.p12.base64
  gh secret set DEV_CERT_PASSWORD < $out_dir/glint-dev.password
MSG
