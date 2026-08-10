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

# 6. MCP hub: clone/pull + install deps at runtime (env-driven URL, so MCP
# updates land without rebuilding the image — same pattern as assistant-bot).
ensure_mcp_hub() {
    local repo="${MCP_HUB_REPO_URL:-https://github.com/ndq1801/slave_mcps.git}"
    local hub="/app/mcp-hub"
    if [ -z "${MCP_HUB_REPO_URL:-}" ]; then
        echo "MCP_HUB_REPO_URL not set — using default repo ${repo}"
    fi
    if [ -d "${hub}/.git" ]; then
        if ! git -C "${hub}" pull --ff-only --quiet; then
            echo "Warning: MCP hub update failed, using existing copy"
        fi
    else
        if ! git clone --depth 1 "${repo}" "${hub}"; then
            echo "ERROR: MCP hub clone failed from ${repo}" >&2
            exit 1
        fi
    fi
    # Node deps for every server folder with a package.json.
    for pkg in "${hub}"/*/package.json; do
        [ -f "${pkg}" ] || continue
        local dir
        dir="$(dirname "${pkg}")"
        echo "MCP hub: installing node deps for '$(basename "${dir}")'"
        if ! npm --prefix "${dir}" install --no-audit --no-fund; then
            echo "ERROR: npm install failed for '$(basename "${dir}")'" >&2
            exit 1
        fi
    done
    # Python deps for every server folder with a requirements.txt.
    for req in "${hub}"/*/requirements.txt; do
        [ -f "${req}" ] || continue
        local dir
        dir="$(dirname "${req}")"
        echo "MCP hub: installing python deps for '$(basename "${dir}")'"
        if ! (cd "${dir}" && pip install -q --break-system-packages -r requirements.txt); then
            echo "Warning: pip install failed for '$(basename "${dir}")'"
        fi
    done
    echo "MCP hub ready at ${hub}"
}

ensure_mcp_hub

exec hermes gateway run
