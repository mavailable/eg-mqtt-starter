
#!/usr/bin/env bash
set -euo pipefail
: "${EG_PROJECT_DIR:?EG_PROJECT_DIR not set}"
: "${DEVICE_KIND:?DEVICE_KIND not set}"
CORE_HOST="${CORE_HOST:-core-01}"
CORE_PORT="${CORE_PORT:-8000}"
BROWSER="${BROWSER:-chromium-browser}"
if ! command -v "$BROWSER" >/dev/null 2>&1; then
  if command -v chromium >/dev/null 2>&1; then BROWSER=chromium; else echo "No chromium installed"; exit 1; fi
fi
STATE_FILE="$EG_PROJECT_DIR/devices/$DEVICE_KIND/state/device_state.yaml"
DEVICE_ID="${DEVICE_KIND}-01"
if [ -f "$STATE_FILE" ]; then
  DID_LINE=$(grep -E '^device_id:' "$STATE_FILE" | awk '{print $2}')
  if [ -n "${DID_LINE:-}" ]; then DEVICE_ID="$DID_LINE"; fi
fi
BASE_URL="http://${CORE_HOST}:${CORE_PORT}/web/react"
case "$DEVICE_KIND" in
  slot)      URL="$BASE_URL/slot/dist/index.html?device_id=$DEVICE_ID" ;;
  change)    URL="$BASE_URL/change/dist/index.html" ;;
  roulette)  URL="$BASE_URL/roulette/dist/index.html?device_id=$DEVICE_ID" ;;
  blackjack) URL="$BASE_URL/blackjack/dist/index.html?device_id=$DEVICE_ID" ;;
  *)         URL="$BASE_URL/slot/dist/index.html?device_id=$DEVICE_ID" ;;
esac
exec "$BROWSER" --kiosk --noerrdialogs --disable-infobars --disable-session-crashed-bubble --autoplay-policy=no-user-gesture-required "$URL"
