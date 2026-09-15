#!/usr/bin/env bash
# ErrandBoy — Hermes Agent gateway entrypoint (Docker Compose on VPS).
# Every boot: (re)materialize config + plugins + secrets into HERMES_HOME,
# then start the gateway (Telegram polling keeps the service awake,
# which also keeps cron jobs running on time).
set -euo pipefail

HERMES_HOME="${HERMES_HOME:-/root/.hermes}"
echo "HERMES_HOME=${HERMES_HOME}"

# Persistent CLI tool root (single source: TOOLS_ROOT env, see .env.example).
TOOLS_ROOT="${TOOLS_ROOT:-/opt/tools}"
echo "TOOLS_ROOT=${TOOLS_ROOT}"

# Required env vars — no defaults in code. Fail fast with a clear message so a
# missing env var never boots a half-configured gateway silently.
for _var in HERMES_MODEL HERMES_PROVIDER HERMES_BASE_URL HERMES_API_MODE HERMES_TIMEZONE MCP_HUB_REPO_URL ROUTER9_API_KEY; do
    if [ -z "${!_var:-}" ]; then
        echo "ERROR: required env var ${_var} is not set (add it to the container env)" >&2
        exit 1
    fi
done

mkdir -p "${HERMES_HOME}"/{memories,skills,sessions,cron,cron/output,hooks,logs,scripts,plugins}

# Persistent tool bin (tools_data / host bind): CLI tools the agent installs
# here survive redeploys. Put it FIRST in PATH so agent-installed tools win
# over ephemeral system-wide ones (which reset on every --force-recreate).
mkdir -p "${TOOLS_ROOT}/bin"
export PATH="${TOOLS_ROOT}/bin:${PATH}"

# Optional context-window override. Hermes resolves a model's context length
# dynamically, but a 9router COMBO returns no metadata from /v1/models, so the
# probe fails and Hermes falls back to its hardcoded 256k default. The gateway
# is no better a source: its per-model context_length is a hardcoded glob guess
# that it never enforces, and the upstream provider publishes none. So this
# value is what actually governs history compaction — too small and the bot
# summarises away context it could still have sent. Unset lets Hermes decide.
CONTEXT_LENGTH_LINE=""
if [ -n "${HERMES_CONTEXT_LENGTH:-}" ]; then
    CONTEXT_LENGTH_LINE="  context_length: ${HERMES_CONTEXT_LENGTH}"
    echo "Model context length override: ${HERMES_CONTEXT_LENGTH}"
fi

# 1. Config: generated from env vars (all values come from the environment).
# \${...} references are left literal for Hermes to resolve from $HERMES_HOME/.env.
cat > "${HERMES_HOME}/config.yaml" <<EOF
# Custom OpenAI-compatible gateway (9router). Declared as a NAMED provider so the
# model picker can probe {base_url}/models and list what the gateway offers; the
# main model still uses provider: custom (the documented form for an arbitrary
# endpoint) and reads its key from ROUTER9_API_KEY via a \${...} reference below.
providers:
  "9router":
    api: ${HERMES_BASE_URL}
    key_env: ROUTER9_API_KEY
    transport: chat_completions

model:
  default: ${HERMES_MODEL}
  provider: ${HERMES_PROVIDER}
  base_url: ${HERMES_BASE_URL}
  api_mode: ${HERMES_API_MODE}
  api_key: \${ROUTER9_API_KEY}
${CONTEXT_LENGTH_LINE}

# Hide the built-in OpenCode provider group from the /model picker. Hermes ships
# opencode-zen/opencode-go (plus the keyless opencode-free) in its static
# catalog, so they appear in the picker regardless of what this bot configures.
# Excluding the group keeps a stray pick from selecting a provider this
# deployment no longer sets up.
model_catalog:
  excluded_providers:
    - opencode

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
  obsidian:
    command: node
    args: ["/app/mcp-hub/mcp-obsidian/index.js"]
    cwd: /app/mcp-hub/mcp-obsidian
    env:
      OBSIDIAN_VAULT_PATH: \${OBSIDIAN_VAULT_PATH}
  calendar:
    command: node
    args: ["/app/mcp-hub/mcp-calendar/index.js"]
    cwd: /app/mcp-hub/mcp-calendar
    env:
      GOOGLE_CALENDAR_CLIENT_ID: \${GOOGLE_CALENDAR_CLIENT_ID}
      GOOGLE_CALENDAR_CLIENT_SECRET: \${GOOGLE_CALENDAR_CLIENT_SECRET}
      GOOGLE_CALENDAR_REFRESH_TOKEN: \${GOOGLE_CALENDAR_REFRESH_TOKEN}
      GOOGLE_CALENDAR_ID: \${GOOGLE_CALENDAR_ID}
      GOOGLE_CALENDAR_TIMEZONE: \${GOOGLE_CALENDAR_TIMEZONE}

plugins:
  enabled:
    - access-control
    # Image generation backend for the custom gateway (user plugin copied into
    # $HERMES_HOME/plugins/image_gen/9router by step 2). User plugins are opt-in:
    # without this entry the image_generate tool stays hidden from the agent.
    - image_gen/9router

