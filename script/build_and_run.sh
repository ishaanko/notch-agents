#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="notch-agents"
BUNDLE_ID="app.notchagents.macos"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/build/Notch Agents.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/notch-agents"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
"$ROOT_DIR/scripts/package-app.sh" debug no-archive >/dev/null

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    for _ in {1..20}; do
      if pgrep -x "$APP_NAME" >/dev/null; then
        exit 0
      fi
      sleep 0.1
    done
    echo "Notch Agents did not start." >&2
    exit 1
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
