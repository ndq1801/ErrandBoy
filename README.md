# ErrandBoy

Hermes Agent (Nous Research) personal assistant deployed on a **VPS** as a
Telegram bot, backed by the MCP servers from
[slave_mcps](https://github.com/ndq1801/slave_mcps) (daily-report, finlog).

```
Telegram ──► Hermes gateway (polling)
                ├── model: deepseek-v4-flash via OpenCode Go (opencode.ai/zen/go/v1)
                ├── mcp_servers: daily_report (node), finlog (python), jina (node, no-cache wrapper)
                ├── plugins: access-control (per-user x per-tool)
                └── cron: scheduled jobs + wakeAgent gate scripts
```

## Repository layout

| Path | Purpose |
|---|---|
| `Dockerfile` | Build: python:3.13-slim + tini + Hermes Agent (git/node/npm for the runtime MCP hub clone) |
| `entrypoint.sh` | Every boot: generate config.yaml from env vars, materialize plugins/secrets into `$HERMES_HOME`, clone/update MCP hub (`MCP_HUB_REPO_URL`), then `hermes gateway run` |
| `docker-compose.yml` | Docker Compose: postgres:17 + errandboy service |
| `hermes/cli-config.yaml` | Reference template of the env-driven defaults (entrypoint generates the real config) |
| `hermes/SOUL.md` | Assistant persona (copied to `$HERMES_HOME/SOUL.md`) |
| `plugins/access-control/` | Plugin: block state-changing MCP tools for unauthorized users |
| `cron/check_user_hour.py` | Example `wakeAgent` gate script (user-local-time cron) |
| `.env.example` | All env vars to set |

## Deploy to VPS

### Quick setup (recommended)

Run the setup script — it installs dependencies, clones the repo, and starts
the containers:

```bash
# Download and run the setup script
curl -sL https://raw.githubusercontent.com/ndq1801/ErrandBoy/main/scripts/vps-setup.sh | bash
```

Or clone the repo first, then run the script:

```bash
git clone https://github.com/ndq1801/ErrandBoy.git /srv/errandboy
cd /srv/errandboy
chmod +x scripts/vps-setup.sh
./scripts/vps-setup.sh
```

### Manual setup

If you prefer to set up manually, install these dependencies on the VPS host
(outside Docker):

| Dependency | Purpose | Install |
|---|---|---|
| **Docker** | Run containers | `curl -fsSL https://get.docker.com \| sh` |
| **docker-compose** | Orchestrate services | Included with Docker 20+ (`docker compose`) |
| **Git** | Clone repo | `apt install git` |
| **rclone** | Backup database to OneDrive | `curl -fsSL https://rclone.org/install.sh \| bash` |

Then:

1. Clone the repo: `git clone https://github.com/ndq1801/ErrandBoy.git /srv/errandboy`
2. Create `.env`: `cp .env.example .env && nano .env` (fill in your values)
3. Build and start: `docker compose up -d --build`

### Notes

- The gateway uses Telegram **polling**, so the service stays awake and cron
  jobs fire on time. Check `hermes mcp list` / `hermes doctor` via
  `docker compose logs errandboy` on first boot.
- For OneDrive backups, configure rclone: `rclone config` (run once, follow
  the interactive setup for Microsoft OneDrive).
- Dependencies are installed on the **VPS host**, not inside Docker containers.
  This means they persist across container recreates.

## Notes

- **State lives in the Docker volume**: `state.db`, sessions, memories, cron
  jobs, `config.yaml`, `.env`, skills. The repo only carries templates —
  every restart re-applies them over the volume.
- **Config is env-driven, no defaults in code**: model/provider/base_url/api_mode (`HERMES_MODEL`, `HERMES_PROVIDER`, `HERMES_BASE_URL`, `HERMES_API_MODE`), timezone (`HERMES_TIMEZONE`) and the MCP hub URL (`MCP_HUB_REPO_URL`) are **required** env vars — entrypoint fails fast on boot if any is missing. `entrypoint.sh` generates `config.yaml` from them every start.
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
- **Memory/skill writes** — saved directly, no approval (`memory.write_approval: false`, `skills.write_approval: false`).
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

`entrypoint.sh` regenerates `$HERMES_HOME/.env` from the container env on
every boot — anything hand-written into the container's `.env` is wiped at
the next boot. Secrets must be set in the container env (via `docker-compose`
`env_file`); scripts read them from the process environment or from the
regenerated `.env`.
