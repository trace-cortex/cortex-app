#!/usr/bin/env bash
# Install the single-user Cortex backend as a macOS launchd LaunchAgent (starts at login,
# restarts on crash, survives logout/login cycles). User-scoped: no sudo, fully reversible
# with deploy/launchd/uninstall.sh.
#
#   deploy/launchd/install.sh [--mode fastapi|standalone] [--dry-run]
#
# Prerequisites: scripts/setup_local.sh has been run (./.venv and ./.env exist).
# Logs:          .run/launchd.out.log and .run/launchd.err.log in the repo.
# Label:         com.cortex.local.backend
#
# For a headless machine, also enable Automatic Login (System Settings > Users & Groups) and
# `sudo pmset -c sleep 0 disksleep 0 autorestart 1`, or promote the plist to /Library/LaunchDaemons.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LABEL="${CORTEX_LAUNCHD_LABEL:-com.cortex.local.backend}"
AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST="$AGENTS_DIR/$LABEL.plist"
ENV_FILE="${CORTEX_ENV_FILE:-$ROOT/.env}"
RUN_DIR="$ROOT/.run"
MODE="${CORTEX_SERVER_MODE:-fastapi}"
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE missing; run scripts/setup_local.sh first" >&2; exit 1; }
[[ -x "$ROOT/.venv/bin/python" ]] || { echo "ERROR: $ROOT/.venv missing; run scripts/setup_local.sh first" >&2; exit 1; }
mkdir -p "$AGENTS_DIR" "$RUN_DIR"

# If a foreground/background copy started by scripts/start_backend.sh is running, stop it so the
# service does not fight it for the port.
if [[ -f "$RUN_DIR/backend.pid" ]] && kill -0 "$(cat "$RUN_DIR/backend.pid")" 2>/dev/null; then
  echo "==> stopping the manually started backend first"
  "$ROOT/scripts/stop_backend.sh"
fi

cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$ROOT/scripts/start_backend.sh</string>
    <string>--foreground</string>
    <string>--mode</string>
    <string>$MODE</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>CORTEX_ENV_FILE</key><string>$ENV_FILE</string>
    <key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>WorkingDirectory</key><string>$ROOT</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>StandardOutPath</key><string>$RUN_DIR/launchd.out.log</string>
  <key>StandardErrorPath</key><string>$RUN_DIR/launchd.err.log</string>
  <key>ProcessType</key><string>Background</string>
</dict>
</plist>
EOF
plutil -lint "$PLIST" >/dev/null
echo "==> wrote $PLIST (mode: $MODE)"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "==> dry run: not loaded. Load with: launchctl load -w \"$PLIST\""
  exit 0
fi

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load -w "$PLIST"
echo "==> loaded $LABEL; waiting for health"
for _ in $(seq 1 60); do
  if "$ROOT/scripts/health_check.sh" --quiet; then
    "$ROOT/scripts/health_check.sh"
    cat <<EOT

Service installed.
  status : launchctl list | grep $LABEL
  logs   : tail -f $RUN_DIR/launchd.err.log
  stop   : launchctl unload "$PLIST"        (start again with: launchctl load -w "$PLIST")
  remove : deploy/launchd/uninstall.sh
EOT
    exit 0
  fi
  sleep 1
done
echo "ERROR: service did not become healthy; see $RUN_DIR/launchd.err.log" >&2
tail -n 30 "$RUN_DIR/launchd.err.log" >&2 || true
exit 1
