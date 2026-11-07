#!/usr/bin/env bash
# Start the Cortex backend from ./.env (or $CORTEX_ENV_FILE).
#
#   scripts/start_backend.sh [--foreground] [--mode fastapi|standalone]
#
#   --foreground   run in the foreground (what launchd / Docker / systemd want)
#   --mode         fastapi    = uvicorn + FastAPI app (default; full HTTP surface, OpenAPI docs)
#                  standalone = dependency-light stdlib server, the one the packaged macOS app embeds
#
# Background mode writes .run/backend.pid and .run/backend.log and waits for /health.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ENV_FILE="${CORTEX_ENV_FILE:-$ROOT/.env}"
VENV="${CORTEX_VENV:-$ROOT/.venv}"
RUN_DIR="$ROOT/.run"
PIDFILE="$RUN_DIR/backend.pid"
LOGFILE="$RUN_DIR/backend.log"
FOREGROUND=0
MODE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --foreground) FOREGROUND=1 ;;
    --mode) MODE="$2"; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Run scripts/setup_local.sh first." >&2
  exit 1
fi
if [[ ! -x "$VENV/bin/python" ]]; then
  echo "ERROR: $VENV/bin/python not found. Run scripts/setup_local.sh first." >&2
  exit 1
fi

# Load the env file into the process environment (the backend reads only real env vars).
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

MODE="${MODE:-${CORTEX_SERVER_MODE:-fastapi}}"
HOST="${CORTEX_HOST:-127.0.0.1}"
PORT="${CORTEX_PORT:-8766}"
export CORTEX_PUBLIC_BASE_URL="${CORTEX_PUBLIC_BASE_URL:-http://$HOST:$PORT}"

if [[ -z "${CORTEX_API_KEY:-}" ]]; then
  echo "ERROR: CORTEX_API_KEY is empty in $ENV_FILE." >&2
  exit 1
fi
if [[ "$CORTEX_API_KEY" == "dev-local-key" && "${CORTEX_ALLOW_INSECURE_DEV_TOKEN:-0}" != "1" ]]; then
  echo "ERROR: CORTEX_API_KEY is the insecure sample token. Set a random token (scripts/setup_local.sh does this)." >&2
  exit 1
fi

# Resolve the vault/db paths to absolute paths so launchd, cron and the macOS app agree on them.
abs() { "$VENV/bin/python" -c 'import os,sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' "$1"; }
export CORTEX_VAULT_PATH="$(abs "${CORTEX_VAULT_PATH:-./backend/data/Cortex.vault}")"
export CORTEX_DB_PATH="$(abs "${CORTEX_DB_PATH:-$CORTEX_VAULT_PATH/index.sqlite}")"
mkdir -p "$CORTEX_VAULT_PATH"
export PYTHONDONTWRITEBYTECODE=1
export PYTHONUNBUFFERED=1

case "$MODE" in
  fastapi)
    CMD=("$VENV/bin/python" -m uvicorn backend.app.main:app --host "$HOST" --port "$PORT" --workers "${CORTEX_UVICORN_WORKERS:-1}")
    [[ "$HOST" != "127.0.0.1" && "$HOST" != "localhost" ]] && CMD+=(--proxy-headers --forwarded-allow-ips="${CORTEX_FORWARDED_ALLOW_IPS:-127.0.0.1}")
    WORKDIR="$ROOT"
    ;;
  standalone)
    CMD=("$VENV/bin/python" -m app.standalone_server --host "$HOST" --port "$PORT")
    WORKDIR="$ROOT/backend"
    ;;
  *)
    echo "ERROR: unknown mode '$MODE' (fastapi|standalone)" >&2
    exit 2
    ;;
esac

if [[ "$FOREGROUND" == "1" ]]; then
  cd "$WORKDIR"
  exec "${CMD[@]}"
fi

mkdir -p "$RUN_DIR"
if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "Cortex backend already running (pid $(cat "$PIDFILE")) on http://$HOST:$PORT"
  exit 0
fi

(
  cd "$WORKDIR"
  nohup "${CMD[@]}" >>"$LOGFILE" 2>&1 &
  echo $! >"$PIDFILE"
)
PID="$(cat "$PIDFILE")"
echo "starting Cortex backend ($MODE) pid $PID on http://$HOST:$PORT  (log: $LOGFILE)"

for _ in $(seq 1 60); do
  if curl -fsS -o /dev/null "http://$HOST:$PORT/health" 2>/dev/null; then
    echo "healthy: http://$HOST:$PORT/health"
    exit 0
  fi
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "ERROR: backend exited during startup. Last log lines:" >&2
    tail -n 20 "$LOGFILE" >&2
    rm -f "$PIDFILE"
    exit 1
  fi
  sleep 1
done
echo "ERROR: backend did not become healthy within 60s. See $LOGFILE" >&2
exit 1
