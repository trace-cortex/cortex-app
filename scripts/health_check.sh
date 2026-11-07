#!/usr/bin/env bash
# Health check for a running Cortex backend.
#
#   scripts/health_check.sh [--url http://127.0.0.1:8766] [--quiet]
#
# Checks, in order:
#   1. GET /health   (unauthenticated; must be 200 and status "ok")
#   2. GET /ready    (200 = storage diagnostics ok; 503 = needs attention)
#   3. GET /v1/settings with the token from .env (proves auth works)
#   4. GET /v1/inbox with a bogus token (must be 401; proves auth is enforced)
# Exit 0 only when all four pass. Prints a one-line summary per check.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${CORTEX_ENV_FILE:-$ROOT/.env}"
URL=""
QUIET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) URL="$2"; shift ;;
    --quiet) QUIET=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

TOKEN="${CORTEX_API_KEY:-}"
if [[ -f "$ENV_FILE" ]]; then
  # Only read the two values we need; do not export the whole file.
  [[ -z "$TOKEN" ]] && TOKEN="$(grep -E '^CORTEX_API_KEY=' "$ENV_FILE" | head -1 | cut -d= -f2-)"
  PORT_FROM_ENV="$(grep -E '^CORTEX_PORT=' "$ENV_FILE" | head -1 | cut -d= -f2-)"
  HOST_FROM_ENV="$(grep -E '^CORTEX_HOST=' "$ENV_FILE" | head -1 | cut -d= -f2-)"
fi
URL="${URL:-http://${HOST_FROM_ENV:-127.0.0.1}:${PORT_FROM_ENV:-8766}}"
URL="${URL%/}"

say() { [[ "$QUIET" == "1" ]] || echo "$*"; }
fail=0

code_and_body() { curl -sS -m 5 -o "$2" -w '%{http_code}' "${@:3}" "$1" 2>/dev/null || echo 000; }

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

c="$(code_and_body "$URL/health" "$tmp")"
if [[ "$c" == "200" ]] && grep -q '"status": *"ok"' "$tmp"; then
  say "ok   /health 200 (backend_version $(sed -n 's/.*"backend_version": *"\([^"]*\)".*/\1/p' "$tmp" | head -1))"
else
  say "FAIL /health -> HTTP $c"; fail=1
fi

c="$(code_and_body "$URL/ready" "$tmp")"
if [[ "$c" == "200" ]]; then say "ok   /ready 200"; else say "FAIL /ready -> HTTP $c ($(head -c 200 "$tmp"))"; fail=1; fi

if [[ -n "$TOKEN" ]]; then
  c="$(code_and_body "$URL/v1/settings" "$tmp" -H "Authorization: Bearer $TOKEN")"
  if [[ "$c" == "200" ]]; then say "ok   /v1/settings 200 with configured token"; else say "FAIL /v1/settings with configured token -> HTTP $c"; fail=1; fi
else
  say "skip /v1/settings (no CORTEX_API_KEY available)"
fi

c="$(code_and_body "$URL/v1/inbox" "$tmp" -H "Authorization: Bearer not-a-real-token")"
if [[ "$c" == "401" ]]; then say "ok   /v1/inbox rejects a bad token (401)"; else say "FAIL /v1/inbox with bad token -> HTTP $c (expected 401)"; fail=1; fi

if [[ "$fail" == "0" ]]; then say "HEALTHY $URL"; else say "UNHEALTHY $URL"; fi
exit "$fail"
