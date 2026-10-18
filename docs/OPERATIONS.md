# Operations runbook (in-house)

Applies to the single-user, local-first deployment set up by `scripts/setup_local.sh`. The
multi-tenant server profile has its own runbooks in `deploy/README.md`, `deploy/macmini/README.md`
and `docs/OPERATIONAL_READINESS.md`.

## Layout

| Path | Contents |
|---|---|
| `.venv/` | Python 3.12 environment from `backend/requirements.lock.txt` |
| `.env` | configuration + API token (mode 600, git-ignored) |
| `backend/data/Cortex.vault/` | the memory store: `captures/`, `memories/`, `entities/`, `events.jsonl`, `settings.json`, `backups/` |
| `backend/data/Cortex.vault/index.sqlite` | rebuildable FTS5 + sqlite-vec index (WAL mode) |
| `.run/backend.pid`, `.run/backend.log` | background process started by `scripts/start_backend.sh` |
| `.run/launchd.out.log`, `.run/launchd.err.log` | service logs when run under launchd |
| `backups/` | archives from `scripts/backup_local.sh` (default destination) |
| `models/model2vec/` | optional on-device embedding model |

## Start, stop, status

Manual (foreground-less background process):

```bash
scripts/start_backend.sh              # idempotent; waits for /health
scripts/health_check.sh               # 4 checks, exit 0 = healthy
scripts/stop_backend.sh               # SIGTERM, then SIGKILL after 15 s
tail -f .run/backend.log
```

As a macOS service:

```bash
deploy/launchd/install.sh                                             # install + start + health check
launchctl list | grep com.cortex.local.backend                        # "<pid> 0 com.cortex.local.backend" = running
launchctl unload ~/Library/LaunchAgents/com.cortex.local.backend.plist  # stop
launchctl load -w ~/Library/LaunchAgents/com.cortex.local.backend.plist # start
launchctl kickstart -k gui/$(id -u)/com.cortex.local.backend          # restart
deploy/launchd/uninstall.sh                                           # remove the service
```

The service has `KeepAlive` set: a crash or `kill -9` is followed by an automatic restart within a
few seconds (verified: recovery after SIGKILL in about 15 s with the default ThrottleInterval, data intact).

Docker:

```bash
docker compose up -d --build
docker compose ps
docker compose logs -f api
docker compose restart api
docker compose down            # data persists in the cortex-data volume
```

## Health contract

| Endpoint | Auth | Healthy response |
|---|---|---|
| `GET /health` | none | 200, `status: ok`, `health_contract >= 3`, feature list, vault/db paths |
| `GET /ready` | none | 200 with storage diagnostics; 503 `needs_configuration` or a diagnostics payload when the index needs repair |
| `GET /v1/settings` | bearer | 200 proves the token works |
| `GET /v1/diagnostics` | bearer | integrity check: `quick_check`, FTS orphans, relation orphans |
| `GET /v1/reliability/report` | bearer | consolidated reliability report |
| `GET /v1/metrics` | admin | counters/latency when `CORTEX_OBSERVABILITY_ENABLED=1` |

`scripts/health_check.sh` runs the first three plus a bad-token rejection and is what the launchd
installer and the restart procedure rely on. Wire it into any monitor you already run (cron +
notification, UptimeRobot on the proxy URL, etc.).

## Backups

Two complementary mechanisms:

