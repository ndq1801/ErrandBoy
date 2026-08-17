#!/bin/bash
# vps-setup.sh — Initial VPS setup for ErrandBoy
# Run this ONCE on the VPS before first deploy.
set -e

PROJECT_DIR="/srv/errandboy"

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

echo "=== Creating .env file ==="
if [ ! -f .env ]; then
    cat > .env << 'ENVFILE'
# === AI Model ===
HERMES_MODEL=deepseek-v4-flash
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
ENVFILE
    chmod 600 .env
    echo "Created .env — EDIT IT with your actual values!"
    echo "  nano $PROJECT_DIR/.env"
else
    echo ".env already exists, skipping."
fi

echo "=== Building and starting containers ==="
docker compose build
docker compose up -d

echo "=== Status ==="
docker compose ps

echo ""
echo "=== Setup complete! ==="
echo "Next steps:"
echo "  1. Edit .env: nano $PROJECT_DIR/.env"
echo "  2. Restart: cd $PROJECT_DIR && docker compose up -d"
echo "  3. Add GitHub Secrets for auto-deploy:"
echo "     - VPS_HOST = 180.93.136.13"
echo "     - VPS_USERNAME = root"
echo "     - VPS_SSH_KEY = (contents of ~/.ssh/id_rsa)"
