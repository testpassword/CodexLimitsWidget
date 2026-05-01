#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_SOURCE="$ROOT/build/Codex Limits.app"
APP_TARGET="/Applications/Codex Limits.app"
OLD_APP_TARGET="/Applications/CodexLimits.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$ROOT/build-widget.sh" >/dev/null
pkill -f "$APP_TARGET" 2>/dev/null || true
pkill -f "$OLD_APP_TARGET" 2>/dev/null || true
rm -rf "$APP_TARGET"
rm -rf "$OLD_APP_TARGET"
ditto "$APP_SOURCE" "$APP_TARGET"
"$LSREGISTER" -f "$APP_TARGET"
open "$APP_TARGET"
echo "$APP_TARGET"
