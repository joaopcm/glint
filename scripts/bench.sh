#!/usr/bin/env bash
set -euo pipefail

lunetta_app="$HOME/Applications/Lunetta.app"
cleanshot_ids="com.getcleanshot.app-setapp pl.maketheweb.cleanshotx"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

die() {
  echo "error: $*" >&2
  exit 1
}

[[ "$(uname)" == Darwin ]] || die "the benchmark runs on macOS only"

ref="origin/main"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref)
      [[ $# -ge 2 ]] || die "--ref needs a git ref, e.g. --ref my-branch"
      ref="$2"
      shift 2
      ;;
    *) die "unknown argument: $1. usage: scripts/bench.sh [--ref <git ref>] (default: origin/main)" ;;
  esac
done

cleanshot_app=""
for id in $cleanshot_ids; do
  cleanshot_app="$(mdfind "kMDItemCFBundleIdentifier == '$id'" | head -n 1)"
  if [[ -n "$cleanshot_app" ]]; then break; fi
done
[[ -n "$cleanshot_app" ]] || die "CleanShot X not found (looked for bundle ids: $cleanshot_ids). install it, through Setapp or directly, and rerun"
cleanshot_process="$(plutil -extract CFBundleExecutable raw "$cleanshot_app/Contents/Info.plist")"

work="$(mktemp -d)"
lunetta_was_running=false
cleanshot_was_running=false
pgrep -x Lunetta >/dev/null && lunetta_was_running=true
pgrep -x "$cleanshot_process" >/dev/null && cleanshot_was_running=true

restore() {
  git -C "$repo_root" worktree remove --force "$work/build" 2>/dev/null || true
  rm -rf "$work"
  if [[ "$lunetta_was_running" == true ]] && ! pgrep -x Lunetta >/dev/null; then open -g "$lunetta_app"; fi
  if [[ "$cleanshot_was_running" == true ]] && ! pgrep -x "$cleanshot_process" >/dev/null; then open -g "$cleanshot_app"; fi
}
trap restore EXIT

swiftc -O -swift-version 5 "$repo_root/scripts/bench/benchtool.swift" -o "$work/benchtool"
"$work/benchtool" check

git fetch --quiet origin main
git worktree add --detach --quiet "$work/build" "$ref"
"$work/build/scripts/install-local.sh"

report="$repo_root/docs/perf/$(date +%Y-%m-%d).md"
echo "measuring, about 15 min. you can keep working: each hotkey press waits for 3 s without input, and full-screen overlays flash briefly" >&2
"$work/benchtool" run \
  --lunetta "$lunetta_app" \
  --built-from "$ref" \
  --cleanshot "$cleanshot_app" \
  --report "$report" \
  --readme "$repo_root/README.md" >/dev/null

echo "wrote $report and updated README.md" >&2
