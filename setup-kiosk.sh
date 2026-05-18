#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SETUP_CONFIG_FILE="$SCRIPT_DIR/kiosk-config.env"

APP_DIR="/opt/dual-kiosk-display"
CONFIG_DIR="/etc/dual-kiosk-display"
CONFIG_FILE="$CONFIG_DIR/config.json"

USER_NAME="${SUDO_USER:-$(whoami)}"

if [ "$USER_NAME" = "root" ]; then
  echo "❌ Bitte nicht direkt als root ausführen. Nutze deinen normalen User."
  exit 1
fi

if [ ! -f "$SETUP_CONFIG_FILE" ]; then
  echo "❌ Config fehlt: $SETUP_CONFIG_FILE"
  echo "➡️ Lege kiosk-config.env neben setup-kiosk.sh an."
  exit 1
fi

# shellcheck disable=SC1090
source "$SETUP_CONFIG_FILE"

CURRENT_HOSTNAME="$(hostname)"
DEFAULT_SCREEN1_URL="https://example.com"
DEFAULT_SCREEN2_URL="https://example.org"

resolve_config_value() {
  local value="${1:-}"
  local placeholder="${2:-}"
  local fallback="${3:-}"

  if [ -z "$value" ] || [ "$value" = "$placeholder" ]; then
    printf '%s\n' "$fallback"
    return
  fi

  printf '%s\n' "$value"
}

KIOSK_HOSTNAME="$(resolve_config_value "${KIOSK_HOSTNAME:-}" "<HOSTNAME>" "$CURRENT_HOSTNAME")"
SCREEN1_URL="$(resolve_config_value "${SCREEN1_URL:-}" "<https://example.com>" "$DEFAULT_SCREEN1_URL")"
SCREEN2_URL="$(resolve_config_value "${SCREEN2_URL:-}" "<https://example.org>" "$DEFAULT_SCREEN2_URL")"
WIFI_SSID="$(resolve_config_value "${WIFI_SSID:-}" "<SSID>" "")"
WIFI_PASSWORD="$(resolve_config_value "${WIFI_PASSWORD:-}" "<PASSWORD>" "")"
WIFI_HIDDEN="${WIFI_HIDDEN:-false}"

SCREEN1_DISPLAY="${SCREEN1_DISPLAY:-:0}"
SCREEN2_DISPLAY="${SCREEN2_DISPLAY:-:0}"
SCREEN1_WINDOW_POSITION="${SCREEN1_WINDOW_POSITION:-0,0}"
SCREEN2_WINDOW_POSITION="${SCREEN2_WINDOW_POSITION:-1920,0}"
SCREEN1_WINDOW_SIZE="${SCREEN1_WINDOW_SIZE:-1920,1080}"
SCREEN2_WINDOW_SIZE="${SCREEN2_WINDOW_SIZE:-1920,1080}"
SCREEN1_OUTPUT="${SCREEN1_OUTPUT:-}"
SCREEN2_OUTPUT="${SCREEN2_OUTPUT:-}"
SCREEN1_MODE="${SCREEN1_MODE:-}"
SCREEN2_MODE="${SCREEN2_MODE:-}"
DISPLAY_LAYOUT_WAIT_SECONDS="${DISPLAY_LAYOUT_WAIT_SECONDS:-30}"
DISPLAY_LAYOUT_RETRY_INTERVAL="${DISPLAY_LAYOUT_RETRY_INTERVAL:-2}"
DISPLAY_LAYOUT_FALLBACK_TO_WINDOW_POSITION="${DISPLAY_LAYOUT_FALLBACK_TO_WINDOW_POSITION:-true}"

IFS=',' read -r SCREEN1_POS_X SCREEN1_POS_Y <<< "$SCREEN1_WINDOW_POSITION"
IFS=',' read -r SCREEN2_POS_X SCREEN2_POS_Y <<< "$SCREEN2_WINDOW_POSITION"
IFS=',' read -r SCREEN1_WIDTH SCREEN1_HEIGHT <<< "$SCREEN1_WINDOW_SIZE"
IFS=',' read -r SCREEN2_WIDTH SCREEN2_HEIGHT <<< "$SCREEN2_WINDOW_SIZE"

