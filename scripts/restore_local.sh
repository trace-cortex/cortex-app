#!/usr/bin/env bash
# Restore a scripts/backup_local.sh archive into the vault from ./.env.
#
#   scripts/restore_local.sh <archive.tar.gz> [--yes]
#
# Stops nothing by itself: stop the backend first (scripts/stop_backend.sh or launchctl),
# run this, then start it again. The current vault is moved aside to <vault>.pre-restore-<stamp>
# (never deleted) so the operation is reversible. The .env inside the archive is NOT restored
# automatically; it is extracted next to the archive for you to compare.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${CORTEX_ENV_FILE:-$ROOT/.env}"
VENV="${CORTEX_VENV:-$ROOT/.venv}"
ARCHIVE="${1:-}"
YES="${2:-}"
[[ -f "$ARCHIVE" ]] || { echo "usage: $0 <archive.tar.gz> [--yes]" >&2; exit 2; }

if [[ -f "$ENV_FILE" ]]; then set -a; . "$ENV_FILE"; set +a; fi
PY="$VENV/bin/python"; [[ -x "$PY" ]] || PY="$(command -v python3)"
abs() { "$PY" -c 'import os,sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' "$1"; }
VAULT="$(abs "${CORTEX_VAULT_PATH:-$ROOT/backend/data/Cortex.vault}")"
DB="$(abs "${CORTEX_DB_PATH:-$VAULT/index.sqlite}")"

if [[ -f "$ROOT/.run/backend.pid" ]] && kill -0 "$(cat "$ROOT/.run/backend.pid")" 2>/dev/null; then
  echo "ERROR: backend is running (pid $(cat "$ROOT/.run/backend.pid")). Stop it first." >&2
  exit 1
fi
if curl -fsS -m 2 -o /dev/null "http://${CORTEX_HOST:-127.0.0.1}:${CORTEX_PORT:-8766}/health" 2>/dev/null; then
  echo "ERROR: something is still serving on ${CORTEX_HOST:-127.0.0.1}:${CORTEX_PORT:-8766}. Stop it first." >&2
  exit 1
fi

STAMP="$(date -u +%Y%m%d-%H%M%S)"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
tar -xzf "$ARCHIVE" -C "$STAGING"
[[ -d "$STAGING/vault" ]] || { echo "ERROR: archive has no vault/ directory" >&2; exit 1; }

echo "restore plan:"
echo "  archive : $ARCHIVE"
echo "  vault   : $VAULT  (current copy kept at $VAULT.pre-restore-$STAMP)"
echo "  index   : $DB"
if [[ "$YES" != "--yes" ]]; then
  read -r -p "proceed? [y/N] " answer
  [[ "$answer" == "y" || "$answer" == "Y" ]] || { echo "aborted"; exit 1; }
fi

if [[ -d "$VAULT" ]]; then mv "$VAULT" "$VAULT.pre-restore-$STAMP"; fi
mkdir -p "$(dirname "$VAULT")"
cp -R "$STAGING/vault" "$VAULT"
rm -f "$DB" "$DB-wal" "$DB-shm"
if [[ -f "$STAGING/index.sqlite" ]]; then
  mkdir -p "$(dirname "$DB")"
  cp "$STAGING/index.sqlite" "$DB"
  echo "index restored from snapshot"
else
  echo "no index snapshot in archive; the backend rebuilds it from the vault on next start"
fi
if [[ -f "$STAGING/env/.env" ]]; then
  cp "$STAGING/env/.env" "$ARCHIVE.env.restored"
  chmod 600 "$ARCHIVE.env.restored"
  echo "archived .env extracted to $ARCHIVE.env.restored (compare with $ENV_FILE manually)"
fi
echo "done. Start the backend again (scripts/start_backend.sh) and run scripts/health_check.sh"
