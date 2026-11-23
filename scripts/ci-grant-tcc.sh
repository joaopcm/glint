#!/usr/bin/env bash
# CI only: GitHub's macOS runners let sudo write the system TCC database (proved by spike run 45262298278).
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <kTCCService...> <bundle-id>..." >&2
  exit 2
fi

db="/Library/Application Support/com.apple.TCC/TCC.db"
service=$1
shift

for id in "$@"; do
  sudo sqlite3 "$db" "insert or replace into access (service, client, client_type, auth_value, auth_reason, auth_version, indirect_object_identifier, flags) values ('$service', '$id', 0, 2, 4, 1, 'UNUSED', 0);"
  granted=$(sudo sqlite3 "$db" "select auth_value from access where service = '$service' and client = '$id';")
  if [ "$granted" != "2" ]; then
    echo "TCC grant missing: $service for $id in $db (auth_value '$granted'); the UI tests depend on it" >&2
    exit 1
  fi
  echo "granted $service to $id"
done

sudo automationmodetool enable-automationmode-without-authentication
