# Configuration

The backend reads configuration from **environment variables only** (`backend/app/config.py`
`load_settings()` plus a few module-level reads). It never loads a `.env` file itself; the wrappers
(`scripts/start_backend.sh`, `deploy/launchd/install.sh`, `docker-compose.yml`, `deploy/macmini/*`,
`deploy/systemd/*`) export the file before launching.

Two files describe the two supported profiles:

| Profile | Example file | Use |
|---|---|---|
| Single-user, local-first | `.env.example` | one person, one vault, loopback, the mode the macOS app uses |
| Multi-tenant server | `deploy/cortex.env.example` | many users, sharded SQLite, accounts/OAuth, scoped tokens, external worker |

Values are case-sensitive; booleans accept `1/true/yes/on`.

## Required

| Variable | Default | Notes |
|---|---|---|
| `CORTEX_API_KEY` | (none) | Bearer token for every REST call and the admin token in server mode. The backend refuses `dev-local-key` unless `CORTEX_ALLOW_INSECURE_DEV_TOKEN=1`. |

## Storage

| Variable | Default | Notes |
|---|---|---|
| `CORTEX_VAULT_PATH` | `backend/data/Cortex.vault` | User-owned records: Markdown + JSON, `events.jsonl`, `backups/`. The macOS app uses `~/Library/Application Support/Cortex/Cortex.vault`. |
| `CORTEX_DB_PATH` | `<vault>/index.sqlite` | Rebuildable FTS5 + `sqlite-vec` index. Deleting it is safe; `POST /v1/maintenance/rebuild-index-from-vault` rebuilds. |
| `CORTEX_BACKUP_RETENTION_COUNT` | `20` | In-vault backup zips to keep. |
| `CORTEX_BACKUP_RETENTION_DAYS` | `0` | Age pruning, off by default. |
| `CORTEX_STORE_CACHE_SIZE` | `512` | Per-process store cache (server mode). |

## Network

| Variable | Default | Notes |
|---|---|---|
| `CORTEX_HOST` | `127.0.0.1` | Used by the wrappers. Bind elsewhere only behind TLS. |
| `CORTEX_PORT` | `8766` | The macOS app, MCP bridge and SDKs default to this port. |
| `CORTEX_PUBLIC_BASE_URL` | `http://127.0.0.1:8766` | Advertised in OAuth redirects, MCP resources, account pages. |
| `CORTEX_PUBLIC_APP_URL` | = base URL | Browser-facing URL for sign-in pages (server mode). |
| `CORTEX_CORS_ORIGINS` | loopback | Comma-separated allowed origins. |
| `CORTEX_ALLOW_EXTENSION_CORS` | `1` | Allow `chrome-extension://` / `moz-extension://` origins for the browser extension. |
| `CORTEX_UVICORN_WORKERS` | `1` | uvicorn processes (FastAPI mode). Rate limiter is per process. |
| `CORTEX_SERVER_MODE` | `fastapi` | Wrapper-only: `fastapi` (uvicorn) or `standalone` (stdlib server bundled in the app). |
| `CORTEX_MAX_CONCURRENT_REQUESTS` | `8` | Standalone server concurrency gate. |
| `CORTEX_RATE_LIMIT_RPS` / `CORTEX_RATE_LIMIT_BURST` | `20` / `60` | Standalone per-token token bucket. |
| `CORTEX_RATE_LIMIT_PER_MINUTE` | `0` | FastAPI per-user limiter; `0` disables. |

## Authentication and tokens

| Variable | Default | Notes |
|---|---|---|
| `CORTEX_MCP_API_KEY` | (empty) | Optional scoped token accepted only by `/mcp`. Keeps the app token out of MCP configs. |
| `CORTEX_MCP_API_KEY_SCOPES` | `read,write,export,maintenance` | Scopes of that token (`destructive` must be added explicitly). |
| `CORTEX_REQUIRE_SCOPED_API_TOKENS` | `0` | Server mode: only minted scoped tokens may call user endpoints; the admin token is control-plane only. |
| `CORTEX_MCP_TOOL_SURFACE` | `core` | Advertised MCP tool list: `core`, `full`, `coding`, `chat`, `chatgpt`. Advertisement never grants authorization. |
| `CORTEX_MCP_STREAMABLE` | `1` | Streamable-HTTP (SSE) compatibility on `/mcp`. |
| `CORTEX_SYNC_SIGNING_KEY` | (empty) | HMAC key for `/v1/sync/changes` manifests. |

## Retrieval quality (all local)

