#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="/home/pi/eg-mqtt-starter"

# Dossiers
sudo mkdir -p /opt/eg /etc/eg

# --- Script first boot ---
sudo tee /opt/eg/firstboot.sh >/dev/null <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="/home/pi/eg-mqtt-starter"
STATE_DIR="/etc/eg"
PROVISION_FLAG="$STATE_DIR/provisioned"
LOG="/var/log/eg-firstboot.log"
exec > >(tee -a "$LOG") 2>&1

trap 'echo "[ERR] firstboot failed (see $LOG)"' ERR

require() { command -v "$1" >/dev/null 2>&1 || sudo apt-get install -y "$1"; }
say(){ echo "[firstboot] $*"; }

if [ -f "$PROVISION_FLAG" ]; then
  say "Already provisioned. Exiting."; exit 0
fi

sudo apt-get update -y
sudo apt-get install -y whiptail python3-venv mosquitto-clients

# Petit helper whiptail
menu() { whiptail --title "$1" --menu "$2" 20 70 10 "${@:3}" 3>&1 1>&2 2>&3; }
ask()  { whiptail --title "$1" --inputbox "$2" 12 70 "$3" 3>&1 1>&2 2>&3; }
yesno(){ whiptail --title "$1" --yesno "$2" 10 70; }

# 1) Choix rôle
ROLE=$(menu "EG First Boot" "Choisis le rôle de ce Raspberry Pi" \
  core "Ce Pi héberge le Core (Mosquitto + API)" \
  device "Ce Pi est un Device (slot/roulette/blackjack/change)")
[ -n "$ROLE" ] || { echo "No role chosen"; exit 1; }

if [ "$ROLE" = "core" ]; then
  # --- Installation Core (Docker) ---
  say "Install Docker"
  sudo apt-get install -y docker.io docker-compose-plugin
  sudo systemctl enable --now docker

  # Génère compose si absent
  if [ ! -f "$PROJECT_DIR/docker-compose.yml" ]; then
    say "Generating docker-compose.yml + core files"
    if [ -x "$PROJECT_DIR/scripts/setup-core-compose.sh" ]; then
      bash "$PROJECT_DIR/scripts/setup-core-compose.sh"
    else
      # fallback minimal
      mkdir -p "$PROJECT_DIR/core" "$PROJECT_DIR/mosquitto" "$PROJECT_DIR/data"
      cat > "$PROJECT_DIR/docker-compose.yml" <<'YML'
services:
  mosquitto:
    image: eclipse-mosquitto:2
    container_name: eg-mosquitto
    restart: unless-stopped
    ports: ["1883:1883","9001:9001"]
    volumes:
      - ./mosquitto/mosquitto.conf:/mosquitto/config/mosquitto.conf:ro
      - mosquitto_data:/mosquitto/data
      - mosquitto_log:/mosquitto/log
  core:
    build: ./core
    container_name: eg-core
    restart: unless-stopped
    environment:
      - BROKER_HOST=mosquitto
      - BROKER_PORT=1883
      - MQTT_NAMESPACE=eg
      - DB_PATH=/data/core.db
    depends_on: [mosquitto]
    ports: ["8000:8000"]
    volumes:
      - ./core:/app
      - ./data:/data
volumes:
  mosquitto_data:
  mosquitto_log:
YML
      cat > "$PROJECT_DIR/mosquitto/mosquitto.conf" <<'CFG'
listener 1883
protocol mqtt
listener 9001
protocol websockets
allow_anonymous true
persistence true
persistence_location /mosquitto/data/
CFG
      cat > "$PROJECT_DIR/core/Dockerfile" <<'DOCK'
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8000
CMD ["uvicorn","core:app","--host","0.0.0.0","--port","8000"]
DOCK
      cat > "$PROJECT_DIR/core/requirements.txt" <<'REQ'
fastapi
uvicorn[standard]
paho-mqtt
REQ
      # mini app si aucune n'existe
      if [ ! -f "$PROJECT_DIR/core/core.py" ]; then
        cat > "$PROJECT_DIR/core/core.py" <<'PY'
from fastapi import FastAPI
app = FastAPI()
@app.get("/")
def root(): return {"ok": True, "msg":"EG Core placeholder"}
PY
      fi
    fi
  fi

  say "Docker compose up"
  (cd "$PROJECT_DIR" && docker compose up -d --remove-orphans)

  # Service systemd pour maintenir le stack au boot
  sudo tee /etc/systemd/system/eg-core-stack.service >/dev/null <<'UNIT'
[Unit]
Description=EG Core Stack (Docker Compose)
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=/home/pi/eg-mqtt-starter
RemainAfterExit=yes
ExecStart=/usr/bin/docker compose up -d --remove-orphans
ExecStop=/usr/bin/docker compose down

[Install]
WantedBy=multi-user.target
UNIT
  sudo systemctl daemon-reload
  sudo systemctl enable --now eg-core-stack.service

  # Sauvegarde
  echo "role: core" | sudo tee "$PROVISION_FLAG" >/dev/null

