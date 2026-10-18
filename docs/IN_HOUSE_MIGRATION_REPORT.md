# In-house migration report (2026-10-17)

Scope: take `trace-cortex/cortex-app` and make it run, reproducibly and documented, on
infrastructure the operator controls (first target: this macOS workstation). This file records what
was inspected, what was verified, what changed, and what remains.

## 1. Repository access and acquisition

| Item | Result |
|---|---|
| Visibility | public, MIT, default branch `main`, 39 forks, about 1.8 GB of history |
| Control | the operator's GitHub account is an **admin of the `trace-cortex` organisation** and the repository (GitHub still redirects `VamikaSinghal/cortex-app` to it, i.e. it was transferred from that account). No fork was needed; `origin` stays at trace-cortex. |
| Clone | full clone to `~/cortex-app` with all 12 remote branches and 19 tags |
| Submodules / LFS | none |
| Work branch | `chore/in-house-deployment` (nothing pushed) |

## 2. Codebase audit (summary)

| Area | Finding |
|---|---|
| Languages | Python 3.12 backend (CI pins 3.12; `str \| None` syntax needs 3.10+, README says 3.11+), Swift 6 SwiftUI macOS app, TypeScript for the Obsidian plugin / TS SDK / OpenClaw adapter, JS browser extension, static HTML site |
| Backend entry points | `backend.app.main:app` (FastAPI + uvicorn) and `backend/app/standalone_server.py` (stdlib HTTP server with built-in job worker; this is what the packaged app launches). Both expose the same routes, `/health`, `/ready`, `/v1/*`, `/mcp` |
| Workers / scheduled jobs | inline job runner by default; `scripts/run_memory_worker.py` for `CORTEX_WORKER_MODE=external`; nightly backup timer in the server kit |
| Persistence | user-owned vault directory (Markdown + JSON + `events.jsonl`) and a rebuildable SQLite index (FTS5 + `sqlite-vec`, WAL). No Postgres, Redis or queue in the product. Schema migrations run on startup. |
| Auth | single bearer token (`CORTEX_API_KEY`), optional scoped tokens (`read/write/export/maintenance/destructive`), optional MCP-only token; multi-tenant profile adds argon2id accounts, OIDC (Google/GitHub/Apple), KEK-encrypted credentials |
| External services | all optional: Anthropic (extraction), OpenAI (embeddings), Hugging Face (one-time model download), 13 source connectors, SMTP, Paddle/Stripe, Turnstile, Cloudflare Tunnel / Caddy for ingress |
| Config surface | 168 `CORTEX_*` variables plus `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `DATABASE_URL`; catalogued in `docs/CONFIGURATION.md` |
| Tests | 166 test files, pytest canonical (`backend/tests/conftest.py` isolates a temp vault) |
| CI | `.github/workflows/ci.yml`: python checks + 12 eval gates, security scan (bandit, pip-audit), distribution checks, Obsidian plugin build (Node 22), macOS app build (CLT) |
| Legacy prototype | `capture.py`, `ingest.py`, `github_store.py`, `redis_store.py`, `mcp_server.py`, `ui.py`, `instrumentation.py` + root `requirements.txt` (Redis, Voyage, rumps, Streamlit, Arize). Unused by the product. |

Data flow: sources (notes, exports, connectors, MCP `remember_this`) -> captures (pending) ->
extractor (local deterministic or Claude) -> memories/entities/tasks in the vault -> review inbox
(approve/archive) -> SQLite index (FTS + vectors) -> retrieval (`/v1/search`, `/v1/ask`,
`/v1/context-pack`, MCP tools) -> clients (macOS app, MCP tools, SDKs, extension).

## 3. Environment reconstruction

| Step | Result |
|---|---|
| Runtime | this Mac had only Python 3.9, no Homebrew, no Node, no Docker; `uv` was present and installed CPython 3.12.14 without sudo |
| Dependencies | `backend/requirements.txt` + `backend/runtime-requirements.txt` installed cleanly; `pysqlite3` compiled with Xcode CLT; universal lockfile generated (`backend/requirements.lock.txt`, 46 pins) |
| Vector runtime | `scripts/check_vector_runtime.py`: `sqlite-vec v0.1.9 available: true` |
| Backend | both entry points start, pass `/health` and `/ready`, reject bad tokens (401), accept capture -> approve -> search -> ask with a cited answer, serve MCP `initialize` and `tools/list` (110 tools) |
| macOS app | `macos/build.sh` with `CORTEX_BUNDLE_PYTHON=0`, ad-hoc signing: built in about 2 minutes with Command Line Tools only (33 MB bundle), `codesign --verify --deep --strict` passes, build's own backend boot smoke passed |
| Service | launchd LaunchAgent `com.cortex.local.backend` installed; survives `kill -9` (auto-restart in about 15 s, data intact) |
| Backup/restore | `scripts/backup_local.sh` (WAL-safe) and `scripts/restore_local.sh` round-trip verified |
| Restart | stop/start via scripts and via launchd verified; captured data persisted across restarts |
| Docker | `Dockerfile` + `docker-compose.yml` written from the same lockfile; **not executed** (Docker absent on this machine) |
| Node packages | Obsidian plugin, TS SDK, OpenClaw adapter **not rebuilt** (Node absent); committed build output is what the app bundles |

## 4. Test and gate results

| Check | Result |
|---|---|
| `python -m compileall backend scripts *.py` | pass |
| `pytest backend/tests` (full, after fixes) | **2152 passed, 0 failed**, 416 subtests, about 6.7 min (before the fix: 2151 passed, 1 failed) |
| `scripts/retrieval_eval.py`, `tool_routing_eval.py`, `adapter_contract_eval.py`, `context_pack_eval.py`, `token_calibration_eval.py`, `agent_task_eval.py --deterministic`, `delivery_eval.py`, `rerank_eval.py` (skips model2vec lift, as in CI), `adaptation_eval.py`, `check_connector_baseline.py`, `check_docs_current.py`, `backend_beta_smoke.py`, `appstore_compliance_lint.py` (46/46) | all pass |
| `bandit -c .bandit.yaml -r backend scripts -ll` | 0 medium/high after fix (was 8 high) |
| `pip-audit --strict` (both requirement files + lockfile) | no known vulnerabilities |
| `scripts/check_distribution_site.py` | pass |
| `scripts/validate_update_manifest.py site/downloads/latest.json` and `ops_readiness_check.py` | pass with the new `--allow-remote-artifacts` mode (site feed binaries live on GitHub Releases; the manifest's sha256 is cross-checked against the committed checksums file). Strict mode, used for packaged release directories, is unchanged. |
| Upstream CI on `main` | failing since 2026-08-05 on the security scan (SHA1 findings, then `pip-audit` on the root `requirements.txt` whose `rumps` dependency cannot build on Linux), the distribution job (DMG not in git) and one `model2vec` test that did not skip without the package. All three are fixed on this branch. |

## 5. Files changed on `chore/in-house-deployment`

Added:

- `scripts/setup_local.sh`, `scripts/start_backend.sh`, `scripts/stop_backend.sh`,
  `scripts/health_check.sh`, `scripts/backup_local.sh`, `scripts/restore_local.sh`
- `deploy/launchd/install.sh`, `deploy/launchd/uninstall.sh`
- `Dockerfile`, `docker-compose.yml`, `.dockerignore`
- `backend/requirements.lock.txt`
- `docs/INSTALLATION.md`, `docs/CONFIGURATION.md`, `docs/OPERATIONS.md`, `docs/SECURITY.md`,
  `docs/DEPENDENCIES.md`, `docs/IN_HOUSE_MIGRATION_REPORT.md`

Modified:

- `.env.example` (full single-user reference with safe placeholders), `.gitignore` (venv, env
  files, run state, data, backups, models, SQLite side files, keys)
- `README.md` ("Run it in-house" section), `SETUP.md` (service pointer), `docs/ARCHITECTURE.md`
  (deployment topology)
- `backend/app/connectors/agent_sessions.py`, `backend/app/obsidian_writeback.py`,
  `backend/app/storage.py`, `backend/app/vault.py`: SHA1 content fingerprints marked
  `usedforsecurity=False` (no behaviour change; unblocks the bandit gate)
- `backend/tests/test_macos_ui_quality_contract.py`: assertions updated to the refactored
  `AppleSignInSupport` gate in `CortexCloudAuth.swift` (same guarantee, current symbol names)
- `backend/tests/test_rerank_eval.py`: probe the embedder before deciding to skip, so the gate
  skips (as CI intends) when `model2vec` is not installed
- `requirements.txt` (legacy prototype): `rumps` limited to macOS so `pip-audit` resolves on Linux
- `scripts/validate_update_manifest.py`, `scripts/ops_readiness_check.py`, `.github/workflows/ci.yml`:
  `--allow-remote-artifacts` for the published site feed

Removed: none. No application architecture, framework or feature was changed.

## 6. Known issues and blockers

1. Docker image and Compose stack are untested here (no Docker Engine on this Mac).
2. Node-based packages were not rebuilt; CI's Obsidian plugin job needs Node 22.
3. The macOS dev build runs the backend with whatever `python3.12` is on the GUI `PATH`; a
   bundled-Python build needs a Python.framework at `/Library/Frameworks/Python.framework/3.12`.
4. The launchd service and the macOS app both want port 8766; run one, or align vault path and
   token (documented in `docs/INSTALLATION.md`).
5. `com.cortex.doppl.ShipIt` (an updater from a previously installed Doppl build) is still
   registered with launchd on this machine; it is unrelated to this deployment.
6. Semantic embeddings are off (hash provider) until `scripts/setup_local.sh --with-model` is
   run, which downloads about 30 MB from Hugging Face once.

## 7. Recommended next steps

- Run `scripts/setup_local.sh --with-model` once to enable on-device semantic search.
- Open a PR from `chore/in-house-deployment` to `main`; it also turns the upstream security CI job
  green.
- Schedule `scripts/backup_local.sh` nightly (plist in `docs/OPERATIONS.md`) and copy archives
  off-machine.
- Build and run the Docker image on a Linux host to validate the container path.
- Install Node 22 if the Obsidian plugin or TS SDK need rebuilding.
- Decide whether the single-user service should use the app's default vault path so the macOS app
  and the service share one memory store.
