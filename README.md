# ErrandBoy

Hermes Agent (Nous Research) personal assistant deployed on **Railway** as a
Telegram bot, backed by the MCP servers from
[slave_mcps](https://github.com/ndq1801/slave_mcps) (daily-report, finlog).

```
Telegram ──► Hermes gateway (polling)
                ├── model: deepseek-v4-flash via OpenCode Go (opencode.ai/zen/go/v1)
                ├── mcp_servers: daily_report (node), finlog (python)
                ├── plugins: access-control (per-user x per-tool)
                └── cron: scheduled jobs + wakeAgent gate scripts
```

## Repository layout

| Path | Purpose |
|---|---|
| `Dockerfile` | Build: python:3.13-slim + tini + Hermes Agent + pre-installed MCP servers |
| `entrypoint.sh` | Every boot: materialize config/plugins/secrets into `$HERMES_HOME`, then `hermes gateway run` |
| `railway.json` | Railway Dockerfile builder (no `startCommand` — it would bypass tini) |
| `hermes/cli-config.yaml` | Hermes `config.yaml` template (model, timezone, mcp_servers, plugins) |
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
4. Deploy. The gateway uses Telegram **polling**, so Railway never sleeps the
   service and cron jobs fire on time. Check `hermes mcp list` / `hermes doctor`
   via `railway logs` on first boot.

## Notes

- **State lives in the Volume**: `state.db`, sessions, memories, cron jobs,
  `config.yaml`, `.env`, skills. The repo only carries templates — every
  restart re-applies them over the volume (git push = config deploy).
- **Config changes**: edit `hermes/cli-config.yaml` and redeploy; the
  entrypoint copies it over the volume copy each boot.
- **Cron**: create jobs with `hermes cron create` (e.g. daily report reminder
  at 18:00). Timezone is global via `timezone` in cli-config.yaml
  (Asia/Ho_Chi_Minh); for per-user local hours use `cron/check_user_hour.py`
  as the job's `--script` gate.
- **Slack MCP server** is intentionally not wired up in this project. To add
  it later, put the entry back in `cli-config.yaml` + pass `SLACK_*` env vars.