# Control model: shell approvals run in smart mode — the guardian
# auto-approves safe commands while approvals.deny hard-blocks anything
# referencing /app or defined-source files. Background LLM review forks are
# disabled, memory/skill writes are saved directly (no approval), and the
# curator never runs. Keeps the gateway from acting without consent.
approvals:
  mode: smart
  deny:
    - "*config.yaml*"
    - "*SOUL.md*"
    - "*cli-config.yaml*"
    - "*/.env*"
    - "*/app/*"
    - "* /app*"
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
  # Standing operator instructions injected into the system prompt as a
  # stable block ("Operator instructions (from config):"). Prefer dedicated
  # tools over shell workarounds so the agent uses the right tool for the job.
  coding_instructions:
    - "Prefer the dedicated tool for a task over shell workarounds: use the 'cronjob' tool for scheduling (never edit ~/.hermes/cron/jobs.json or run crontab directly), use MCP tools for their domains, and use read_file/write_file/patch for file operations."
    - "Reserve the terminal for builds, installs, git, processes, scripts, network, and package managers."
    - "When you need a CLI tool to persist across deploys (so the user does not have to reinstall it after each redeploy), ALWAYS install it into ${TOOLS_ROOT}/bin (a persistent volume; already first on PATH). NEVER install tools system-wide via apt-get or into /usr/local/bin or ~/.local/bin — those are reset (wiped) on every container redeploy and the user will lose the tool. Prefer release binaries or user-space installs rewritten into ${TOOLS_ROOT}/bin (e.g. curl a tarball and copy the binary there, incl. for pip/npm-installed CLIs)."

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

# Optional: image generation through the custom gateway. Requires the repo's
# plugins/image_gen/9router backend (copied into $HERMES_HOME in step 2 and
# enabled under plugins.enabled). The provider id is the backend's registered
# name and this repo ships exactly one image backend, so it is a literal rather
# than an env knob. The model id below is a 9router combo name and is forwarded
# verbatim, so generation only returns an image once that combo points at a real
# image model.
if [ -n "${HERMES_IMAGE_MODEL:-}" ]; then
    cat >> "${HERMES_HOME}/config.yaml" <<EOF

image_gen:
  provider: 9router
  model: ${HERMES_IMAGE_MODEL}
EOF
    echo "Image generation: 9router/${HERMES_IMAGE_MODEL}"
fi

# Build a SINGLE merged auxiliary block. YAML duplicate keys would make the
# last block win (Hermes reloads/rewrites config.yaml), so writing multiple
# separate "auxiliary:" sections would silently drop earlier ones.
# Auxiliary calls are NON-streaming by default, but this gateway appends an SSE
# `data: [DONE]` marker to non-streaming bodies unless the request carries an
# explicit `stream` field — which would break the JSON parse in every aux task
# (vision, compression, session search, MCP helpers...). Declaring the main
# endpoint here makes Hermes stream and aggregate aux responses instead.
AUX_ENTRIES="  stream_only_base_urls:
    - ${HERMES_BASE_URL}
"
if [ -n "${HERMES_VISION_MODEL:-}" ]; then
    # Vision runs on the same provider/endpoint as the main model — only the
    # model id differs, so no separate provider var is needed.
    AUX_ENTRIES="${AUX_ENTRIES}  vision:
    provider: ${HERMES_PROVIDER}
    model: ${HERMES_VISION_MODEL}
"
    echo "Auxiliary vision model: ${HERMES_PROVIDER}/${HERMES_VISION_MODEL}"
fi

# Title generation is DISABLED by default (auto-titling would otherwise use a
# fast/cheap gateway model — instead of the main
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
# Custom gateway credentials. ROUTER9_BASE_URL is derived from HERMES_BASE_URL so
# the endpoint lives in one place; the image_gen/9router plugin reads both.
ROUTER9_BASE_URL=${HERMES_BASE_URL}
ROUTER9_API_KEY=${ROUTER9_API_KEY:-}
# Optional edit-capable model/combo for the image_gen/9router plugin. Use a
# dedicated combo whose members are all edit-capable, so the image model is
# changed on the gateway without touching this repo. Empty keeps the tool
# text-to-image only; see the plugin's capabilities() gate for why.
ROUTER9_IMAGE_EDIT_MODEL=${HERMES_IMAGE_EDIT_MODEL:-}
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
# --- MCP: mcp-obsidian / mcp-calendar ---
OBSIDIAN_VAULT_PATH=${OBSIDIAN_VAULT_PATH}
GOOGLE_CALENDAR_CLIENT_ID=${GOOGLE_CALENDAR_CLIENT_ID:-}
GOOGLE_CALENDAR_CLIENT_SECRET=${GOOGLE_CALENDAR_CLIENT_SECRET:-}
GOOGLE_CALENDAR_REFRESH_TOKEN=${GOOGLE_CALENDAR_REFRESH_TOKEN:-}
GOOGLE_CALENDAR_ID=${GOOGLE_CALENDAR_ID:-primary}
GOOGLE_CALENDAR_TIMEZONE=${GOOGLE_CALENDAR_TIMEZONE:-Asia/Ho_Chi_Minh}
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
