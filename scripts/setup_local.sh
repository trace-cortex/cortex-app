#!/usr/bin/env bash
# One-command, in-house setup for the Cortex backend on macOS or Linux.
#
#   scripts/setup_local.sh [--dev] [--with-model] [--python <interpreter>]
#
# What it does (idempotent, safe to re-run after `git pull`):
#   1. Finds or installs CPython 3.12 (uses `uv` when available, no sudo needed).
#   2. Creates ./.venv and installs backend/requirements.lock.txt (pinned).
#   3. Creates ./.env from .env.example with a freshly generated API token (never overwrites).
#   4. Optionally (--with-model) downloads the on-device embedding model so semantic
#      search works offline afterwards. Without it, Cortex uses deterministic hash embeddings.
#   5. Verifies the SQLite + sqlite-vec runtime.
#
# Flags:
#   --dev         also install pytest, bandit and pip-audit (test + security tooling)
#   --with-model  download minishlab/potion-base-8M (~30 MB, one-time, needs internet)
#   --python P    use interpreter P instead of auto-detecting
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PY_VERSION="${CORTEX_PYTHON_VERSION:-3.12}"
VENV="${CORTEX_VENV:-$ROOT/.venv}"
ENV_FILE="${CORTEX_ENV_FILE:-$ROOT/.env}"
MODEL_DIR="${CORTEX_MODEL_DIR:-$ROOT/models/model2vec}"
MODEL_NAME="${CORTEX_MODEL2VEC_MODEL:-minishlab/potion-base-8M}"
DEV=0
WITH_MODEL=0
PY_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dev) DEV=1 ;;
    --with-model) WITH_MODEL=1 ;;
    --python) PY_OVERRIDE="$2"; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

log() { printf '==> %s\n' "$*"; }

# --- 1. interpreter --------------------------------------------------------------
PY=""
if [[ -n "$PY_OVERRIDE" ]]; then
  PY="$PY_OVERRIDE"
elif command -v uv >/dev/null 2>&1; then
  log "uv found; ensuring CPython $PY_VERSION is installed (no sudo)"
  uv python install "$PY_VERSION" >/dev/null 2>&1 || true
  PY="$(uv python find "$PY_VERSION")"
else
  for candidate in "python$PY_VERSION" python3.13 python3.12 python3.11 python3; do
    if command -v "$candidate" >/dev/null 2>&1; then
      if "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)'; then
        PY="$(command -v "$candidate")"
        break
      fi
    fi
  done
fi
if [[ -z "$PY" ]]; then
  cat >&2 <<'EOF'
ERROR: no CPython >= 3.11 found.
  Easiest fix (no admin rights): install uv, then re-run this script.
    curl -LsSf https://astral.sh/uv/install.sh | sh
  Or install Python 3.12 from https://www.python.org/downloads/ and pass --python /path/to/python3.12
EOF
  exit 1
fi
log "python: $PY ($("$PY" -c 'import platform; print(platform.python_version())'))"

# --- 2. virtualenv + pinned dependencies --------------------------------------
if [[ ! -x "$VENV/bin/python" ]]; then
  log "creating virtualenv at $VENV"
  if command -v uv >/dev/null 2>&1; then
    uv venv --python "$PY" "$VENV" >/dev/null
  else
    "$PY" -m venv "$VENV"
  fi
fi
log "installing pinned backend dependencies (backend/requirements.lock.txt)"
if command -v uv >/dev/null 2>&1; then
  uv pip install --python "$VENV/bin/python" -q -r backend/requirements.lock.txt
  [[ "$DEV" == "1" ]] && uv pip install --python "$VENV/bin/python" -q pytest bandit pip-audit
else
  "$VENV/bin/python" -m pip install -q --upgrade pip
  "$VENV/bin/python" -m pip install -q -r backend/requirements.lock.txt
  [[ "$DEV" == "1" ]] && "$VENV/bin/python" -m pip install -q pytest bandit pip-audit
