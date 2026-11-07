#!/bin/bash
# Re-detects the public IP (e.g. after attaching an Elastic IP), updates the domain and restarts.
# Usage: sudo /opt/cobalt/reconfigure.sh [your-domain.com]
set -euo pipefail
cd /opt/cobalt

DOMAIN="${1:-}"
if [ -z "$DOMAIN" ]; then
  TOKEN=$(curl -sX PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
  IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4)
  DOMAIN="$(echo "$IP" | tr '.' '-').sslip.io"
fi

echo "COBALT_DOMAIN=$DOMAIN" > .env
docker compose up -d --force-recreate

KEY=$(grep -oE '"[0-9a-f-]{36}"' keys.json | head -1 | tr -d '"')
cat > CREDENTIALS.txt <<EOF
=== StickerLab / cobalt ===
URL server: https://$DOMAIN/
API key:    $KEY
(Inseriscili in StickerLab → Impostazioni → Server cobalt)
EOF
cat CREDENTIALS.txt
# Also visible in EC2 console → Actions → Monitor → Get system log.
cat CREDENTIALS.txt > /dev/console || true
