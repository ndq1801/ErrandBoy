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
# PINNED to v0.21.2 (tag v2026.9.11) — the newest official release at the time
# the bot was moved onto the self-hosted 9router gateway (a custom
# OpenAI-compatible endpoint). v0.21.1+ also sends the session header natively
# (upstream PR #101864), so the old in-container `default_headers` workaround is
# no longer needed. Pinned to a release TAG (not main HEAD) so the deployed
# build stays reproducible; bump deliberately after testing. NOTE: 08-12/08-13
# commits once broke Telegram connect with "Any cannot be instantiated" — always
# re-test the gateway after a pin bump.
# NOTE: this must be the tag's COMMIT sha, not the annotated tag-object sha.
# The GitHub refs API returns the tag OBJECT for an annotated tag, and
# raw.githubusercontent.com 404s on it (this broke the 2026-09-14 deploy:
# curl (22) 404 -> install.sh never ran -> the `hermes --version` smoke test
# failed with exit 127). Dereference before pinning:
#   gh api repos/NousResearch/hermes-agent/git/ref/tags/v2026.9.11   (object.sha = tag object)
#   gh api <that object url>                                          (object.sha = commit)
# --commit + --force-commit make install.sh fetch this exact SHA (it is behind
# main, so the rollback guard needs --force-commit).
# Cache-free by design: deploy.yml prunes the builder cache and builds with
# --no-cache, so this layer re-downloads and re-installs hermes on every deploy
# (a stale cached layer once shipped an image without the hermes binary). That
# is also why no cache-buster ARG is needed anymore.
ARG HERMES_COMMIT=939e45c91d751fadd94dcd1b873ac3cb44846213
RUN curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors \
        "https://raw.githubusercontent.com/NousResearch/hermes-agent/${HERMES_COMMIT}/scripts/install.sh" \
        -o /tmp/hermes-install.sh \
    && bash /tmp/hermes-install.sh --skip-setup --commit "${HERMES_COMMIT}" --force-commit \
    && rm -f /tmp/hermes-install.sh
ENV PATH="/root/.local/bin:/root/.hermes/hermes-agent/venv/bin:${PATH}"

# Smoke test: the binary must resolve inside the image.
RUN hermes --version

# GitHub CLI — baked into the image (NOT runtime-installed into the container
# writable layer): a plain binary install under /root would be lost on every
# --force-recreate. Pinned release tarball from official cli/cli. Auth state
# (hosts.yml) lives in the gh_config_data volume via ~/.config/gh, not here.
ARG GH_VERSION=2.98.0
RUN curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
        -o /tmp/gh.tar.gz \
    && tar -xzf /tmp/gh.tar.gz -C /tmp \
    && cp /tmp/gh_${GH_VERSION}_linux_amd64/bin/gh /usr/local/bin/gh \
    && rm -rf /tmp/gh.tar.gz /tmp/gh_${GH_VERSION}_linux_amd64 \
    && gh --version | head -1
# Clear the (empty at build-time) npm cache so nothing baked into the image
# layer persists; runtime caches under /root reset on every --force-recreate.
RUN npm cache clean --force 2>/dev/null || true

WORKDIR /app
COPY . .

# CRLF safety + exec bit (files checked out on Windows).
RUN sed -i 's/\r$//' /app/entrypoint.sh && chmod +x /app/entrypoint.sh

# No CMD here on purpose: docker-compose must NOT set command either
# (it would override ENTRYPOINT and bypass tini).
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/app/entrypoint.sh"]
