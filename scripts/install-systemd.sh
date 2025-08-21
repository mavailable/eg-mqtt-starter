
#!/usr/bin/env bash
set -euo pipefail
DEVICE_KIND="${1:-}"
PROJECT_DIR="${2:-}"
CORE_HOST="${3:-core-01}"
BROWSER="${4:-chromium-browser}"
if [[ -z "$DEVICE_KIND" || -z "$PROJECT_DIR" ]]; then
  echo "Usage: sudo scripts/install-systemd.sh <device-kind> <project-dir> [core-host] [browser]"
  echo "  device-kind: slot | roulette | blackjack | change"
  echo "  project-dir: absolute path to this project on the device (e.g., /home/pi/eg)"
  exit 1
fi
mkdir -p /etc/eg
cat >/etc/eg/eg.env <<EOF
EG_PROJECT_DIR=${PROJECT_DIR}
DEVICE_KIND=${DEVICE_KIND}
CORE_HOST=${CORE_HOST}
BROWSER=${BROWSER}
EOF
cp systemd/eg-agent.service /etc/systemd/system/eg-agent.service
cp systemd/eg-kiosk.service /etc/systemd/system/eg-kiosk.service
systemctl daemon-reload
systemctl enable eg-agent.service eg-kiosk.service
systemctl restart eg-agent.service eg-kiosk.service
echo "Installed. Env in /etc/eg/eg.env"