echo "== Hostname =="
if [ "$(hostname)" != "$KIOSK_HOSTNAME" ]; then
  sudo hostnamectl set-hostname "$KIOSK_HOSTNAME"
  echo "✅ Hostname gesetzt: $KIOSK_HOSTNAME"
else
  echo "ℹ️ Hostname bereits gesetzt: $KIOSK_HOSTNAME"
fi

echo "== Chromium Paket erkennen =="
if apt-cache show chromium >/dev/null 2>&1; then
  CHROMIUM_PACKAGE="chromium"
  CHROMIUM_CMD="chromium"
elif apt-cache show chromium-browser >/dev/null 2>&1; then
  CHROMIUM_PACKAGE="chromium-browser"
  CHROMIUM_CMD="chromium-browser"
else
  echo "❌ Kein Chromium-Paket gefunden"
  exit 1
fi

echo "✅ Chromium Paket: $CHROMIUM_PACKAGE"
echo "✅ Chromium Command: $CHROMIUM_CMD"

echo "== Installiere Pakete =="
sudo apt update
sudo apt install -y \
  "$CHROMIUM_PACKAGE" \
  unclutter \
  x11-xserver-utils \
  network-manager \
  jq

echo "== Verzeichnisse =="
sudo mkdir -p "$APP_DIR" "$CONFIG_DIR"

echo "== Kiosk Config =="
sudo tee "$CONFIG_FILE" >/dev/null <<EOF
{
  "screen1": {
    "url": "$SCREEN1_URL",
    "display": "$SCREEN1_DISPLAY",
    "output": "$SCREEN1_OUTPUT",
    "mode": "$SCREEN1_MODE",
    "windowPosition": "$SCREEN1_WINDOW_POSITION",
    "windowSize": "$SCREEN1_WINDOW_SIZE",
    "profileDir": "/home/$USER_NAME/.config/dual-kiosk-display/screen1"
  },
  "screen2": {
    "url": "$SCREEN2_URL",
    "display": "$SCREEN2_DISPLAY",
    "output": "$SCREEN2_OUTPUT",
    "mode": "$SCREEN2_MODE",
    "windowPosition": "$SCREEN2_WINDOW_POSITION",
    "windowSize": "$SCREEN2_WINDOW_SIZE",
    "profileDir": "/home/$USER_NAME/.config/dual-kiosk-display/screen2"
  },
  "displayLayout": {
    "waitSeconds": $DISPLAY_LAYOUT_WAIT_SECONDS,
    "retryIntervalSeconds": $DISPLAY_LAYOUT_RETRY_INTERVAL,
    "fallbackToWindowPosition": $DISPLAY_LAYOUT_FALLBACK_TO_WINDOW_POSITION
  },
  "chromiumCommand": "$CHROMIUM_CMD"
}
EOF

echo "== WLAN konfigurieren =="
if [ -n "$WIFI_SSID" ]; then
  if [ -n "$WIFI_PASSWORD" ]; then
    sudo nmcli dev wifi connect "$WIFI_SSID" password "$WIFI_PASSWORD" || true
  else
    sudo nmcli dev wifi connect "$WIFI_SSID" || true
  fi

  if [ "$WIFI_HIDDEN" = "true" ]; then
    sudo nmcli connection modify "$WIFI_SSID" 802-11-wireless.hidden yes || true
  fi
else
  echo "ℹ️ Kein WLAN in kiosk-config.env definiert"
fi

echo "== kiosk-display-layout.sh =="
sudo tee "$APP_DIR/kiosk-display-layout.sh" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/dual-kiosk-display/config.json"
GEOMETRY_DIR="/run/dual-kiosk-display"
GEOMETRY_FILE="$GEOMETRY_DIR/geometry.env"
LOCK_FILE="$GEOMETRY_DIR/layout.lock"

mkdir -p "$GEOMETRY_DIR"

if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK_FILE"
  flock -x 9
fi