else
  # --- Installation Device ---
  # Choix type
  KIND=$(menu "Type de device" "Sélectionne le device à installer" \
    slot "Machine à sous" \
    roulette "Roulette" \
    blackjack "Blackjack" \
    change "Change machine")
  [ -n "$KIND" ] || exit 1

  # Device ID (défaut basé sur type)
  DEF_ID="${KIND}-01"
  DEVICE_ID=$(ask "Device ID" "Nom du device (device_id)" "$DEF_ID")
  [ -n "$DEVICE_ID" ] || exit 1

  # IP du Core
  CORE_IP=$(ask "Core IP" "Adresse IP du Core (broker MQTT)" "192.168.1.27")
  [ -n "$CORE_IP" ] || exit 1

  # Option Kiosk ?
  KIOSK=0
  if yesno "Kiosk" "Activer un navigateur plein écran (kiosk) pour l'UI du device ?"; then KIOSK=1; fi

  # Env Python minimal
  say "Python venv + deps"
  python3 -m venv "$PROJECT_DIR/.venv"
  "$PROJECT_DIR/.venv/bin/pip" -q install -U pip
  if [ -f "$PROJECT_DIR/devices/requirements.txt" ]; then
    "$PROJECT_DIR/.venv/bin/pip" -q install -r "$PROJECT_DIR/devices/requirements.txt"
  else
    "$PROJECT_DIR/.venv/bin/pip" -q install paho-mqtt PyYAML
  fi

  # Persiste le device_id
  mkdir -p "$PROJECT_DIR/devices/$KIND/state"
  printf "device_id: %s\n" "$DEVICE_ID" > "$PROJECT_DIR/devices/$KIND/state/device_state.yaml"

  # Service agent
  sudo tee /etc/systemd/system/eg-agent@.service >/dev/null <<'UNIT'
[Unit]
Description=EG Device Agent (%i)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=pi
WorkingDirectory=/home/pi/eg-mqtt-starter
Environment=PYTHONUNBUFFERED=1
Environment=BROKER_HOST=%h  # placeholder (sera remplacé)
Environment=BROKER_PORT=1883
ExecStart=/bin/bash -lc 'source .venv/bin/activate && python -m devices.%i.agent'
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
  # Remplace %h par l'IP Core
  sudo sed -i "s|Environment=BROKER_HOST=%h|Environment=BROKER_HOST=$CORE_IP|" /etc/systemd/system/eg-agent@.service

  sudo systemctl daemon-reload
  sudo systemctl enable --now eg-agent@"$KIND"

  # Kiosk optionnel
  if [ "$KIOSK" -eq 1 ]; then
    say "Installing kiosk"
    sudo apt-get install -y chromium-browser xserver-xorg xinit
    sudo tee /etc/systemd/system/eg-kiosk@.service >/dev/null <<'UNIT'
[Unit]
Description=EG Kiosk (%i)
After=graphical.target eg-agent@%i.service
Wants=graphical.target

[Service]
User=pi
Environment=DISPLAY=:0
Environment=XDG_RUNTIME_DIR=/run/user/1000
ExecStart=/bin/bash -lc 'startx /usr/bin/chromium-browser --kiosk --noerrdialogs --disable-session-crashed-bubble --disable-infobars "http://%h:8000/web/react/%i/dist/index.html?device_id=%i-01"'
Restart=always
UNIT
    sudo sed -i "s|http://%h:8000|http://$CORE_IP:8000|" /etc/systemd/system/eg-kiosk@.service
    sudo systemctl daemon-reload
    sudo systemctl enable --now eg-kiosk@"$KIND"
  fi

  # Option: hostname = device_id
  if yesno "Hostname" "Définir le nom de machine sur '$DEVICE_ID' ?"; then
    sudo hostnamectl set-hostname "$DEVICE_ID"
    echo "127.0.1.1 $DEVICE_ID" | sudo tee -a /etc/hosts >/dev/null || true
  fi

  # SPI pour RFID ? (si tu utilises MFRC522)
  if yesno "RFID SPI" "Activer SPI pour lecteur RFID ?"; then
    sudo raspi-config nonint do_spi 0 || true
    sudo apt-get install -y python3-spidev python3-rpi.gpio python3-gpiozero
    "$PROJECT_DIR/.venv/bin/pip" -q install mfrc522
  fi

  # Sauvegarde
  {
    echo "role: device"
    echo "kind: $KIND"
    echo "device_id: $DEVICE_ID"
    echo "core_ip: $CORE_IP"
    echo "kiosk: $KIOSK"
  } | sudo tee "$PROVISION_FLAG" >/dev/null
fi

say "Provision OK. Rebooting…"
sudo systemctl disable eg-firstboot.service || true
sudo reboot
EOS
sudo chmod +x /opt/eg/firstboot.sh

# --- Service firstboot ---
sudo tee /etc/systemd/system/eg-firstboot.service >/dev/null <<'UNIT'
[Unit]
Description=EG First Boot Wizard
After=multi-user.target
ConditionPathExists=!/etc/eg/provisioned

[Service]
Type=idle
ExecStart=/opt/eg/firstboot.sh
StandardOutput=journal
StandardError=journal
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
Restart=no

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable eg-firstboot.service

echo "[ok] First-boot wizard installed. This Pi will ask on next boot."
