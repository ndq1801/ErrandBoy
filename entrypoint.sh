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
  jina:
    command: node
    args: ["/app/mcp/jina-fresh.js"]
    env:
      JINA_API_KEY: \${JINA_API_KEY}

plugins:
  enabled:
    - access-control

# Control model: shell commands need manual approval, background LLM review
# forks are disabled, memory/skill writes are saved directly (no approval),
# and the curator never runs. Keeps the gateway from acting without consent.
approvals:
  mode: manual
memory:
  nudge_interval: 0
  write_approval: false
skills:
  creation_nudge_interval: 0
  write_approval: false
curator:
  enabled: false

# Bound agent persistence: 25 tool iterations per turn (gateway + cron) stops
# long "keep trying alternatives" loops — the agent must report failure
# instead of hunting for workarounds for 30 minutes.
agent:
  max_turns: 25

# Show each user message's send-time to the model (e.g. [Sat 2026-08-15
# 10:00:00 +07]). Prevents the agent from inferring a stale "now" from old
# conversation history when a session is resumed hours/days later. Timestamps
# live in user messages only, so the cached system prompt stays byte-stable
# and the provider prefix cache is preserved.
gateway:
  message_timestamps:
    enabled: true

# Safe read-only terminal commands exempt from approval prompts (they also
# run past the fail-closed cron approval, so cron jobs may use them).
# Entries are exact or fnmatch globs over the FULL command string; compound
# commands (&&, |, >, ...) never match. Keep only commands with no write,
# delete, or exec capability.
command_allowlist:
  - "grep *"
  - "ls *"
  - "date *"
  - "stat *"
  - "wc *"
  - "head *"
  - "tail *"
  - "df *"
  - "du *"
  - "pwd"
  - "whoami"
  - "uname *"
  - "which *"
  - "dirname *"
  - "basename *"
  - "realpath *"
  - "readlink *"
  - "sort *"
  - "uniq *"
  - "cut *"
  - "tr *"
  - "hermes sessions list"
  - "hermes config get"
EOF

# Build a SINGLE merged auxiliary block. YAML duplicate keys would make the
# last block win (Hermes reloads/rewrites config.yaml), so writing multiple
# separate "auxiliary:" sections would silently drop earlier ones.
AUX_ENTRIES=""
if [ -n "${HERMES_VISION_MODEL:-}" ]; then
    AUX_ENTRIES="${AUX_ENTRIES}  vision:
    provider: ${HERMES_VISION_PROVIDER:-${HERMES_PROVIDER}}
    model: ${HERMES_VISION_MODEL}
"
    echo "Auxiliary vision model: ${HERMES_VISION_PROVIDER:-${HERMES_PROVIDER}}/${HERMES_VISION_MODEL}"
fi

# Title generation is DISABLED by default (auto-titling would otherwise use a
# fast/cheap provider model — glm-5 for opencode-go — instead of the main
# model). Only HERMES_TITLE_GENERATION=main opts back in with the main model.
case "${HERMES_TITLE_GENERATION:-off}" in
    main)
        AUX_ENTRIES="${AUX_ENTRIES}  title_generation:
    provider: ${HERMES_PROVIDER}
    model: ${HERMES_MODEL}
"
        echo "Auxiliary title_generation: main model (${HERMES_PROVIDER}/${HERMES_MODEL})"
        ;;
    *)
        AUX_ENTRIES="${AUX_ENTRIES}  title_generation:
    enabled: false
"
        echo "Auxiliary title_generation: disabled (HERMES_TITLE_GENERATION=${HERMES_TITLE_GENERATION:-unset})"
        ;;
esac

if [ -n "${AUX_ENTRIES}" ]; then
    cat >> "${HERMES_HOME}/config.yaml" <<EOF

auxiliary:
${AUX_ENTRIES}
EOF
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
JINA_API_KEY=${JINA_API_KEY:-}
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

# 7. Run mcp-finlog database migrations (idempotent — Alembic stamps head if
#    already applied, applies pending revisions otherwise).
if [ -n "${DATABASE_URL:-}" ] && [ -d /app/mcp-hub/mcp-finlog/alembic ]; then
    echo "Running mcp-finlog database migrations..."
    if ! (cd /app/mcp-hub/mcp-finlog && python -m alembic upgrade head); then
        echo "ERROR: mcp-finlog migration failed" >&2
        exit 1
    fi
    echo "mcp-finlog migrations up to date"
fi

exec hermes gateway run