SCREEN1_OUTPUT="$(jq -r '.screen1.output // ""' "$CONFIG_FILE")"
SCREEN2_OUTPUT="$(jq -r '.screen2.output // ""' "$CONFIG_FILE")"
SCREEN1_MODE="$(jq -r '.screen1.mode // ""' "$CONFIG_FILE")"
SCREEN2_MODE="$(jq -r '.screen2.mode // ""' "$CONFIG_FILE")"
SCREEN1_WINDOW_POSITION="$(jq -r '.screen1.windowPosition // "0,0"' "$CONFIG_FILE")"
SCREEN2_WINDOW_POSITION="$(jq -r '.screen2.windowPosition // "1920,0"' "$CONFIG_FILE")"
SCREEN1_WINDOW_SIZE="$(jq -r '.screen1.windowSize // "1920,1080"' "$CONFIG_FILE")"
SCREEN2_WINDOW_SIZE="$(jq -r '.screen2.windowSize // "1920,1080"' "$CONFIG_FILE")"
DISPLAY_NAME="$(jq -r '.screen1.display // ":0"' "$CONFIG_FILE")"
WAIT_SECONDS="$(jq -r '.displayLayout.waitSeconds // 30' "$CONFIG_FILE")"
RETRY_SECONDS="$(jq -r '.displayLayout.retryIntervalSeconds // 2' "$CONFIG_FILE")"
FALLBACK_TO_WINDOW="$(jq -r '.displayLayout.fallbackToWindowPosition // true' "$CONFIG_FILE")"

IFS=',' read -r SCREEN1_FALLBACK_POS_X SCREEN1_FALLBACK_POS_Y <<< "$SCREEN1_WINDOW_POSITION"
IFS=',' read -r SCREEN2_FALLBACK_POS_X SCREEN2_FALLBACK_POS_Y <<< "$SCREEN2_WINDOW_POSITION"
IFS=',' read -r SCREEN1_FALLBACK_WIDTH SCREEN1_FALLBACK_HEIGHT <<< "$SCREEN1_WINDOW_SIZE"
IFS=',' read -r SCREEN2_FALLBACK_WIDTH SCREEN2_FALLBACK_HEIGHT <<< "$SCREEN2_WINDOW_SIZE"

export DISPLAY="$DISPLAY_NAME"

if [ -z "${XAUTHORITY:-}" ] && [ -n "${HOME:-}" ] && [ -f "$HOME/.Xauthority" ]; then
  export XAUTHORITY="$HOME/.Xauthority"
fi

write_geometry_from_fallback() {
  cat > "$GEOMETRY_FILE" <<GEOM
SCREEN1_POS_X=$SCREEN1_FALLBACK_POS_X
SCREEN1_POS_Y=$SCREEN1_FALLBACK_POS_Y
SCREEN1_WIDTH=$SCREEN1_FALLBACK_WIDTH
SCREEN1_HEIGHT=$SCREEN1_FALLBACK_HEIGHT
SCREEN2_POS_X=$SCREEN2_FALLBACK_POS_X
SCREEN2_POS_Y=$SCREEN2_FALLBACK_POS_Y
SCREEN2_WIDTH=$SCREEN2_FALLBACK_WIDTH
SCREEN2_HEIGHT=$SCREEN2_FALLBACK_HEIGHT
GEOM
}

extract_geometry_token() {
  local output_name="$1"
  xrandr --query | awk -v output="$output_name" '
    $1 == output && $2 == "connected" {
      for (i = 3; i <= NF; i++) {
        if ($i ~ /^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+$/) {
          print $i
          exit
        }
      }
    }
  '
}

parse_geometry_token() {
  local token="$1"
  local prefix="${2:-}"
  if [[ "$token" =~ ^([0-9]+)x([0-9]+)\+([0-9]+)\+([0-9]+)$ ]]; then
    printf '%sWIDTH=%s\n' "$prefix" "${BASH_REMATCH[1]}"
    printf '%sHEIGHT=%s\n' "$prefix" "${BASH_REMATCH[2]}"
    printf '%sPOS_X=%s\n' "$prefix" "${BASH_REMATCH[3]}"
    printf '%sPOS_Y=%s\n' "$prefix" "${BASH_REMATCH[4]}"
    return 0
  fi
  return 1
}

wait_for_xrandr() {
  local start_ts now_ts
  start_ts="$(date +%s)"
  while true; do
    now_ts="$(date +%s)"
    if [ $((now_ts - start_ts)) -ge "$WAIT_SECONDS" ]; then
      break
    fi
    if xrandr --query >/dev/null 2>&1; then
      return 0
    fi
    sleep "$RETRY_SECONDS"
  done
  return 1
}

