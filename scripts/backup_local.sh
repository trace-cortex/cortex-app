#!/usr/bin/env bash
# WAL-safe backup of a single-user local Cortex vault (the mode scripts/start_backend.sh runs).
#
#   scripts/backup_local.sh [--dest DIR] [--keep N]
#
# Produces DIR/cortex-local-<UTC stamp>.tar.gz containing:
#   vault/        every user-owned record file (Markdown/JSON) in CORTEX_VAULT_PATH,
#                 excluding the rebuildable index and the vault's own backups/ folder
#   index.sqlite  a consistent snapshot taken with SQLite's online backup API
#                 (copying a live WAL database byte-for-byte is NOT safe)
#   env/.env      your configuration INCLUDING the API token: the archive is as sensitive
#                 as the data; store it encrypted/offsite accordingly.
# Keeps the newest N archives (default 14). Safe to run while the backend is up.
#
# For the multi-tenant server profile use deploy/backup.sh instead.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${CORTEX_ENV_FILE:-$ROOT/.env}"
VENV="${CORTEX_VENV:-$ROOT/.venv}"
DEST="${CORTEX_BACKUP_DIR:-$ROOT/backups}"
KEEP="${CORTEX_BACKUP_KEEP:-14}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest) DEST="$2"; shift ;;
    --keep) KEEP="$2"; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ -f "$ENV_FILE" ]]; then
  set -a; . "$ENV_FILE"; set +a
fi
PY="$VENV/bin/python"; [[ -x "$PY" ]] || PY="$(command -v python3)"
abs() { "$PY" -c 'import os,sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' "$1"; }
VAULT="$(abs "${CORTEX_VAULT_PATH:-$ROOT/backend/data/Cortex.vault}")"
DB="$(abs "${CORTEX_DB_PATH:-$VAULT/index.sqlite}")"
[[ -d "$VAULT" ]] || { echo "ERROR: vault not found at $VAULT" >&2; exit 1; }

STAMP="$(date -u +%Y%m%d-%H%M%S)"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$DEST" "$STAGING/vault" "$STAGING/env"

# 1. user-owned records (skip the rebuildable index + nested backup zips)
"$PY" - "$VAULT" "$STAGING/vault" <<'PY'
import os, shutil, sys
src, dst = sys.argv[1:3]
skip_names = {"index.sqlite", "index.sqlite-wal", "index.sqlite-shm", "index.sqlite-journal"}
for dirpath, dirnames, filenames in os.walk(src):
    rel = os.path.relpath(dirpath, src)
    if rel.split(os.sep)[0] == "backups":
        dirnames[:] = []
        continue
    out = os.path.join(dst, rel) if rel != "." else dst
    os.makedirs(out, exist_ok=True)
    for name in filenames:
        if name in skip_names:
            continue
        shutil.copy2(os.path.join(dirpath, name), os.path.join(out, name))
PY

# 2. consistent SQLite snapshot via the online backup API
if [[ -f "$DB" ]]; then
  "$PY" - "$DB" "$STAGING/index.sqlite" <<'PY'
import sqlite3, sys
src, dst = sys.argv[1:3]
with sqlite3.connect(src) as a, sqlite3.connect(dst) as b:
    a.backup(b)
print("index snapshot ok")
PY
fi

# 3. config (contains the token: treat the archive as secret)
[[ -f "$ENV_FILE" ]] && cp "$ENV_FILE" "$STAGING/env/.env"

ARCHIVE="$DEST/cortex-local-$STAMP.tar.gz"
tar -czf "$ARCHIVE" -C "$STAGING" .
chmod 600 "$ARCHIVE"
echo "backup written: $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"

# 4. retention
ls -1t "$DEST"/cortex-local-*.tar.gz 2>/dev/null | tail -n +"$((KEEP + 1))" | while read -r old; do rm -f "$old"; done
echo "retained: $(ls -1 "$DEST"/cortex-local-*.tar.gz 2>/dev/null | wc -l | tr -d ' ') archive(s) in $DEST"
