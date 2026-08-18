# ErrandBoy — Hermes Agent personal Telegram assistant (Docker Compose on VPS)
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
# PINNED to 07ee4a2e — Hermes main at 2026-08-12T08:16Z, the exact state of the
# last known-good deployment. Later main commits (08-12 16:25Z..08-13 02:43Z:
# plugin system overhaul, PTB 22.6->22.8 bump) broke Telegram connect with
# "Any cannot be instantiated". --commit + --force-commit make install.sh
# fetch this exact SHA (it is behind main, so the rollback guard needs
# --force-commit). Unpin back to `main` once upstream ships a working
# telegram adapter again — and re-test the control-model config first.
ARG HERMES_COMMIT=07ee4a2ec8d3a678248d5e0bdc148a457c782d8d
# Bump this value to force re-running install.sh (invalidates stale layer cache
# layer cache where the hermes binary was missing).
ARG CACHE_BUSTER=20260818
RUN curl -fsSL "https://raw.githubusercontent.com/NousResearch/hermes-agent/${HERMES_COMMIT}/scripts/install.sh" \
        | bash -s -- --skip-setup --commit "${HERMES_COMMIT}" --force-commit
ENV PATH="/root/.local/bin:/root/.hermes/hermes-agent/venv/bin:${PATH}"

# Smoke test: the binary must resolve inside the image.
RUN hermes --version

WORKDIR /app
COPY . .

# CRLF safety + exec bit (files checked out on Windows).
RUN sed -i 's/\r$//' /app/entrypoint.sh && chmod +x /app/entrypoint.sh

# No CMD here on purpose: docker-compose must NOT set command either
# (it would override ENTRYPOINT and bypass tini).
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/app/entrypoint.sh"]