ensure_output_connected() {
  local output_name="$1"
  xrandr --query | awk -v output="$output_name" '$1 == output && $2 == "connected" { found = 1 } END { exit(found ? 0 : 1) }'
}

use_fallback_or_fail() {
  local reason="$1"
  if [ "$FALLBACK_TO_WINDOW" = "true" ]; then
    echo "⚠️ $reason - nutze windowPosition/windowSize fallback"
    write_geometry_from_fallback
    return 0
  fi
  echo "❌ $reason"
  return 1
}

if [ -z "$SCREEN1_OUTPUT" ] || [ -z "$SCREEN2_OUTPUT" ]; then
  write_geometry_from_fallback
  exit 0
fi

if ! wait_for_xrandr; then
  use_fallback_or_fail "xrandr/X-Display nicht rechtzeitig verfügbar"
  exit $?
fi

if ! ensure_output_connected "$SCREEN1_OUTPUT"; then
  use_fallback_or_fail "Output für Screen 1 nicht verbunden: $SCREEN1_OUTPUT"
  exit $?
fi

if ! ensure_output_connected "$SCREEN2_OUTPUT"; then
  use_fallback_or_fail "Output für Screen 2 nicht verbunden: $SCREEN2_OUTPUT"
  exit $?
fi

xrandr_cmd=(xrandr --output "$SCREEN1_OUTPUT" --auto)
if [ -n "$SCREEN1_MODE" ]; then
  xrandr_cmd+=(--mode "$SCREEN1_MODE")
fi
xrandr_cmd+=(--pos 0x0 --primary --output "$SCREEN2_OUTPUT" --auto)
if [ -n "$SCREEN2_MODE" ]; then
  xrandr_cmd+=(--mode "$SCREEN2_MODE")
fi
xrandr_cmd+=(--right-of "$SCREEN1_OUTPUT")

if ! "${xrandr_cmd[@]}"; then
  use_fallback_or_fail "xrandr Layout konnte nicht gesetzt werden"
  exit $?
fi

SCREEN1_GEOMETRY="$(extract_geometry_token "$SCREEN1_OUTPUT")"
SCREEN2_GEOMETRY="$(extract_geometry_token "$SCREEN2_OUTPUT")"

if [ -z "$SCREEN1_GEOMETRY" ] || [ -z "$SCREEN2_GEOMETRY" ]; then
  use_fallback_or_fail "Output-Geometrie konnte nicht gelesen werden"
  exit $?
fi

{
  parse_geometry_token "$SCREEN1_GEOMETRY" "SCREEN1_"
  parse_geometry_token "$SCREEN2_GEOMETRY" "SCREEN2_"
} > "$GEOMETRY_FILE" || {
  use_fallback_or_fail "Output-Geometrie konnte nicht verarbeitet werden"
  exit $?
}
EOF

echo "== kiosk-runtime-utils.sh =="
sudo tee "$APP_DIR/kiosk-runtime-utils.sh" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

kiosk_read_geometry_value() {
  local geometry_file="$1"
  local key="$2"
  awk -F= -v target="$key" '$1 == target { print $2; exit }' "$geometry_file"
}