1. **In-app / API backups** (`POST /v1/backups`, the app's Backup button): writes a full vault zip
   under `<vault>/backups/` and prunes to `CORTEX_BACKUP_RETENTION_COUNT`. Restore with
   `POST /v1/backups/restore-latest` or `scripts/cortex_restore.py` (per-zip, with integrity checks).
2. **File-system backups** (`scripts/backup_local.sh`): WAL-safe snapshot of the index via SQLite's
   online backup API plus every vault record and your `.env`, as one `tar.gz`. Runs safely while
   the backend is up. Keeps the newest 14 by default.

Nightly schedule on macOS (user agent, 02:30):

```bash
cat > ~/Library/LaunchAgents/com.cortex.local.backup.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.cortex.local.backup</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$HOME/cortex-app/scripts/backup_local.sh</string></array>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>2</integer><key>Minute</key><integer>30</integer></dict>
  <key>StandardErrorPath</key><string>$HOME/cortex-app/.run/backup.err.log</string>
</dict></plist>
EOF
launchctl load -w ~/Library/LaunchAgents/com.cortex.local.backup.plist
```

Copy archives off the machine (they contain the API token: encrypt or store them where only you
can read them). `rclone`, Time Machine excluding nothing but `.venv`, or any object store works.

## Restore

```bash
scripts/stop_backend.sh    # or launchctl unload ...
scripts/restore_local.sh backups/cortex-local-<stamp>.tar.gz --yes
scripts/start_backend.sh   # or launchctl load -w ...
scripts/health_check.sh
```

The previous vault is kept at `<vault>.pre-restore-<stamp>`; delete it once satisfied. The archived
`.env` is extracted beside the archive for manual comparison, never applied automatically.

If only the index is damaged, the vault remains authoritative: delete `index.sqlite*` and call
`POST /v1/maintenance/rebuild-index-from-vault` (or restart; the backend rebuilds missing indexes).
`POST /v1/maintenance/repair-storage` performs a backup-first repair, and
`POST /v1/maintenance/rebuild-search` rebuilds FTS/vector tables only.

## Upgrades

```bash
scripts/backup_local.sh
scripts/stop_backend.sh || launchctl unload ~/Library/LaunchAgents/com.cortex.local.backend.plist
git fetch && git checkout <tag-or-branch>
scripts/setup_local.sh                 # reinstalls pinned deps; .env untouched
scripts/start_backend.sh || launchctl load -w ~/Library/LaunchAgents/com.cortex.local.backend.plist
scripts/health_check.sh
```

Schema migrations are applied on startup and recorded in `schema_migrations`. Rollback = check out
the previous commit and restore the pre-upgrade backup (migrations are forward-only).

Dependency updates: edit `backend/requirements.txt` / `backend/runtime-requirements.txt`, then

```bash
uv pip compile --universal --python-version 3.12 backend/requirements.txt backend/runtime-requirements.txt -o backend/requirements.lock.txt
```

and re-run the test suite and `pip-audit -r backend/requirements.lock.txt`.

## Logs

| Source | Location |
|---|---|
| background process | `.run/backend.log` (uvicorn access + app logs) |
| launchd service | `.run/launchd.out.log`, `.run/launchd.err.log` |
| audit trail of memory operations | `<vault>/events.jsonl`, `GET /v1/audit-log` |
| support bundle (sanitised) | `GET /v1/support/bundle` or `scripts/export_support_bundle.py` |

Rotate `.run/*.log` with `newsyslog` or logrotate; the backend does not rotate them itself.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `RuntimeError: CORTEX_API_KEY uses the insecure sample token` | `.env` still has `dev-local-key` | set a random token (`scripts/setup_local.sh` does) |
| `port 8766 may already be in use` in the macOS app | launchd service (or another backend) owns the port | run one of them, or align vault path + token (see `docs/INSTALLATION.md` section 5) |
| `/ready` returns 503 with `needs_configuration` | server-profile vars half-set (e.g. `CORTEX_HOSTED_RUNTIME_TIER=postgres` without a database URL) | unset them for single-user mode |
| `/ready` 503 with diagnostics | index integrity issue | `POST /v1/maintenance/repair-storage`, then rebuild from vault |
| `vector.available: false` in `check_vector_runtime.py` | `sqlite-vec` could not load (stdlib sqlite without extension support) | ensure `pysqlite3` built: reinstall with a C compiler + SQLite headers present |
| semantic search feels keyword-only | provider is `hash` | `scripts/setup_local.sh --with-model` and restart |
| `SSL: CERTIFICATE_VERIFY_FAILED` on connector sync | Python without a CA bundle | `certifi` is in the lockfile; otherwise set `SSL_CERT_FILE` |
| service restarts in a loop | see `.run/launchd.err.log`; usually a bad `.env` value | fix, then `launchctl kickstart -k gui/$(id -u)/com.cortex.local.backend` |

## Deleting everything

`scripts/stop_backend.sh`, `deploy/launchd/uninstall.sh`, then delete the vault directory,
`backups/`, `.run/` and `.env`. `DELETE /v1/user-data` does the in-app equivalent for the memory
store. Nothing else on the machine holds Cortex data.