| Variable | Default | Notes |
|---|---|---|
| `CORTEX_EMBEDDING_PROVIDER` | `hash` | `hash` (offline, deterministic, 384-d), `model2vec` (offline, semantic, 256-d, needs the model on disk), `openai` (remote). |
| `CORTEX_MODEL2VEC_PATH` | (empty) | Directory produced by `scripts/setup_local.sh --with-model` (`config.json` + weights). |
| `CORTEX_MODEL2VEC_MODEL` | `minishlab/potion-base-8M` | Hugging Face id used when downloading. |
| `CORTEX_EMBEDDING_MODEL` / `CORTEX_EMBEDDING_DIMENSIONS` | `text-embedding-3-small` / `384` | OpenAI provider only. |
| `CORTEX_EMBEDDING_STRICT` | `0` | `1` makes indexing fail instead of falling back to hash when the provider is unavailable. |
| `CORTEX_RERANK` | (app sets `linear+mmr`) | Reranker blend; no-op under the hash provider. |
| `CORTEX_QUERY_PLAN` / `CORTEX_TEMPORAL_DECAY` | (app sets `1`) | Query planning and per-layer temporal decay. |
| `CORTEX_ENTITY_BOOST`, `CORTEX_CONTEXT_HOP`, `CORTEX_CONTEXT_HOP2`, `CORTEX_CONTEXT_HOP_MS`, `CORTEX_CONTEXT_HOP2_MS`, `CORTEX_RERANK_WEIGHTS_PATH`, `CORTEX_RETRIEVAL_FEEDBACK`, `CORTEX_SESSION_PREFETCH` | tuned defaults | Advanced retrieval knobs; see `backend/app/storage.py`. |

## Extraction

| Variable | Default | Notes |
|---|---|---|
| `ANTHROPIC_API_KEY` | (empty) | When set, captures are condensed with Claude. Unset = deterministic local extractor; nothing leaves the machine. |
| `CORTEX_EXTRACTION_MODEL` / `CORTEX_CONDENSE_MODEL` | `claude-opus-4-5` | Model ids for extraction / condensation. |
| `CORTEX_EXTRACTION_MODE` | auto | Force `local` or `llm`. |

## Behaviour

| Variable | Default | Notes |
|---|---|---|
| `CORTEX_AUTO_APPROVE_CAPTURES` | `0` | `1` skips the Review inbox for new captures. |
| `CORTEX_APP_BRAND` | `Cortex` | User-visible brand in backend strings (`Doppl` for the App Store build). |
| `CORTEX_WORKER_MODE` | `inline` | `external` moves queued jobs to `scripts/run_memory_worker.py`. |
| `CORTEX_WORKER_*` | see script | `--limit`, `--interval-seconds`, `--iterations`, `--worker-id`, `--failed-job-limit` defaults for the worker. |
| `CORTEX_STANDALONE_WORKER_*` | enabled, 15 s | Standalone server's built-in worker thread. |
| `CORTEX_OBSERVABILITY_ENABLED` | `0` | Enables `GET /v1/metrics` (admin). |
| `CORTEX_DELIVERY_ALLOW_INTERNAL` | `0` | Allow `/v1/delivery/send` to private/internal targets (SSRF guard off). Keep `0`. |
| `CORTEX_DEMO_EMBEDDINGS`, `CORTEX_DEMO_PORT`, `CORTEX_SMOKE_PORT` | | Used only by demo/eval scripts. |

## Multi-tenant server profile only