kiosk_pick_numeric() {
  local candidate="$1"
  local fallback="$2"
  if [[ "$candidate" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$candidate"
  else
    printf '%s\n' "$fallback"
  fi
}
EOF

echo "== kiosk-screen1.sh =="
sudo tee "$APP_DIR/kiosk-screen1.sh" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/dual-kiosk-display/config.json"
LAYOUT_SCRIPT="/opt/dual-kiosk-display/kiosk-display-layout.sh"
RUNTIME_UTILS="/opt/dual-kiosk-display/kiosk-runtime-utils.sh"
GEOMETRY_FILE="/run/dual-kiosk-display/geometry.env"

URL="$(jq -r '.screen1.url' "$CONFIG_FILE")"
CHROMIUM_CMD="$(jq -r '.chromiumCommand // "chromium"' "$CONFIG_FILE")"
DISPLAY_NAME="$(jq -r '.screen1.display // ":0"' "$CONFIG_FILE")"
WINDOW_POSITION="$(jq -r '.screen1.windowPosition // "0,0"' "$CONFIG_FILE")"
WINDOW_SIZE="$(jq -r '.screen1.windowSize // "1920,1080"' "$CONFIG_FILE")"
PROFILE_DIR="$(jq -r '.screen1.profileDir // ""' "$CONFIG_FILE")"

IFS=',' read -r POS_X POS_Y <<< "$WINDOW_POSITION"
IFS=',' read -r WIDTH HEIGHT <<< "$WINDOW_SIZE"

if [ -z "$PROFILE_DIR" ]; then
  PROFILE_DIR="$HOME/.config/dual-kiosk-display/screen1"
fi
mkdir -p "$PROFILE_DIR"

export DISPLAY="$DISPLAY_NAME"
if [ -z "${XAUTHORITY:-}" ] && [ -n "${HOME:-}" ] && [ -f "$HOME/.Xauthority" ]; then
  export XAUTHORITY="$HOME/.Xauthority"
fi

if [ -x "$LAYOUT_SCRIPT" ]; then
  if ! "$LAYOUT_SCRIPT"; then
    echo "❌ Display-Layout konnte für screen1 nicht vorbereitet werden"
    exit 1
  fi
fi

if [ -x "$RUNTIME_UTILS" ]; then
  # shellcheck disable=SC1090
  source "$RUNTIME_UTILS"
fi

if [ -f "$GEOMETRY_FILE" ] && command -v kiosk_read_geometry_value >/dev/null 2>&1; then
  GEOM_POS_X="$(kiosk_read_geometry_value "$GEOMETRY_FILE" SCREEN1_POS_X)"
  GEOM_POS_Y="$(kiosk_read_geometry_value "$GEOMETRY_FILE" SCREEN1_POS_Y)"
  GEOM_WIDTH="$(kiosk_read_geometry_value "$GEOMETRY_FILE" SCREEN1_WIDTH)"
  GEOM_HEIGHT="$(kiosk_read_geometry_value "$GEOMETRY_FILE" SCREEN1_HEIGHT)"

  POS_X="$(kiosk_pick_numeric "$GEOM_POS_X" "$POS_X")"
  POS_Y="$(kiosk_pick_numeric "$GEOM_POS_Y" "$POS_Y")"
  WIDTH="$(kiosk_pick_numeric "$GEOM_WIDTH" "$WIDTH")"
  HEIGHT="$(kiosk_pick_numeric "$GEOM_HEIGHT" "$HEIGHT")"
fi

xset s off || true
xset -dpms || true
xset s noblank || true
unclutter -idle 0.5 &

exec "$CHROMIUM_CMD" \
  --noerrdialogs \
  --disable-infobars \
  --disable-session-crashed-bubble \
  --kiosk \
  --user-data-dir="$PROFILE_DIR" \
  --window-position="$POS_X,$POS_Y" \
  --window-size="$WIDTH,$HEIGHT" \
  "$URL"
EOF

echo "== kiosk-screen2.sh =="
sudo tee "$APP_DIR/kiosk-screen2.sh" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/dual-kiosk-display/config.json"
LAYOUT_SCRIPT="/opt/dual-kiosk-display/kiosk-display-layout.sh"
RUNTIME_UTILS="/opt/dual-kiosk-display/kiosk-runtime-utils.sh"
GEOMETRY_FILE="/run/dual-kiosk-display/geometry.env"

URL="$(jq -r '.screen2.url' "$CONFIG_FILE")"
CHROMIUM_CMD="$(jq -r '.chromiumCommand // "chromium"' "$CONFIG_FILE")"
DISPLAY_NAME="$(jq -r '.screen2.display // ":0"' "$CONFIG_FILE")"
WINDOW_POSITION="$(jq -r '.screen2.windowPosition // "1920,0"' "$CONFIG_FILE")"
WINDOW_SIZE="$(jq -r '.screen2.windowSize // "1920,1080"' "$CONFIG_FILE")"
PROFILE_DIR="$(jq -r '.screen2.profileDir // ""' "$CONFIG_FILE")"

IFS=',' read -r POS_X POS_Y <<< "$WINDOW_POSITION"
IFS=',' read -r WIDTH HEIGHT <<< "$WINDOW_SIZE"

if [ -z "$PROFILE_DIR" ]; then
  PROFILE_DIR="$HOME/.config/dual-kiosk-display/screen2"
fi
mkdir -p "$PROFILE_DIR"

export DISPLAY="$DISPLAY_NAME"
if [ -z "${XAUTHORITY:-}" ] && [ -n "${HOME:-}" ] && [ -f "$HOME/.Xauthority" ]; then
  export XAUTHORITY="$HOME/.Xauthority"
fi

if [ -x "$LAYOUT_SCRIPT" ]; then
  if ! "$LAYOUT_SCRIPT"; then
    echo "❌ Display-Layout konnte für screen2 nicht vorbereitet werden"
    exit 1
  fi
fi

if [ -x "$RUNTIME_UTILS" ]; then
  # shellcheck disable=SC1090
  source "$RUNTIME_UTILS"
fi

if [ -f "$GEOMETRY_FILE" ] && command -v kiosk_read_geometry_value >/dev/null 2>&1; then
  GEOM_POS_X="$(kiosk_read_geometry_value "$GEOMETRY_FILE" SCREEN2_POS_X)"
  GEOM_POS_Y="$(kiosk_read_geometry_value "$GEOMETRY_FILE" SCREEN2_POS_Y)"
  GEOM_WIDTH="$(kiosk_read_geometry_value "$GEOMETRY_FILE" SCREEN2_WIDTH)"
  GEOM_HEIGHT="$(kiosk_read_geometry_value "$GEOMETRY_FILE" SCREEN2_HEIGHT)"

  POS_X="$(kiosk_pick_numeric "$GEOM_POS_X" "$POS_X")"
  POS_Y="$(kiosk_pick_numeric "$GEOM_POS_Y" "$POS_Y")"
  WIDTH="$(kiosk_pick_numeric "$GEOM_WIDTH" "$WIDTH")"
  HEIGHT="$(kiosk_pick_numeric "$GEOM_HEIGHT" "$HEIGHT")"
fi

xset s off || true
xset -dpms || true
xset s noblank || true
unclutter -idle 0.5 &

exec "$CHROMIUM_CMD" \
  --noerrdialogs \
  --disable-infobars \
  --disable-session-crashed-bubble \
  --kiosk \
  --user-data-dir="$PROFILE_DIR" \
  --window-position="$POS_X,$POS_Y" \
  --window-size="$WIDTH,$HEIGHT" \
  "$URL"
EOF

echo "== Rechte =="
sudo chmod +x "$APP_DIR/kiosk-display-layout.sh" "$APP_DIR/kiosk-runtime-utils.sh" "$APP_DIR/kiosk-screen1.sh" "$APP_DIR/kiosk-screen2.sh"
sudo chown -R "$USER_NAME:$USER_NAME" "$APP_DIR"

echo "== systemd Services =="
sudo tee /etc/systemd/system/kiosk-screen1.service >/dev/null <<EOF
[Unit]
Description=Kiosk Screen 1
After=graphical.target network-online.target
Wants=network-online.target

[Service]
User=$USER_NAME
Environment=DISPLAY=:0
Environment=XAUTHORITY=/home/$USER_NAME/.Xauthority
ExecStartPre=$APP_DIR/kiosk-display-layout.sh
ExecStart=$APP_DIR/kiosk-screen1.sh
Restart=always
RestartSec=5

[Install]
WantedBy=graphical.target
EOF

sudo tee /etc/systemd/system/kiosk-screen2.service >/dev/null <<EOF
[Unit]
Description=Kiosk Screen 2
After=graphical.target network-online.target
Wants=network-online.target

[Service]
User=$USER_NAME
Environment=DISPLAY=:0
Environment=XAUTHORITY=/home/$USER_NAME/.Xauthority
ExecStartPre=$APP_DIR/kiosk-display-layout.sh
ExecStart=$APP_DIR/kiosk-screen2.sh
Restart=always
RestartSec=5

[Install]
WantedBy=graphical.target
EOF

echo "== Enable Services =="
sudo systemctl daemon-reload
sudo systemctl enable kiosk-screen1 kiosk-screen2
sudo systemctl restart kiosk-screen1 kiosk-screen2

echo "== DONE =="
echo "👤 User: $USER_NAME"
echo "🏷️ Hostname: $KIOSK_HOSTNAME"
echo "🌐 Screen 1 URL: $SCREEN1_URL"
echo "🌐 Screen 2 URL: $SCREEN2_URL"
echo "📡 IP:"
hostname -I
