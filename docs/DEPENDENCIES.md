# Dependencies, licences, external services and self-hosting limits

Project licence: MIT (`LICENSE`, copyright Doppl). Everything required to run the backend and build
the macOS app is open source or Apple-provided.

## Runtime inventory

| Component | Version / pin | Purpose | Licence | Runs locally? |
|---|---|---|---|---|
| CPython | 3.12 (3.11+) | backend runtime | PSF | yes |
| fastapi | 0.143.3 | HTTP API (`backend/app/main.py`) | MIT | yes |
| starlette | 1.8.0 | ASGI toolkit under FastAPI | BSD-3 | yes |
| uvicorn | 0.54.0 | ASGI server | BSD-3 | yes |
| pydantic / pydantic-core | 2.14.1 / 2.50.1 | request/response models | MIT | yes |
| python-dotenv | 1.2.4 | listed; the backend does not load `.env` itself | BSD-3 | yes |
| anthropic | 1.15.0 | optional Claude extraction client | MIT | client only; service is remote and optional |
| sqlite-vec | 0.1.9 | vector KNN inside SQLite | MIT / Apache-2.0 | yes |
| pysqlite3 | 0.6.1 | SQLite module built against system libsqlite3 (extension loading, FTS5) | zlib-style (pysqlite) | yes, compiled at install |
| model2vec | 0.10.0 | on-device static embeddings | MIT | yes |
| numpy, tokenizers, safetensors, huggingface_hub, joblib, tqdm, fsspec, filelock, hf-xet, cloudpickle, jinja2, markupsafe, docstring_parser, pyyaml, packaging | pinned in lockfile | transitive deps of model2vec | BSD / Apache / MIT / MPL-2.0 (tqdm) | yes; huggingface_hub is used only for the one-time model download |
| argon2-cffi (+bindings), cffi, pycparser | 25.1.0 | password hashing (server profile) | MIT | yes |
| cryptography | 50.0.2 | CXE1 credential encryption, OIDC verification | Apache-2.0 / BSD-3 | yes |
| certifi | 2026.7.22 | CA bundle for outbound TLS | MPL-2.0 | yes |
| anyio, httpx2, httpcore2, h11, sniffio, idna, jiter, typing_extensions, annotated-types, annotated-doc, typing-inspection, opentelemetry-api, truststore | pinned | transitive (anthropic / fastapi) | MIT / BSD / Apache | yes |

Full pinned list: `backend/requirements.lock.txt` (46 packages, generated with
`uv pip compile --universal`). Dev/test only: pytest, bandit, pip-audit.

### Build and tooling

| Tool | Needed for | Available without admin? |
|---|---|---|
| Xcode Command Line Tools (`swiftc`, `codesign`, `plutil`) | `macos/build.sh` (full Xcode not required) | yes (`xcode-select --install`) |
| Python.framework 3.12 at `/Library/Frameworks` | only `CORTEX_BUNDLE_PYTHON=1` / App Store builds | python.org installer |
| Developer ID certificate + notarytool profile | only `macos/package_release.sh` | Apple Developer Program |
| Node 22 + npm | `packages/obsidian-cortex-plugin` (esbuild, typescript), `sdk/typescript` (tsc, node --test), `packages/openclaw-cortex-context` | nodejs.org; not installed on the verification machine, so these packages were not rebuilt (the committed `main.js` is used by the app bundle) |
| Docker Engine + Compose v2 | `Dockerfile`, `docker-compose.yml` | not installed on the verification machine; image untested there |
| sqlite3 CLI | `deploy/backup.sh` (server profile) | preinstalled on macOS; `apt install sqlite3` |

### Vendored / bundled

| Item | Location | Licence |
|---|---|---|
| Obsidian API typings | `packages/obsidian-api` | MIT (upstream obsidianmd/obsidian-api) |
| potion-base-8M embedding model | downloaded to `models/model2vec` on demand | MIT (minishlab) |
| Sample notes | `macos/SampleNotes` | project |

## External services

| Service | Used by | Required? | Self-hostable alternative |
|---|---|---|---|
| Anthropic API | LLM extraction/condensation when `ANTHROPIC_API_KEY` is set | no | deterministic local extractor (default) |
| OpenAI embeddings | `CORTEX_EMBEDDING_PROVIDER=openai` | no | `hash` (default) or `model2vec` (local semantic) |
| Hugging Face Hub | one-time download of the embedding model | no (optional, once) | copy `models/model2vec` between machines |
| Source connectors: GitHub, Slack, Notion, Linear, Jira, Readwise, Raindrop, Google (Gmail/Drive/Calendar), Microsoft (Outlook), Zotero, Obsidian/local notes | user-initiated syncs | no | local notes, Obsidian vault, file/export imports need no network |
| OAuth brokers, social sign-in (Google/GitHub/Apple), SMTP, Paddle/Stripe, Cloudflare Turnstile | multi-tenant server profile | no | not needed in single-user mode |
| GitHub Releases / `latest.json` feed | macOS app update check | no | host `latest.json` yourself or ignore |
| Cloudflare Tunnel, Caddy/Let's Encrypt | optional ingress for a shared server | no | any reverse proxy with your own certificates |
| Redis, Voyage AI, GitHub (as a store), Arize/Phoenix, Streamlit | legacy prototype files at repo root only | no | not part of the product |

## Self-hosting boundaries (what is and is not possible)

- **Fully offline single-user operation: yes.** Backend, MCP, search, review, export, backups and
  the macOS app all work with no network after dependencies are installed. Semantic embeddings
  need the one-time model download or a copied model folder.
- **Multi-user server on your hardware: yes**, with the sharded-SQLite tier (`deploy/`). The
  Postgres/pgvector tier mentioned in the docs is a readiness gate, not an implemented backend in
  this tree; do not plan on it.
- **Cloud sync between devices (E2EE design in `docs/ACCOUNTS_ENCRYPTION_DESIGN.md`)**: requires
  running the server profile with accounts; there is no third-party dependency, but it is beta.
- **Not self-hostable:** nothing in the core. Third-party source connectors inherently talk to
  their vendors; social sign-in and payments inherently need those providers.
- **Licensing constraints:** none beyond MIT for the code; the embedding model is MIT; Obsidian
  typings are MIT. Connector use is subject to each provider's API terms.
