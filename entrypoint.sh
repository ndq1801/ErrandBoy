#!/usr/bin/env bash
# ErrandBoy — Hermes Agent gateway entrypoint (Railway).
# Every boot: (re)materialize config + plugins + secrets into HERMES_HOME,
# then start the gateway (Telegram polling keeps the Railway service awake,
# which also keeps cron jobs running on time).
set -euo pipefail

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
echo "HERMES_HOME=${HERMES_HOME}"

mkdir -p "${HERMES_HOME}"/{memories,skills,sessions,cron,cron/output,hooks,logs,scripts,plugins}

# 1. Config: repo file wins on every boot (git push = config deploy).
cp /app/hermes/cli-config.yaml "${HERMES_HOME}/config.yaml"

# 2. Plugins (versioned in this repo).
if [ -d /app/plugins ]; then
    cp -r /app/plugins/. "${HERMES_HOME}/plugins/"
fi

# 3. Cron gate scripts -> $HERMES_HOME/scripts (Hermes resolves them there).
if [ -d /app/cron ]; then
    cp -r /app/cron/. "${HERMES_HOME}/scripts/"
fi

# 4. Secrets: Hermes loads $HERMES_HOME/.env with override=True.
cat > "${HERMES_HOME}/.env" <<EOF
OPENCODE_GO_API_KEY=${OPENCODE_GO_API_KEY:-}
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:-}
TELEGRAM_ALLOWED_USERS=${TELEGRAM_ALLOWED_USERS:-}
TELEGRAM_HOME_CHANNEL=${TELEGRAM_HOME_CHANNEL:-}
TELEGRAM_HOME_CHANNEL_NAME=${TELEGRAM_HOME_CHANNEL_NAME:-}
DATABASE_URL=${DATABASE_URL:-}
DAILY_REPORT_BASE_URL=${DAILY_REPORT_BASE_URL:-}
DAILY_REPORT_USERNAME=${DAILY_REPORT_USERNAME:-}
DAILY_REPORT_PASSWORD=${DAILY_REPORT_PASSWORD:-}
DAILY_REPORT_LOGIN_FIELD=${DAILY_REPORT_LOGIN_FIELD:-email}
BRAVE_SEARCH_API_KEY=${BRAVE_SEARCH_API_KEY:-}
EOF
chmod 600 "${HERMES_HOME}/.env"

# 5. Persona (optional).
if [ -f /app/hermes/SOUL.md ]; then
    cp /app/hermes/SOUL.md "${HERMES_HOME}/SOUL.md"
fi

exec hermes gateway run
