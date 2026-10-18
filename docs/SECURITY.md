# Security: assumptions, findings and hardening for an in-house deployment

Companion to `docs/SECURITY_REVIEW.md` (the product-level review) and `docs/TRUST_CONTROLS.md`
(per-tool permissions). This document covers what an operator must know to run the backend safely
on their own infrastructure.

## Threat model for the single-user profile

- The backend binds to `127.0.0.1:8766`. Anything on the same machine that can reach loopback and
  holds the bearer token has full access; nothing off the machine can reach it.
- All memory lives in plain files under the vault plus a SQLite index. Disk encryption (FileVault
  on macOS, LUKS on Linux) is the at-rest protection; the backend does not encrypt the vault
  itself. Connector credentials are encrypted (CXE1) only when a KEK is configured
  (`CORTEX_KEK`/`CORTEX_KEK_FILE`); without one they are stored in `credentials.json` in the vault.
- The API token is the only authentication. Treat `.env` and every backup archive as secrets.

## Audit results (October 2026, this tree)

| Check | Result |
|---|---|
| Committed secrets (tokens, keys, certificates) across all tracked files | none found; only test fixtures with obviously fake values (`xoxb-test`, `test-token`) |
| Tracked env/key files | only `.env.example`; `.env`, `*.pem`, `*.key`, `*.p12` are git-ignored |
| `pip-audit --strict` on `backend/requirements.txt`, `backend/runtime-requirements.txt` and the installed lockfile | no known vulnerabilities |
| `bandit -ll` (medium and above) over `backend/` and `scripts/` | 8 high findings (B324, SHA1 used for content fingerprints), fixed by marking them `usedforsecurity=False`; now 0 medium/high. The upstream CI security job had been failing on exactly these since August 2026. |
| Default credentials | the sample `dev-local-key` token is refused at startup unless `CORTEX_ALLOW_INSECURE_DEV_TOKEN=1` |
| Debug/dev endpoints | none exposed without the token; `/capture` HTML page requires `?token=`; `/docs` (OpenAPI) is served by FastAPI mode only and reveals routes, not data |
| Unauthenticated surface | `GET /`, `GET /health`, `GET /ready` (no user data), `/account/*` HTML pages only when accounts are enabled |
| Auth rejection | wrong or missing bearer returns 401 (verified by `scripts/health_check.sh`) |
| Authorization model | scoped tokens (`read`, `write`, `export`, `maintenance`, `destructive`) checked on every call; MCP tool advertisement never grants scope; per-source trust policies and redaction on by default |
| Outbound traffic in the default configuration | none. Anthropic/OpenAI/connector hosts are contacted only when the corresponding key or connector is configured. `certifi` is used for TLS verification; `CORTEX_DISABLE_SSL` exists for packaged-app diagnostics and must stay unset. |
| SSRF | `/v1/delivery/send` refuses private/internal targets and non-HTTPS public targets unless `CORTEX_DELIVERY_ALLOW_INTERNAL=1` |
| SQL injection | all user values are bound parameters; the f-string SQL that bandit skips (B608) interpolates only hard-coded predicate literals (reviewed in `storage.py`) |
| Password hashing (server profile) | argon2id via `argon2-cffi` |

## Hardening checklist

1. **Keep loopback.** Do not set `CORTEX_HOST=0.0.0.0` on bare metal. Expose the API to a network
   only through a TLS-terminating reverse proxy (Caddy with automatic certificates is provided in
   `deploy/Caddyfile` and the Compose `proxy` profile; Cloudflare Tunnel is documented in
   `deploy/macmini/README.md`). Bearer tokens over plain HTTP on a LAN are capturable.
2. **One token per client.** Mint scoped MCP tokens (`POST /v1/integrations/mcp-token` or
   `CORTEX_MCP_API_KEY`) for AI tools and the browser extension; keep the main token for the app
   and operators. Revoke from the app's Connections & Privacy sheet or `GET/DELETE
   /v1/integrations/tokens`.
3. **Rotate the main token** by editing `CORTEX_API_KEY` in `.env` and restarting; update the
   macOS app's Advanced backend token and any MCP config afterwards. Scoped tokens stored in the
   vault are unaffected.
4. **File permissions.** `.env` is created with mode 600; keep the vault directory readable only by
   the service user (`chmod -R go-rwx backend/data` or run under a dedicated user/Docker).
5. **Backups are secrets.** `scripts/backup_local.sh` archives include `.env`. Encrypt before
   leaving the machine (`age`, `gpg`, or an encrypted bucket).
6. **Firewall.** macOS: the service never listens on a non-loopback interface, so no rule is
   required; still enable the application firewall. Linux: `ufw default deny incoming`, allow only
   SSH and the proxy ports, as `deploy/bootstrap.sh` does.
7. **Dependencies.** Versions are pinned in `backend/requirements.lock.txt`. Re-run
   `pip-audit -r backend/requirements.lock.txt` on each upgrade and after security advisories.
8. **Models and data stay local.** Use the `hash` or `model2vec` embedding provider and leave
   `ANTHROPIC_API_KEY`/`OPENAI_API_KEY` unset for a fully offline posture. Source connectors are
   opt-in per source.
9. **Server profile extras.** If you enable accounts: generate and escrow the KEK offline, turn off
   `CORTEX_AUTH_AUTOVERIFY` before any public exposure, set non-zero rate limits and quotas,
   enable Turnstile on signup, and use SMTP with SPF/DKIM for verification mail.
10. **Least privilege for the process.** Run as an unprivileged user (Docker image already does;
    `deploy/systemd/cortex-api.service` uses `NoNewPrivileges`, `ProtectSystem=strict`,
    `ProtectHome`, `PrivateTmp`). On macOS the LaunchAgent runs as your user; for a shared machine
    promote it to a dedicated service account.

## Residual risks and open items

- The macOS dev build (`CORTEX_BUNDLE_PYTHON=0`) is ad-hoc signed and runs the backend with the
  system `python3.12`; it is for local use only. Distribution requires Developer ID signing and
  notarisation (`docs/APPLE_RELEASE.md`).
- `CORTEX_ALLOW_EXTENSION_CORS=1` by default allows browser-extension origins to call the API with
  a token; set `0` if you do not use the extension.
- The legacy prototype files at the repository root (`redis_store.py`, `github_store.py`, ...) are
  unused by the product and un-audited beyond byte-compilation; do not run them in production.
- bandit's 817 low-severity findings (mostly `assert`, `subprocess` in build/eval scripts and
  broad exception handlers) were not individually reviewed.
