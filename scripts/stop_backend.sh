#!/usr/bin/env bash
# Stop a backend started by scripts/start_backend.sh (background mode).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIDFILE="$ROOT/.run/backend.pid"

if [[ ! -f "$PIDFILE" ]]; then
  echo "no pidfile at $PIDFILE; nothing to stop (launchd-managed? use deploy/launchd/uninstall.sh or launchctl)"
  exit 0
fi

PID="$(cat "$PIDFILE")"
if ! kill -0 "$PID" 2>/dev/null; then
  echo "pid $PID not running; removing stale pidfile"
  rm -f "$PIDFILE"
  exit 0
fi

echo "stopping Cortex backend pid $PID"
kill -TERM "$PID" 2>/dev/null || true
for _ in $(seq 1 15); do
  if ! kill -0 "$PID" 2>/dev/null; then
    rm -f "$PIDFILE"
    echo "stopped"
    exit 0
  fi
  sleep 1
done
echo "did not exit after 15s; sending SIGKILL"
kill -KILL "$PID" 2>/dev/null || true
rm -f "$PIDFILE"
echo "stopped (forced)"
