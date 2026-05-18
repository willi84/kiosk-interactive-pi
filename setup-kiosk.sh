#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SETUP_CONFIG_FILE="$SCRIPT_DIR/kiosk-config.env"

APP_DIR="/opt/dual-kiosk-display"
CONFIG_DIR="/etc/dual-kiosk-display"
CONFIG_FILE="$CONFIG_DIR/config.json"
SCREEN1_PROFILE_DIR="$APP_DIR/chromium-profile-screen1"
SCREEN2_PROFILE_DIR="$APP_DIR/chromium-profile-screen2"

USER_NAME="${SUDO_USER:-$(whoami)}"
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
if [ -z "$USER_HOME" ]; then
  echo "❌ Home-Verzeichnis für User '$USER_NAME' konnte nicht ermittelt werden."
  exit 1
fi
HOME_CONFIG_SYMLINK="$USER_HOME/kiosk-config.env"

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
DEFAULT_SCREEN1_WINDOW_POSITION="0,0"
DEFAULT_SCREEN2_WINDOW_POSITION="1920,0"
DEFAULT_SCREEN1_WINDOW_SIZE="1920,1080"
DEFAULT_SCREEN2_WINDOW_SIZE="1920,1080"

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

detect_monitor_geometry() {
  local display="${1:-:0}"
  local monitor_index="${2:-0}"
  local monitor_line=""
  local geometry=""

  if ! [[ "$monitor_index" =~ ^[0-9]+$ ]]; then
    return
  fi

  monitor_line="$(DISPLAY="$display" xrandr --listmonitors 2>/dev/null | tail -n +2 | sed -n "$((monitor_index + 1))p" || true)"
  if [ -z "$monitor_line" ]; then
    return
  fi

  # Expected xrandr --listmonitors line format:
  # " 1: +HDMI-A-2 1024/150x600/90+1920+0  HDMI-A-2"
  geometry="$(printf '%s\n' "$monitor_line" | sed -nE 's/^[[:space:]]*[0-9]+:.* ([0-9]+)\/[0-9]+x([0-9]+)\/[0-9]+\+([0-9]+)\+([0-9]+).*/\1,\2,\3,\4/p')"
  if [ -z "$geometry" ]; then
    return
  fi

  printf '%s\n' "$geometry"
}

screen_defaults_from_geometry() {
  local geometry="${1:-}"
  local fallback_position="${2:-}"
  local fallback_size="${3:-}"
  local width=""
  local height=""
  local pos_x=""
  local pos_y=""

  if [[ "$geometry" =~ ^[0-9]+,[0-9]+,[0-9]+,[0-9]+$ ]]; then
    IFS=',' read -r width height pos_x pos_y <<< "$geometry"
  fi

  if [ -z "$width" ] || [ -z "$height" ] || [ -z "$pos_x" ] || [ -z "$pos_y" ]; then
    printf '%s|%s\n' "$fallback_position" "$fallback_size"
    return
  fi

  printf '%s,%s|%s,%s\n' "$pos_x" "$pos_y" "$width" "$height"
}

KIOSK_HOSTNAME="$(resolve_config_value "${KIOSK_HOSTNAME:-}" "<HOSTNAME>" "$CURRENT_HOSTNAME")"
SCREEN1_URL="$(resolve_config_value "${SCREEN1_URL:-}" "<https://example.com>" "$DEFAULT_SCREEN1_URL")"
SCREEN2_URL="$(resolve_config_value "${SCREEN2_URL:-}" "<https://example.org>" "$DEFAULT_SCREEN2_URL")"
WIFI_SSID="$(resolve_config_value "${WIFI_SSID:-}" "<SSID>" "")"
WIFI_PASSWORD="$(resolve_config_value "${WIFI_PASSWORD:-}" "<PASSWORD>" "")"
WIFI_HIDDEN="${WIFI_HIDDEN:-false}"

SCREEN1_DISPLAY="${SCREEN1_DISPLAY:-:0}"
SCREEN2_DISPLAY="${SCREEN2_DISPLAY:-:0}"

SCREEN1_MONITOR_GEOMETRY="$(detect_monitor_geometry "$SCREEN1_DISPLAY" 0)"
SCREEN2_MONITOR_INDEX=1
if [ "$SCREEN2_DISPLAY" != "$SCREEN1_DISPLAY" ]; then
  SCREEN2_MONITOR_INDEX=0
fi
SCREEN2_MONITOR_GEOMETRY="$(detect_monitor_geometry "$SCREEN2_DISPLAY" "$SCREEN2_MONITOR_INDEX")"

