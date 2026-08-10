#!/usr/bin/env bash
# ErrandBoy — Hermes Agent gateway entrypoint (Railway).
# Every boot: (re)materialize config + plugins + secrets into HERMES_HOME,
# then start the gateway (Telegram polling keeps the Railway service awake,
# which also keeps cron jobs running on time).
set -euo pipefail

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
echo "HERMES_HOME=${HERMES_HOME}"

# Required env vars — no defaults in code. Fail fast with a clear message so a
# missing Railway Variable never boots a half-configured gateway silently.
for _var in HERMES_MODEL HERMES_PROVIDER HERMES_BASE_URL HERMES_API_MODE HERMES_TIMEZONE MCP_HUB_REPO_URL; do
    if [ -z "${!_var:-}" ]; then
        echo "ERROR: required env var ${_var} is not set (add it to Railway Variables)" >&2
        exit 1
    fi
done

mkdir -p "${HERMES_HOME}"/{memories,skills,sessions,cron,cron/output,hooks,logs,scripts,plugins}

# 1. Config: generated from env vars (all values come from the environment).
# \${...} references are left literal for Hermes to resolve from $HERMES_HOME/.env.
cat > "${HERMES_HOME}/config.yaml" <<EOF
model:
  default: ${HERMES_MODEL}
  provider: ${HERMES_PROVIDER}
  base_url: ${HERMES_BASE_URL}
  api_mode: ${HERMES_API_MODE}

# Cron runs in this timezone (cron jobs have no per-job timezone).
timezone: ${HERMES_TIMEZONE}

mcp_servers:
  daily_report:
    command: node
    args: ["/app/mcp-hub/mcp-daily-report/index.js"]
    cwd: /app/mcp-hub/mcp-daily-report
    env:
      DAILY_REPORT_BASE_URL: \${DAILY_REPORT_BASE_URL}
      DAILY_REPORT_USERNAME: \${DAILY_REPORT_USERNAME}
      DAILY_REPORT_PASSWORD: \${DAILY_REPORT_PASSWORD}
      DAILY_REPORT_LOGIN_FIELD: \${DAILY_REPORT_LOGIN_FIELD}
  finlog:
    command: python
    args: ["/app/mcp-hub/mcp-finlog/index.py"]
    cwd: /app/mcp-hub/mcp-finlog
    env:
      DATABASE_URL: \${DATABASE_URL}
      FINLOG_TELEGRAM_USER_ID: \${TELEGRAM_HOME_CHANNEL}
      FINLOG_MASTER_TELEGRAM_ID: \${TELEGRAM_HOME_CHANNEL}

plugins:
  enabled:
    - access-control
EOF

# Optional auxiliary vision model: used for image analysis when the main
# model is text-only (Hermes routes photos through the vision_analyze tool).
# Only written when HERMES_VISION_MODEL is set — provider falls back to the
# env-driven main provider, never hardcoded.
if [ -n "${HERMES_VISION_MODEL:-}" ]; then
    cat >> "${HERMES_HOME}/config.yaml" <<EOF

auxiliary:
  vision:
    provider: ${HERMES_VISION_PROVIDER:-${HERMES_PROVIDER}}
    model: ${HERMES_VISION_MODEL}
EOF
    echo "Auxiliary vision model: ${HERMES_VISION_PROVIDER:-${HERMES_PROVIDER}}/${HERMES_VISION_MODEL}"
fi

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
    local repo="${MCP_HUB_REPO_URL}"
    local hub="/app/mcp-hub"
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
