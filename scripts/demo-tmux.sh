#!/usr/bin/env bash
set -euo pipefail

SESSION="egdemo"
PROJECT_DIR="$HOME/eg-mqtt-starter"

# venv minimal
if [ ! -d "$PROJECT_DIR/.venv" ]; then
  python3 -m venv "$PROJECT_DIR/.venv"
  "$PROJECT_DIR/.venv/bin/pip" install -U pip
  if [ -f "$PROJECT_DIR/devices/requirements.txt" ]; then
    "$PROJECT_DIR/.venv/bin/pip" install -r "$PROJECT_DIR/devices/requirements.txt"
  else
    "$PROJECT_DIR/.venv/bin/pip" install paho-mqtt PyYAML
  fi
fi

tmux kill-session -t "$SESSION" 2>/dev/null || true

tmux new-session -d -s "$SESSION" -n demo \
  "bash -lc 'cd \"$PROJECT_DIR\" && docker compose up -d && docker logs -f eg-core'"

tmux split-window -h -t "$SESSION":0 \
  "bash -lc 'cd \"$PROJECT_DIR\" && source .venv/bin/activate && stdbuf -oL -eL python -X dev -m devices.change.agent 2>&1 | sed -u \"s/^/[change] /\"'"

tmux split-window -v -t "$SESSION":0.0 \
  "bash -lc 'cd \"$PROJECT_DIR\" && source .venv/bin/activate && stdbuf -oL -eL python -X dev -m devices.roulette.agent 2>&1 | sed -u \"s/^/[roulette] /\"'"

tmux split-window -v -t "$SESSION":0.1 \
  "bash -lc 'cd \"$PROJECT_DIR\" && source .venv/bin/activate && stdbuf -oL -eL python -X dev -m devices.slot.agent 2>&1 | sed -u \"s/^/[slot] /\"'"

tmux select-layout -t "$SESSION":0 tiled
tmux new-window -t "$SESSION" -n mqtt \
  "bash -lc 'mosquitto_sub -h 127.0.0.1 -t \"eg/#\" -v'"
tmux attach -t "$SESSION"
