#!/bin/bash
# StickerLab – cobalt server on AWS EC2 (Ubuntu 24.04).
# Paste this whole file into "Advanced details → User data" when launching the instance.
# It installs Docker, creates an API key, gets an HTTPS certificate and starts cobalt.
#
# Optional: set your own domain (its DNS A record must point to the instance IP).
# Leave empty to use a free automatic domain like 3-120-45-67.sslip.io
COBALT_DOMAIN=""

set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y curl uuid-runtime ca-certificates
curl -fsSL https://get.docker.com | sh

mkdir -p /opt/cobalt
cd /opt/cobalt
REPO_RAW="https://raw.githubusercontent.com/VirSukh/StickerLab/main/server"
curl -fsSL "$REPO_RAW/docker-compose.yml" -o docker-compose.yml
curl -fsSL "$REPO_RAW/Caddyfile" -o Caddyfile
curl -fsSL "$REPO_RAW/reconfigure.sh" -o reconfigure.sh
chmod +x reconfigure.sh

# API key (UUIDv4) with no rate limit, used only by your app.
KEY=$(uuidgen -r | tr 'A-Z' 'a-z')
cat > keys.json <<EOF
{
  "$KEY": { "name": "StickerLab", "limit": "unlimited" }
}
EOF
chmod 644 keys.json

# Daily update: cobalt changes often to keep up with the sites it supports.
cat > /etc/cron.daily/cobalt-update <<'EOF'
#!/bin/bash
cd /opt/cobalt && docker compose pull -q && docker compose up -d && docker image prune -f
EOF
chmod +x /etc/cron.daily/cobalt-update

./reconfigure.sh "$COBALT_DOMAIN"
