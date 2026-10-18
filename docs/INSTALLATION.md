# Installation (clean machine, in-house)

This guide gets the Cortex backend running on infrastructure you control, from nothing. It was
verified on macOS 26 (Apple Silicon) with only Xcode Command Line Tools and `uv` installed; the Linux
path uses the same pinned dependency set inside Docker.

Cortex has two deployable parts:

| Part | What it is | Where it runs |
|---|---|---|
| Backend engine | Python 3.12 HTTP + MCP server over a user-owned vault (Markdown/JSON) and a rebuildable SQLite index | Your Mac (launchd), any Linux host (Docker/systemd) |
| macOS app | Native SwiftUI client that embeds and launches its own copy of the backend | Your Mac only; optional |

Everything below works offline after the one-time dependency install. No account, no cloud, no
external database.

## 1. Prerequisites

| Requirement | Why | How to get it |
|---|---|---|
| Git | clone the repo | Xcode CLT (`xcode-select --install`) or distro package |
| CPython 3.12 (3.11+ works) | backend runtime | `uv` installs it without admin rights (recommended), or python.org installer |
| C compiler + SQLite headers | `pysqlite3` builds from source so FTS5 and the `sqlite-vec` extension load on every platform | macOS: Xcode CLT. Debian/Ubuntu: `build-essential libsqlite3-dev` |
| `curl` | health checks | preinstalled on macOS; `apt install curl` on Linux |
| `uv` (optional, recommended) | reproducible Python + venv without sudo | `curl -LsSf https://astral.sh/uv/install.sh \| sh` |
| Xcode Command Line Tools | only to build the macOS app (full Xcode is **not** required) | `xcode-select --install` |
| Docker Engine 24+ with Compose v2 | only for the Linux container path | docker.com or distro package |
| Node 22 + npm | only for the optional Obsidian plugin, TypeScript SDK and browser-extension tooling | nodejs.org |

Disk: the repository is about 1.8 GB because its history contains release artefacts and brand
assets; the backend itself is small.

## 2. Get the code

```bash
git clone https://github.com/trace-cortex/cortex-app.git ~/cortex-app
cd ~/cortex-app
```

There are no submodules and no Git LFS objects. A ZIP download is sufficient for the backend, but a
clone keeps the branches, tags and history you need for upgrades and rollbacks.

## 3. Backend on macOS or Linux (bare metal)

```bash
scripts/setup_local.sh --dev           # --dev adds pytest/bandit/pip-audit; --with-model adds on-device embeddings
scripts/start_backend.sh               # background process on 127.0.0.1:8766, log in .run/backend.log
scripts/health_check.sh                # /health, /ready, authenticated call, bad-token rejection
```

`setup_local.sh` is idempotent. It:

1. finds or installs CPython 3.12 (via `uv` when present),
2. creates `./.venv` from `backend/requirements.lock.txt` (every version pinned),
3. creates `./.env` from `.env.example` with a freshly generated `cxa_` API token (mode 600, never
   overwritten on re-run),
4. optionally downloads the `minishlab/potion-base-8M` embedding model (about 30 MB, one-time
   internet access) when you pass `--with-model`, after which semantic search is fully offline,
5. verifies that SQLite + `sqlite-vec` load.

The API token lives only in `.env`. Read it with:

```bash
grep '^CORTEX_API_KEY=' .env
```

### Make it a service (macOS)

```bash
deploy/launchd/install.sh              # user LaunchAgent: starts at login, restarts on crash
launchctl list | grep com.cortex       # status
deploy/launchd/uninstall.sh            # remove (data stays)
```

For a headless Mac, enable Automatic Login and `sudo pmset -c sleep 0 disksleep 0 autorestart 1`, or
copy the generated plist to `/Library/LaunchDaemons` to run at boot without a login session.

### Make it a service (Linux, no Docker)