SCREEN1_DEFAULTS="$(screen_defaults_from_geometry "$SCREEN1_MONITOR_GEOMETRY" "$DEFAULT_SCREEN1_WINDOW_POSITION" "$DEFAULT_SCREEN1_WINDOW_SIZE")"
SCREEN2_DEFAULTS="$(screen_defaults_from_geometry "$SCREEN2_MONITOR_GEOMETRY" "$DEFAULT_SCREEN2_WINDOW_POSITION" "$DEFAULT_SCREEN2_WINDOW_SIZE")"

SCREEN1_DEFAULT_POSITION="${SCREEN1_DEFAULTS%%|*}"
SCREEN1_DEFAULT_SIZE="${SCREEN1_DEFAULTS##*|}"
SCREEN2_DEFAULT_POSITION="${SCREEN2_DEFAULTS%%|*}"
SCREEN2_DEFAULT_SIZE="${SCREEN2_DEFAULTS##*|}"

SCREEN1_WINDOW_POSITION="${SCREEN1_WINDOW_POSITION:-$SCREEN1_DEFAULT_POSITION}"
SCREEN2_WINDOW_POSITION="${SCREEN2_WINDOW_POSITION:-$SCREEN2_DEFAULT_POSITION}"
SCREEN1_WINDOW_SIZE="${SCREEN1_WINDOW_SIZE:-$SCREEN1_DEFAULT_SIZE}"
SCREEN2_WINDOW_SIZE="${SCREEN2_WINDOW_SIZE:-$SCREEN2_DEFAULT_SIZE}"

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
if [ -n "$SCREEN1_MONITOR_GEOMETRY" ] || [ -n "$SCREEN2_MONITOR_GEOMETRY" ]; then
  echo "✅ Erkannte Monitor-Geometrie: screen1=${SCREEN1_MONITOR_GEOMETRY:-n/a} screen2=${SCREEN2_MONITOR_GEOMETRY:-n/a}"
else
  echo "ℹ️ Keine Monitor-Geometrie via xrandr erkannt – nutze Standardwerte/Config."
fi

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
sudo mkdir -p "$SCREEN1_PROFILE_DIR" "$SCREEN2_PROFILE_DIR"

echo "== Config Symlink im Home-Verzeichnis =="
sudo -u "$USER_NAME" ln -sfn "$SETUP_CONFIG_FILE" "$HOME_CONFIG_SYMLINK"
echo "✅ Symlink erstellt: $HOME_CONFIG_SYMLINK -> $SETUP_CONFIG_FILE"

