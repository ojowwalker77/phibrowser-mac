#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/.derivedData"
APP_NAME="Lua"
APP_BUNDLE="$DERIVED_DATA/Build/Products/OpenSource/Lua.app"
BUNDLE_ID="dev.jow.LuaBrowser.Development"

"$ROOT_DIR/script/fetch_phi_framework.sh"

xcodebuild \
  -project "$ROOT_DIR/Phi.xcodeproj" \
  -scheme PhiBrowser-OpenSource \
  -configuration OpenSource \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

stop_running_lua() {
  # The development build uses an isolated profile. Still keep one writer per
  # profile so repeated local launches cannot race each other.
  # Chromium profiles are single-writer: never launch either app while another
  # Phi process still owns the profile lock.
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  for _ in {1..50}; do
    if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  echo "Lua is still running; quit it before launching the shared development profile." >&2
  return 1
}

open_app() {
  stop_running_lua
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    stop_running_lua
    lldb -- "$APP_BUNDLE/Contents/MacOS/Lua"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate 'process == "Lua"'
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
