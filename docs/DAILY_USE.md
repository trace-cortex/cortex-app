# Using Cortex every day on this Mac

How the in-house deployment on this machine is wired, and the handful of habits that make it
useful. Everything runs locally; nothing leaves the Mac unless you connect an external source.

## What is running

| Piece | Where | Started by |
|---|---|---|
| Memory engine (backend) | `127.0.0.1:8766`, launchd agent `com.cortex.local.backend` | at login, restarts on crash |
| Memory store (vault) | `~/Library/Application Support/Cortex/Cortex.vault` | the engine |
| On-device semantic embeddings | `~/cortex-app/models/model2vec` (potion-base-8M) | the engine; no network |
| Cortex app | `/Applications/Cortex.app` | you (add it to Login Items to have it always in the menu bar) |
| Claude Desktop | MCP server `cortex` in its config, token scoped read+write | Claude Desktop (restart it once) |
| Claude Code | MCP server `cortex` in `~/.claude.json`, separate read+write token | next Claude Code session |

The app does not run its own engine on this Mac (the dev build would fall back to the system
Python 3.9). It connects to the launchd engine because both use the same vault path and the same
API token, seeded in `~/Library/Application Support/Cortex/credentials.json`.

## The daily loop

1. **Capture.** Three ways, pick what fits:
   - In the app: Quick capture (menu bar) or paste into Home. Optional global hotkey
     `Cmd+Shift+V` saves the clipboard (enable it in Connections & Privacy).
   - From Claude Desktop / Claude Code: ask Claude to "remember this" or "save to Cortex"; the
     `remember_this` MCP tool writes a capture.
   - From a notes folder or Obsidian vault: connect it once in Connections & Privacy; it syncs on
     its own.
2. **Review (2 minutes a day).** Open the Review tab, approve what is true and useful, archive the
   rest. Only approved memory is retrievable. If you would rather skip the inbox, set
   `CORTEX_AUTO_APPROVE_CAPTURES=1` in `~/cortex-app/.env` and restart the engine.
3. **Ask.** The Ask tab answers with citations or says it has nothing. Claude Desktop and Claude
   Code get the same via the `ask_memory`, `search_memory`, `get_context` and `use_cortex` tools:
   start a prompt with "check Cortex first" until it becomes habit.
4. **Let agents load your model.** `GET /v1/agent-adaptation` and the `profile/adaptation` MCP
   resource give any tool your calibration brief (voice, preferences, decisions).

## Importing what you already have

Connections & Privacy > sources. Supported today: a local notes / Obsidian folder (live sync),
ChatGPT / Claude / Perplexity / Notion exports (drag and drop or Import), GitHub, Slack, Notion,
Linear, Jira, Readwise, Raindrop, Gmail / Drive / Calendar, Outlook, Zotero (token or OAuth; those
do talk to their vendors). Imports land in Review first.

## Looking after it

```bash
cd ~/cortex-app
scripts/health_check.sh                                    # 4 checks, HEALTHY = fine
tail -f .run/launchd.err.log                               # engine log
launchctl kickstart -k gui/$(id -u)/com.cortex.local.backend   # restart the engine
scripts/backup_local.sh                                    # WAL-safe backup to ./backups (keeps 14)
```

Nightly backups: the plist in `docs/OPERATIONS.md` ("Backups") schedules `scripts/backup_local.sh`
at 02:30; load it once with `launchctl load -w`. Copy archives off the machine occasionally; they
contain your API token.

Upgrading: `git pull && scripts/setup_local.sh && launchctl kickstart -k gui/$(id -u)/com.cortex.local.backend`.

## Tokens (where they live, how to rotate)

| Token | Purpose | Location |
|---|---|---|
| `cxa_…` (CORTEX_API_KEY) | app and operator access to the full REST API | `~/cortex-app/.env`, mirrored in the app's credential store |
| `cxm_…` (CORTEX_MCP_API_KEY) | the app's own MCP token for tools it configures | same two places |
| `cxm_…` "Claude Desktop" | read+write MCP token | Claude Desktop config only |
| `cxm_…` "Claude Code" | read+write MCP token | `~/.claude.json` only |

Revoke or re-issue MCP tokens in the app (Connections & Privacy > connected AI tools) or with
`GET /v1/integrations/tokens`. To rotate the main token, change it in `.env`, restart the engine,
then update it in the app under Connections & Privacy > Advanced.

## If something looks off

| Symptom | Do |
|---|---|
| App says the engine is unreachable | `scripts/health_check.sh`; if unhealthy, `tail .run/launchd.err.log`, then kickstart |
| App says "port 8766 may already be in use" | the engine and the app disagree on vault path or token; see `docs/INSTALLATION.md` section 5 |
| Claude Desktop does not list Cortex tools | restart Claude Desktop; check `~/Library/Application Support/Claude/claude_desktop_config.json` has `mcpServers.cortex` |
| Search feels keyword-only | `GET /v1/diagnostics` should show `embedding.provider: model2vec`, `degraded: false` |
| Want a clean slate | Connections & Privacy > Advanced > reset, or `DELETE /v1/user-data` |
