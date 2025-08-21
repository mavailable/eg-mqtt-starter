
# EG MQTT + GPIO + React + Provision + systemd
Généré le 2025-08-20T19:39:50Z

## Core
docker compose up --build

## Devices
pip install -r devices/requirements.txt
python -m devices.slot.agent
python -m devices.roulette.agent
python -m devices.blackjack.agent
python -m devices.change.agent

## systemd install
sudo scripts/install-systemd.sh slot /home/pi/eg core-01 chromium-browser
# eg-mqtt-starter