echo "== Kiosk Config =="
sudo tee "$CONFIG_FILE" >/dev/null <<EOF
{
  "screen1": {
    "url": "$SCREEN1_URL",
    "display": "$SCREEN1_DISPLAY",
    "windowPosition": "$SCREEN1_WINDOW_POSITION",
    "windowSize": "$SCREEN1_WINDOW_SIZE"
  },
  "screen2": {
    "url": "$SCREEN2_URL",
    "display": "$SCREEN2_DISPLAY",
    "windowPosition": "$SCREEN2_WINDOW_POSITION",
    "windowSize": "$SCREEN2_WINDOW_SIZE"
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

echo "== kiosk-screen1.sh =="
sudo tee "$APP_DIR/kiosk-screen1.sh" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/dual-kiosk-display/config.json"

URL="$(jq -r '.screen1.url' "$CONFIG_FILE")"
DISPLAY_VALUE="$(jq -r '.screen1.display // ":0"' "$CONFIG_FILE")"
CHROMIUM_CMD="$(jq -r '.chromiumCommand // "chromium"' "$CONFIG_FILE")"
WINDOW_POSITION="$(jq -r '.screen1.windowPosition // "0,0"' "$CONFIG_FILE")"
WINDOW_SIZE="$(jq -r '.screen1.windowSize // "1920,1080"' "$CONFIG_FILE")"
PROFILE_DIR="/opt/dual-kiosk-display/chromium-profile-screen1"

IFS=',' read -r POS_X POS_Y <<< "$WINDOW_POSITION"
IFS=',' read -r WIDTH HEIGHT <<< "$WINDOW_SIZE"
URL_BASE="${URL%%[\?#]*}"
URL_HAS_QUERY="no"
URL_HAS_FRAGMENT="no"
if [[ "$URL" == *\?* ]]; then URL_HAS_QUERY="yes"; fi
if [[ "$URL" == *\#* ]]; then URL_HAS_FRAGMENT="yes"; fi
SAFE_URL_BASE="$(printf '%s\n' "$URL_BASE" | sed -E 's#(://)[^/@]+@#\1***@#')"

export DISPLAY="$DISPLAY_VALUE"

echo "[$(date -Is)] [kiosk-screen1] Start requested (pid=$$)"
echo "[$(date -Is)] [kiosk-screen1] URL_BASE=$SAFE_URL_BASE URL_HAS_QUERY=$URL_HAS_QUERY URL_HAS_FRAGMENT=$URL_HAS_FRAGMENT DISPLAY=$DISPLAY_VALUE WINDOW_POSITION=$WINDOW_POSITION WINDOW_SIZE=$WINDOW_SIZE USER_DATA_DIR=$PROFILE_DIR"

xset s off || true
xset -dpms || true
xset s noblank || true
unclutter -idle 0.5 &

exec "$CHROMIUM_CMD" \
  --noerrdialogs \
  --disable-infobars \
  --disable-session-crashed-bubble \
  --user-data-dir="$PROFILE_DIR" \
  --kiosk \
  --window-position="$POS_X,$POS_Y" \
  --window-size="$WIDTH,$HEIGHT" \
  "$URL"
EOF

echo "== kiosk-screen2.sh =="
sudo tee "$APP_DIR/kiosk-screen2.sh" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/dual-kiosk-display/config.json"

URL="$(jq -r '.screen2.url' "$CONFIG_FILE")"
DISPLAY_VALUE="$(jq -r '.screen2.display // ":0"' "$CONFIG_FILE")"
CHROMIUM_CMD="$(jq -r '.chromiumCommand // "chromium"' "$CONFIG_FILE")"
WINDOW_POSITION="$(jq -r '.screen2.windowPosition // "1920,0"' "$CONFIG_FILE")"
WINDOW_SIZE="$(jq -r '.screen2.windowSize // "1920,1080"' "$CONFIG_FILE")"
PROFILE_DIR="/opt/dual-kiosk-display/chromium-profile-screen2"

IFS=',' read -r POS_X POS_Y <<< "$WINDOW_POSITION"
IFS=',' read -r WIDTH HEIGHT <<< "$WINDOW_SIZE"
URL_BASE="${URL%%[\?#]*}"
URL_HAS_QUERY="no"
URL_HAS_FRAGMENT="no"
if [[ "$URL" == *\?* ]]; then URL_HAS_QUERY="yes"; fi
if [[ "$URL" == *\#* ]]; then URL_HAS_FRAGMENT="yes"; fi
SAFE_URL_BASE="$(printf '%s\n' "$URL_BASE" | sed -E 's#(://)[^/@]+@#\1***@#')"

export DISPLAY="$DISPLAY_VALUE"

echo "[$(date -Is)] [kiosk-screen2] Start requested (pid=$$)"
echo "[$(date -Is)] [kiosk-screen2] URL_BASE=$SAFE_URL_BASE URL_HAS_QUERY=$URL_HAS_QUERY URL_HAS_FRAGMENT=$URL_HAS_FRAGMENT DISPLAY=$DISPLAY_VALUE WINDOW_POSITION=$WINDOW_POSITION WINDOW_SIZE=$WINDOW_SIZE USER_DATA_DIR=$PROFILE_DIR"

xset s off || true
xset -dpms || true
xset s noblank || true
unclutter -idle 0.5 &

exec "$CHROMIUM_CMD" \
  --noerrdialogs \
  --disable-infobars \
  --disable-session-crashed-bubble \
  --user-data-dir="$PROFILE_DIR" \
  --kiosk \
  --window-position="$POS_X,$POS_Y" \
  --window-size="$WIDTH,$HEIGHT" \
  "$URL"
EOF

echo "== Rechte =="
sudo chmod +x "$APP_DIR/kiosk-screen1.sh" "$APP_DIR/kiosk-screen2.sh"
sudo chown -R "$USER_NAME:$USER_NAME" "$APP_DIR"

echo "== systemd Services =="
sudo tee /etc/systemd/system/kiosk-screen1.service >/dev/null <<EOF
[Unit]
Description=Kiosk Screen 1
After=graphical.target network-online.target
Wants=network-online.target

[Service]
User=$USER_NAME
ExecStart=$APP_DIR/kiosk-screen1.sh
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=kiosk-screen1

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
ExecStart=$APP_DIR/kiosk-screen2.sh
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=kiosk-screen2

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
echo "🔗 Config Symlink: $HOME_CONFIG_SYMLINK"
echo "📡 IP:"
hostname -I
