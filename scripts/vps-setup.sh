#!/bin/bash
# vps-setup.sh — Initial VPS setup for ErrandBoy
# Run this ONCE on the VPS before first deploy.
# This script installs dependencies on the VPS host (outside Docker),
# then clones the repo and starts the containers.
set -e

PROJECT_DIR="/srv/errandboy"

# ============================================================================
# 1. INSTALL DEPENDENCIES ON VPS HOST
# ============================================================================
echo "=== Installing dependencies on VPS host ==="

# Update package list
echo "--- Updating package list ---"
apt-get update -qq

# --- Git ---
if command -v git &> /dev/null; then
    echo "Git already installed: $(git --version)"
else
    echo "--- Installing Git ---"
    apt-get install -y -qq git
    echo "Git installed: $(git --version)"
fi

# --- Docker ---
if command -v docker &> /dev/null; then
    echo "Docker already installed: $(docker --version)"
else
    echo "--- Installing Docker ---"
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
    echo "Docker installed: $(docker --version)"
fi

# --- Docker Compose ---
if docker compose version &> /dev/null; then
    echo "Docker Compose already installed: $(docker compose version)"
else
    echo "--- Installing Docker Compose ---"
    # Docker Compose is included in Docker plugin since Docker 20+.
    # If not present, install manually.
    apt-get install -y -qq docker-compose-plugin
    echo "Docker Compose installed: $(docker compose version)"
fi

# --- rclone (for OneDrive backups) ---
if command -v rclone &> /dev/null; then
    echo "rclone already installed: $(rclone version | head -1)"
else
    echo "--- Installing rclone ---"
    # rclone install script needs unzip
    if ! command -v unzip &> /dev/null; then
        echo "--- Installing unzip (required by rclone installer) ---"
        apt-get install -y -qq unzip
    fi
    curl -fsSL https://rclone.org/install.sh | bash
    echo "rclone installed: $(rclone version | head -1)"
    echo "NOTE: Run 'rclone config' to set up OneDrive authentication."
fi

echo "=== Dependencies installed ==="

# ============================================================================
# 2. CREATE PROJECT STRUCTURE AND CLONE REPO
# ============================================================================
echo "=== Creating project structure ==="
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

echo "=== Cloning ErrandBoy ==="
if [ -d ".git" ]; then
    echo "Already cloned, pulling latest..."
    git pull origin main
else
    git clone https://github.com/ndq1801/ErrandBoy.git .
fi

# ============================================================================
# 3. CREATE .ENV FILE (first time only)
# ============================================================================
echo "=== Creating .env file ==="
if [ ! -f .env ]; then
    # .env.example is the single source of truth for the env contract — never
    # duplicate the template here. A second inline copy once drifted and shipped
    # the PUBLIC 9router URL, which Cloudflare answers with HTTP 403 (error 1010
    # on the OpenAI SDK's User-Agent), plus it was missing the vars docker-compose
    # interpolates into the volume mount targets.
    cp .env.example .env
    chmod 600 .env
    echo "Created .env from .env.example — EDIT IT with your actual values!"
    echo "  Required: ROUTER9_API_KEY, TELEGRAM_BOT_TOKEN, TELEGRAM_HOME_CHANNEL, POSTGRES_PASSWORD"
    echo "  nano $PROJECT_DIR/.env"
else
    echo ".env already exists, skipping."
fi

# The gateway is reached container-to-container over 9router's own network, and
# docker-compose declares that network as external — so it must exist before
# `docker compose up`, otherwise the deploy aborts with "network 9router_default
# declared as external, but could not be found".
if ! docker network inspect 9router_default >/dev/null 2>&1; then
    echo "ERROR: docker network '9router_default' not found." >&2
    echo "       Start the 9router stack first (its compose file lives in /srv/9router)," >&2
    echo "       then re-run this script." >&2
    exit 1
fi

# ============================================================================
# 4. BUILD AND START CONTAINERS
# ============================================================================
echo "=== Building and starting containers ==="
docker compose build
docker compose up -d

echo "=== Status ==="
docker compose ps

# ============================================================================
# 5. POST-SETUP INSTRUCTIONS
# ============================================================================
echo ""
echo "=== Setup complete! ==="
echo "Next steps:"
echo "  1. Edit .env: nano $PROJECT_DIR/.env"
echo "  2. Restart: cd $PROJECT_DIR && docker compose up -d"
echo "  3. Configure rclone for OneDrive backups:"
echo "     rclone config"
echo "     (follow the interactive setup)"
echo "  4. Add GitHub Secrets for auto-deploy:"
echo "     - VPS_HOST = <your-vps-ip>"
echo "     - VPS_USERNAME = root"
echo "     - VPS_SSH_KEY = (contents of ~/.ssh/id_rsa)"
echo ""
echo "Installed components on VPS host:"
echo "  - $(docker --version)"
echo "  - $(docker compose version)"
echo "  - $(rclone version | head -1)"
echo "  - $(git --version)"
