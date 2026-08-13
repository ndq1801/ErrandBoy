# ErrandBoy

Hermes Agent (Nous Research) personal assistant deployed on **Railway** as a
Telegram bot, backed by the MCP servers from
[slave_mcps](https://github.com/ndq1801/slave_mcps) (daily-report, finlog).

```
Telegram ──► Hermes gateway (polling)
                ├── model: deepseek-v4-flash via OpenCode Go (opencode.ai/zen/go/v1)
                ├── mcp_servers: daily_report (node), finlog (python), jina (npx)
                ├── plugins: access-control (per-user x per-tool)
                └── cron: scheduled jobs + wakeAgent gate scripts
```

## Repository layout

| Path | Purpose |
|---|---|
| `Dockerfile` | Build: python:3.13-slim + tini + Hermes Agent (git/node/npm for the runtime MCP hub clone) |
| `entrypoint.sh` | Every boot: generate config.yaml from env vars, materialize plugins/secrets into `$HERMES_HOME`, clone/update MCP hub (`MCP_HUB_REPO_URL`), then `hermes gateway run` |
| `railway.json` | Railway Dockerfile builder (no `startCommand` — it would bypass tini) |
| `hermes/cli-config.yaml` | Reference template of the env-driven defaults (entrypoint generates the real config) |
| `hermes/SOUL.md` | Assistant persona (copied to `$HERMES_HOME/SOUL.md`) |
| `plugins/access-control/` | Plugin: block state-changing MCP tools for unauthorized users |
| `cron/check_user_hour.py` | Example `wakeAgent` gate script (user-local-time cron) |
| `.env.example` | All Railway env vars to set |

## Deploy to Railway

1. Push this repo to GitHub, then create a Railway project from it
   (Dockerfile builder is automatic via `railway.json`).
2. **Create a Volume** mounted at `/root/.hermes` **before the first deploy**
   (Hobby: 5 GB per volume, 10 volumes/project — separate from any volume
   other projects use).
3. Set the env vars from `.env.example`. Minimum:
   - `OPENCODE_GO_API_KEY` — opencode-go key (same one the opencode CLI uses)
   - `TELEGRAM_BOT_TOKEN`, `TELEGRAM_ALLOWED_USERS`, `TELEGRAM_HOME_CHANNEL`
   - `DAILY_REPORT_BASE_URL`, `DAILY_REPORT_USERNAME`, `DAILY_REPORT_PASSWORD`
   - `DATABASE_URL` (finlog Postgres)
   - `JINA_API_KEY` (optional, for web page extraction via Jina Reader)
4. Deploy. The gateway uses Telegram **polling**, so Railway never sleeps the
   service and cron jobs fire on time. Check `hermes mcp list` / `hermes doctor`
   via `railway logs` on first boot.

## Notes

- **State lives in the Volume**: `state.db`, sessions, memories, cron jobs,
  `config.yaml`, `.env`, skills. The repo only carries templates — every
  restart re-applies them over the volume (git push = config deploy).
- **Config is env-driven, no defaults in code**: model/provider/base_url/api_mode (`HERMES_MODEL`, `HERMES_PROVIDER`, `HERMES_BASE_URL`, `HERMES_API_MODE`), timezone (`HERMES_TIMEZONE`) and the MCP hub URL (`MCP_HUB_REPO_URL`) are **required** Railway env vars — entrypoint fails fast on boot if any is missing. `entrypoint.sh` generates `config.yaml` from them every start.
- **Cron**: create jobs with `hermes cron create` (e.g. daily report reminder at 18:00). Timezone is global via `HERMES_TIMEZONE` (default Asia/Ho_Chi_Minh); for per-user local hours use `cron/check_user_hour.py` as the job's `--script` gate.
- **Slack MCP server** is intentionally not wired up in this project. To add
  it later, put the entry back in `cli-config.yaml` + pass `SLACK_*` env vars.

## Agent control model

The gateway must never act without your consent:

- **Shell commands** — `approvals.mode: manual`: every terminal command is
  prompted in Telegram for approve/deny.
- **File writes** — the `access-control` plugin gates `write_file`/`patch`:
  writes under `$HERMES_HOME` and `/tmp` are allowed, writes to `/app/**`
  are hard-blocked (infrastructure is immutable — change it via this repo),
  `.env` and any other path require your approval in chat.
- **Memory/skill writes** — staged for approval (`memory.write_approval`,
  `skills.write_approval`).
- **Cron changes** — the `cronjob` tool (create/update/pause/resume/remove/
  run) prompts for approval; only `list` is free.
- **Background LLM work** — disabled: memory/skill nudge forks
  (`memory.nudge_interval: 0`, `skills.creation_nudge_interval: 0`) and the
  curator (`curator.enabled: false`). The "typing…" bubble now appears only
  while the bot actually processes your message.
- **Cron sessions are pre-authorized** — scheduled jobs run without prompts
  (e.g. the 17:40 auto-complete report job). A cron that needs a shell
  command or an outside-path write will fail closed (nobody is there to
  approve) — design such jobs as `no_agent` scripts instead.

### Secrets

`entrypoint.sh` regenerates `$HERMES_HOME/.env` from Railway Variables on
every boot — anything hand-written into the container's `.env` is wiped at
the next boot (this is how the Railway token was lost once). Secrets must be
set as **Railway Variables**; scripts read them from the process environment
or from the regenerated `.env`.
