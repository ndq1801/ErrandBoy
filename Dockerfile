# ErrandBoy — Hermes Agent personal Telegram assistant (Railway)
# Strategy: validated install.sh + tini approach (official Nous user story).
# The MCP hub (slave_mcps) is NOT baked in: entrypoint.sh clones/pulls it at
# runtime from $MCP_HUB_REPO_URL (env-driven, same pattern as assistant-bot)
# and installs its node/pip deps on every boot.

FROM python:3.13-slim

# Runtime tooling: git (mcp-hub clone), node (MCP servers), tini (zombie
# reaping for MCP subprocesses), tzdata (Python zoneinfo in finlog).
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl bash git nodejs npm build-essential tini tzdata \
    && rm -rf /var/lib/apt/lists/*

# Install Hermes Agent (official installer, non-interactive).
# PINNED: 97c06dc is main right before the 2026-08-13 "bump PTB 22.6 -> 22.8"
# commit (91345435a1), which broke the Telegram adapter ("Any cannot be
# instantiated") and was never tested upstream. --commit + --force-commit make
# install.sh fetch this exact SHA and check it out (it is behind main, so the
# rollback guard needs --force-commit). Unpin back to `main` once upstream
# ships a working adapter with PTB 22.8.
ARG HERMES_COMMIT=97c06dcfd7caa3e96c42f0ad36c52b1c36c38efe
RUN curl -fsSL "https://raw.githubusercontent.com/NousResearch/hermes-agent/${HERMES_COMMIT}/scripts/install.sh" \
        | bash -s -- --skip-setup --commit "${HERMES_COMMIT}" --force-commit
ENV PATH="/root/.local/bin:/root/.hermes/hermes-agent/venv/bin:${PATH}"

# Smoke test: the binary must resolve inside the image.
RUN hermes --version

WORKDIR /app
COPY . .

# CRLF safety + exec bit (files checked out on Windows).
RUN sed -i 's/\r$//' /app/entrypoint.sh && chmod +x /app/entrypoint.sh

# No CMD here on purpose: railway.json must NOT set startCommand either
# (it would override ENTRYPOINT and bypass tini).
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/app/entrypoint.sh"]