| Variable | Notes |
|---|---|
| `CORTEX_SHARD_MODE` (`local`\|`bucket`), `CORTEX_SHARD_ROOT`, `CORTEX_SHARD_COUNT` (16) | Sharded SQLite layout under one root. |
| `CORTEX_HOSTED_RUNTIME_TIER` (`sharded_sqlite`\|`postgres`), `CORTEX_HOSTED_DATABASE_URL` / `DATABASE_URL`, `CORTEX_HOSTED_VECTOR_BACKEND` | Postgres/pgvector tier is a readiness gate (`/ready` reports it), not an implemented storage backend in this tree. |
| `CORTEX_AUTH_ENABLED`, `CORTEX_AUTH_AUTOVERIFY`, `CORTEX_AUTH_EMAIL_MODE` (`log`\|`smtp`), `CORTEX_AUTH_RATE_LIMIT_PER_MINUTE`, `CORTEX_AUTH_ACCESS_TTL_SECONDS`, `CORTEX_AUTH_REFRESH_IDLE_TTL_SECONDS`, `CORTEX_AUTH_REFRESH_ABSOLUTE_TTL_SECONDS`, `CORTEX_ACCOUNTS_DB_PATH` | First-party accounts (argon2id passwords, access/refresh tokens). |
| `CORTEX_SMTP_HOST`, `CORTEX_SMTP_PORT`, `CORTEX_SMTP_USERNAME`, `CORTEX_SMTP_PASSWORD`, `CORTEX_SMTP_FROM_ADDR`, `CORTEX_SMTP_USE_STARTTLS`, `CORTEX_SMTP_USE_SSL` | Verification / reset mail. Mode `smtp` without a host degrades to the log sink. |
| `CORTEX_OIDC_GOOGLE_CLIENT_ID/SECRET`, `CORTEX_OIDC_GITHUB_CLIENT_ID/SECRET`, `CORTEX_OIDC_APPLE_CLIENT_ID/SECRET` | Social sign-in. |
| `CORTEX_KEK` / `CORTEX_KEK_FILE`, `CORTEX_KEK_VERSION`, `CORTEX_REQUIRE_ENCRYPTED_CREDENTIALS` | Key-encryption key for per-user credential encryption (CXE1). Escrow it offline. |
| `CORTEX_DEFAULT_MEMORY_QUOTA`, `CORTEX_PLAN_QUOTAS` (JSON) | Per-user memory quotas. |
| `CORTEX_BILLING_PROVIDER` (`paddle`\|`stripe`), `CORTEX_PADDLE_WEBHOOK_SECRET`, `CORTEX_PADDLE_API_KEY`, `CORTEX_STRIPE_WEBHOOK_SECRET`, `CORTEX_STRIPE_API_KEY` | Dormant unless provider + webhook secret are set. |
| `CORTEX_TURNSTILE_SITEKEY`, `CORTEX_TURNSTILE_SECRET` | Cloudflare Turnstile on public signup. |
| `CORTEX_BROKER_<PROVIDER>_CLIENT_ID/SECRET`, `CORTEX_OAUTH_BROKER_EXCHANGE_URL`, `CORTEX_GITHUB_OAUTH_CLIENT_ID`, `CORTEX_GITHUB_OAUTH_SCOPE`, `CORTEX_MANAGED_OAUTH_*`, `CORTEX_GOOGLE_OAUTH_*` | OAuth token-exchange broker for confidential connectors (Notion, GitHub, Google, Microsoft). |

## Build-time (macOS packaging only)

`CORTEX_BUNDLE_PYTHON`, `CORTEX_PYTHON_FRAMEWORK_SOURCE`, `CORTEX_BUNDLE_BACKEND_DEPS`,
`CORTEX_CODESIGN_IDENTITY`, `CORTEX_NESTED_CODESIGN_IDENTITY`, `CORTEX_CODESIGN_TIMESTAMP`,
`CORTEX_ENTITLEMENTS`, `CORTEX_CHILD_ENTITLEMENTS`, `CORTEX_DEVID_ENTITLEMENTS`,
`CORTEX_PROVISIONING_PROFILE`, `CORTEX_DISTRIBUTION_MODE` (`direct`\|`app-store`),
`CORTEX_APP_BUNDLE_NAME`, `CORTEX_DISPLAY_NAME`, `CORTEX_PRODUCT_NAME`, `CORTEX_SKIP_PYC`,
`CORTEX_REQUIRE_MODEL`, `CORTEX_NOTARY_PROFILE`, `CORTEX_RELEASE_STRICT`. See `macos/build.sh` and
`docs/APPLE_RELEASE.md`.

## Legacy prototype (not used by the app)

`capture.py`, `ingest.py`, `github_store.py`, `redis_store.py`, `mcp_server.py`, `ui.py` and
`instrumentation.py` at the repo root are the original prototype and read `REDIS_URL`,
`GITHUB_TOKEN`, `VOYAGE_API_KEY`, `ANTHROPIC_API_KEY` and Arize/OpenInference settings from
`requirements.txt`. They are kept for history and CI byte-compilation only; nothing in the backend
or the app imports them.

## External integrations and where data goes

| Integration | Trigger | Outbound host | Can be avoided? |
|---|---|---|---|
| Claude extraction | `ANTHROPIC_API_KEY` set | api.anthropic.com | Yes: leave unset (local extractor). |
| OpenAI embeddings | provider `openai` | api.openai.com | Yes: `hash` or `model2vec`. |
| Model download | `setup_local.sh --with-model` | huggingface.co, once | Yes: copy the `models/model2vec` folder from another machine. |
| Source connectors (Obsidian, GitHub, Slack, Notion, Linear, Jira, Readwise, Raindrop, Gmail, Drive, Outlook, Calendar ICS, Zotero) | user connects them | each provider's API | Yes: connect only local notes / file imports. Tokens are stored encrypted in the vault when a KEK is configured. |
| Social sign-in, SMTP, billing, Turnstile | server profile vars | provider hosts | Yes: single-user profile never enables them. |
| Update feed | macOS app checks `latest.json` | the configured feed URL | Yes: point the feed at your own host or disable in the app. |