fi

# --- 3. .env with a generated token ------------------------------------------------
if [[ ! -f "$ENV_FILE" ]]; then
  log "creating $ENV_FILE from .env.example with a generated API token"
  TOKEN="cxa_$("$VENV/bin/python" -c 'import secrets; print(secrets.token_hex(32))')"
  "$VENV/bin/python" - "$ROOT/.env.example" "$ENV_FILE" "$TOKEN" <<'PY'
import sys, pathlib
src, dst, token = sys.argv[1:4]
text = pathlib.Path(src).read_text()
text = text.replace("CORTEX_API_KEY=replace-with-a-long-random-token", f"CORTEX_API_KEY={token}")
pathlib.Path(dst).write_text(text)
PY
  chmod 600 "$ENV_FILE"
else
  log "$ENV_FILE exists; keeping it (secrets are never overwritten)"
fi

ensure_env() {
  # Append KEY=VALUE to the env file only when KEY is absent. Never overwrites.
  if ! grep -qE "^$1=" "$ENV_FILE"; then
    printf '%s=%s\n' "$1" "$2" >> "$ENV_FILE"
    log "added $1 to $(basename "$ENV_FILE")"
  fi
}

# --- 4. optional on-device embedding model ---------------------------------------
if [[ "$WITH_MODEL" == "1" ]]; then
  if [[ -f "$MODEL_DIR/config.json" ]]; then
    log "embedding model already present at $MODEL_DIR"
  else
    log "downloading $MODEL_NAME to $MODEL_DIR (one-time, ~30 MB)"
    mkdir -p "$(dirname "$MODEL_DIR")"
    "$VENV/bin/python" - "$MODEL_NAME" "$MODEL_DIR" <<'PY'
import sys
from model2vec import StaticModel
name, out = sys.argv[1:3]
StaticModel.from_pretrained(name).save_pretrained(out)
print("saved", out)
PY
  fi
  ensure_env CORTEX_EMBEDDING_PROVIDER model2vec
  ensure_env CORTEX_MODEL2VEC_PATH "$MODEL_DIR"
  # If the example file set the provider to hash, flip it to model2vec once.
  if grep -qE '^CORTEX_EMBEDDING_PROVIDER=hash$' "$ENV_FILE"; then
    sed -i.bak 's/^CORTEX_EMBEDDING_PROVIDER=hash$/CORTEX_EMBEDDING_PROVIDER=model2vec/' "$ENV_FILE" && rm -f "$ENV_FILE.bak"
    grep -qE '^CORTEX_MODEL2VEC_PATH=' "$ENV_FILE" || printf 'CORTEX_MODEL2VEC_PATH=%s\n' "$MODEL_DIR" >> "$ENV_FILE"
    log "switched CORTEX_EMBEDDING_PROVIDER to model2vec"
  fi
fi

# --- 5. runtime verification ---------------------------------------------------------
log "verifying SQLite + sqlite-vec runtime"
if "$VENV/bin/python" scripts/check_vector_runtime.py >/tmp/cortex-vector-check.$$ 2>&1; then
  if grep -q '"available": true' /tmp/cortex-vector-check.$$; then
    log "sqlite-vec available: vector search enabled"
  else
    log "WARNING: sqlite-vec not loadable; Cortex will fall back to full-text search only"
  fi
else
  log "WARNING: vector runtime check failed; see /tmp/cortex-vector-check.$$"
fi
rm -f /tmp/cortex-vector-check.$$ 2>/dev/null || true

cat <<EOF

Setup complete.
  venv     : $VENV
  env file : $ENV_FILE   (contains your API token; chmod 600; never commit it)
Next:
  scripts/start_backend.sh            # start on 127.0.0.1:\${CORTEX_PORT:-8766}
  scripts/health_check.sh             # verify /health, /ready and an authenticated call
  deploy/launchd/install.sh           # (macOS) run it as an always-on login service
EOF
