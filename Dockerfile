# ErrandBoy — Hermes Agent personal Telegram assistant (Railway)
# Strategy: validated install.sh + tini approach (official Nous user story),
# MCP servers pre-installed at build time to avoid cold-start downloads.

FROM python:3.13-slim

# Runtime tooling: git (mcp-hub clone), node (MCP servers), tini (zombie
# reaping for MCP subprocesses), tzdata (Python zoneinfo in finlog).
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl bash git nodejs npm build-essential tini tzdata \
    && rm -rf /var/lib/apt/lists/*

# Install Hermes Agent (official installer, non-interactive).
# Pin a commit for reproducibility: ARG HERMES_COMMIT=<sha>
ARG HERMES_COMMIT=main
RUN curl -fsSL "https://raw.githubusercontent.com/NousResearch/hermes-agent/${HERMES_COMMIT}/scripts/install.sh" \
        | bash -s -- --skip-setup
ENV PATH="/root/.local/bin:/root/.hermes/hermes-agent/venv/bin:${PATH}"

# Smoke test: the binary must resolve inside the image.
RUN hermes --version

# MCP hub servers (pre-installed so the gateway never downloads at runtime).
ARG MCP_HUB_REPO=https://github.com/ndq1801/slave_mcps.git
RUN git clone --depth 1 "${MCP_HUB_REPO}" /app/mcp-hub \
    && (cd /app/mcp-hub/mcp-daily-report && npm install --omit=dev) \
    && pip install --no-cache-dir --break-system-packages -r /app/mcp-hub/mcp-finlog/requirements.txt

WORKDIR /app
COPY . .

# CRLF safety + exec bit (files checked out on Windows).
RUN sed -i 's/\r$//' /app/entrypoint.sh && chmod +x /app/entrypoint.sh

# No CMD here on purpose: railway.json must NOT set startCommand either
# (it would override ENTRYPOINT and bypass tini).
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/app/entrypoint.sh"]