Use the units in `deploy/systemd/` (`cortex-api.service`, `cortex-worker.service`,
`cortex-backup.timer`). They expect the multi-tenant layout under `/srv/cortex` and
`/etc/cortex/cortex.env`; `deploy/bootstrap.sh` renders all of it on Ubuntu 24.04. For a
single-user host, point `ExecStart` at `scripts/start_backend.sh --foreground` and
`EnvironmentFile` at your `.env` instead.

## 4. Backend in Docker (Linux host)

```bash
cp .env.example .env
python3 -c 'import secrets; print("cxa_" + secrets.token_hex(32))'   # paste into CORTEX_API_KEY
docker compose up -d --build
curl http://127.0.0.1:8766/health
```

The port is published on loopback only. Add `--profile proxy` with `CORTEX_DOMAIN` set to put Caddy
with automatic TLS in front, or front it with your own reverse proxy. Data persists in the
`cortex-data` volume. The Docker path could not be executed on the verification machine (Docker is
not installed there); the image definition mirrors the bare-metal install exactly and uses the same
lockfile.

## 5. macOS app (optional)

```bash
./macos/build.sh                       # dev build, ad-hoc signed, ~2 minutes with CLT only
open macos/build/Cortex.app
```

The dev build does not bundle a Python framework (`CORTEX_BUNDLE_PYTHON=0` default); it runs the
backend with the `python3.12` found on `PATH`, so run `scripts/setup_local.sh` first and make sure
`~/.local/bin` (uv) or your Python is on `PATH` for GUI apps. The app launches its own backend on
port 8766 against `~/Library/Application Support/Cortex/Cortex.vault` with a token it generates.

Run **either** the launchd service **or** the app on port 8766. To share one vault between the two,
set `CORTEX_VAULT_PATH` in `.env` to the app's default path above, then paste the service token into
the app under Connections & Privacy > Advanced > backend token. The app reuses a running backend only
when the vault path and token match (`macos/Sources/CortexApp.swift`, backend probe).

Release packaging (`macos/package_release.sh`) needs a Developer ID certificate, a notarytool
profile and a Python.framework at `/Library/Frameworks/Python.framework/Versions/3.12` to bundle.
None of that is required to run in-house.

## 6. Connect AI tools (MCP)

Point any MCP client at the stdio bridge with the backend URL and a token:

```json
{
  "mcpServers": {
    "cortex": {
      "command": "/Users/you/cortex-app/.venv/bin/python",
      "args": ["/Users/you/cortex-app/scripts/cortex_mcp_stdio.py"],
      "env": { "CORTEX_BASE_URL": "http://127.0.0.1:8766", "CORTEX_API_KEY": "<token>" }
    }
  }
}
```

Prefer a scoped MCP token over the app token: set `CORTEX_MCP_API_KEY` in `.env` (any long random
string) and use that in MCP configs; `/mcp` accepts it while REST endpoints keep requiring the
main token. See `docs/MCP_INTEGRATIONS.md` and `docs/EXTERNAL_INTEGRATIONS.md`.

## 7. Verify the install

```bash
source .venv/bin/activate
python -m pytest backend/tests -q            # ~7 minutes, 2152 tests
python scripts/backend_beta_smoke.py          # end-to-end capture/approve/search against a temp vault
python scripts/check_vector_runtime.py        # sqlite-vec loadable
```

Expected on a clean install: all tests pass, `"vector": {"available": true}`.

## 8. Upgrade

```bash
scripts/stop_backend.sh || launchctl unload ~/Library/LaunchAgents/com.cortex.local.backend.plist
git pull
scripts/setup_local.sh                       # reinstalls pinned deps, keeps .env
scripts/start_backend.sh || launchctl load -w ~/Library/LaunchAgents/com.cortex.local.backend.plist
scripts/health_check.sh
```

Schema migrations run automatically on startup (`backend/app/database.py`, `schema_migrations`
table); take a backup first with `scripts/backup_local.sh`. See `docs/OPERATIONS.md`.
