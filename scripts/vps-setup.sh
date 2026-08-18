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
    cat > .env << 'ENVFILE'
# === AI Model ===
HERMES_MODEL=mimo-v2.5
HERMES_PROVIDER=opencode-go
HERMES_BASE_URL=https://opencode.ai/zen/go/v1
HERMES_API_MODE=chat_completions
HERMES_TIMEZONE=Asia/Ho_Chi_Minh
MCP_HUB_REPO_URL=https://github.com/ndq1801/slave_mcps.git

# === Telegram ===
TELEGRAM_BOT_TOKEN=
TELEGRAM_ALLOWED_USERS=
TELEGRAM_HOME_CHANNEL=
TELEGRAM_HOME_CHANNEL_NAME=ErrandBoy

# === Database ===
POSTGRES_PASSWORD=CHANGE_ME
DATABASE_URL=postgresql://finlog_user:CHANGE_ME@postgres:5432/finlogbot_db

# === MCP: Daily Report ===
DAILY_REPORT_BASE_URL=https://daily-report.wpdevelop.online
DAILY_REPORT_USERNAME=
DAILY_REPORT_PASSWORD=
DAILY_REPORT_LOGIN_FIELD=email

# === Optional ===
BRAVE_SEARCH_API_KEY=
JINA_API_KEY=
OPENCODE_GO_API_KEY=
ENVFILE
    chmod 600 .env
    echo "Created .env — EDIT IT with your actual values!"
    echo "  nano $PROJECT_DIR/.env"
else
    echo ".env already exists, skipping."
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
