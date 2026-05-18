#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SETUP_CONFIG_FILE="$SCRIPT_DIR/kiosk-config.env"

APP_DIR="/opt/dual-kiosk-display"
CONFIG_DIR="/etc/dual-kiosk-display"
CONFIG_FILE="$CONFIG_DIR/config.json"
SLIDES_PROFILE_DIR="$APP_DIR/chromium-profile-slides"
WEBSITE_PROFILE_DIR="$APP_DIR/chromium-profile-website"

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
DEFAULT_SLIDES_URL="https://docs.google.com/presentation/d/1qXXRuxEdrp3nGutWSS2N0uWYt8sRPmL24-GsqXWlJDM/present?loop=true&delayms=10000"
DEFAULT_WEBSITE_URL="https://pendler-alarm.de/"
DEFAULT_SLIDES_WINDOW_POSITION="0,0"
DEFAULT_WEBSITE_WINDOW_POSITION="1920,0"
DEFAULT_SLIDES_WINDOW_SIZE="1920,1080"
DEFAULT_WEBSITE_WINDOW_SIZE="1920,1080"

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
  local monitor_selector="${2:-0}"
  local monitor_line=""
  local monitor_lines=""
  local geometry=""
  local best_geometry=""
  local best_area=""
  local area=""
  local width=""
  local height=""
  local pos_x=""
  local pos_y=""

  monitor_lines="$(DISPLAY="$display" xrandr --listmonitors 2>/dev/null | tail -n +2 || true)"
  if [ -z "$monitor_lines" ]; then
    return
  fi

  if [ "$monitor_selector" = "largest" ] || [ "$monitor_selector" = "smallest" ]; then
    while IFS= read -r monitor_line; do
      geometry="$(printf '%s\n' "$monitor_line" | sed -nE 's/^[[:space:]]*[0-9]+:.* ([0-9]+)\/[0-9]+x([0-9]+)\/[0-9]+\+([0-9]+)\+([0-9]+).*/\1,\2,\3,\4/p')"
      if [ -z "$geometry" ]; then
        continue
      fi

      IFS=',' read -r width height pos_x pos_y <<< "$geometry"
      area=$((width * height))

      if [ -z "$best_area" ]; then
        best_area="$area"
        best_geometry="$geometry"
        continue
      fi

      if [ "$monitor_selector" = "largest" ] && [ "$area" -gt "$best_area" ]; then
        best_area="$area"
        best_geometry="$geometry"
      fi
      if [ "$monitor_selector" = "smallest" ] && [ "$area" -lt "$best_area" ]; then
        best_area="$area"
        best_geometry="$geometry"
      fi
    done <<< "$monitor_lines"

    if [ -n "$best_geometry" ]; then
      printf '%s\n' "$best_geometry"
    fi
    return
  fi

  monitor_line="$(printf '%s\n' "$monitor_lines" | sed -n "$((monitor_selector + 1))p")"
  if [ -z "$monitor_line" ]; then
    return
  fi

  geometry="$(printf '%s\n' "$monitor_line" | sed -nE 's/^[[:space:]]*[0-9]+:.* ([0-9]+)\/[0-9]+x([0-9]+)\/[0-9]+\+([0-9]+)\+([0-9]+).*/\1,\2,\3,\4/p')"
  if [ -n "$geometry" ]; then
    printf '%s\n' "$geometry"
  fi
}

detect_monitor_count() {
  local display="${1:-:0}"
  local monitor_count=""

  monitor_count="$(DISPLAY="$display" xrandr --listmonitors 2>/dev/null | sed -nE 's/^Monitors:[[:space:]]*([0-9]+)$/\1/p' | head -n1 || true)"
  if [ -n "$monitor_count" ]; then
    printf '%s\n' "$monitor_count"
  fi
}

screen_defaults_from_geometry() {
  local geometry="${1:-}"
  local fallback_position="${2:-}"
  local fallback_size="${3:-}"
  local width=""
  local height=""
  local pos_x=""
  local pos_y=""

  if [ -n "$geometry" ]; then
    IFS=',' read -r width height pos_x pos_y <<< "$geometry"
  fi

  if [ -z "$width" ] || [ -z "$height" ] || [ -z "$pos_x" ] || [ -z "$pos_y" ]; then
    printf '%s|%s\n' "$fallback_position" "$fallback_size"
    return
  fi

  printf '%s,%s|%s,%s\n' "$pos_x" "$pos_y" "$width" "$height"
}

# Rückwärtskompatibilität: SCREEN1_URL / SCREEN2_URL → Kontext-Variablen
if [ -z "${CONTEXT_SLIDES_URL:-}" ] && [ -n "${SCREEN1_URL:-}" ]; then
  CONTEXT_SLIDES_URL="${SCREEN1_URL}"
fi
if [ -z "${CONTEXT_WEBSITE_URL:-}" ] && [ -n "${SCREEN2_URL:-}" ]; then
  CONTEXT_WEBSITE_URL="${SCREEN2_URL}"
fi
# Rückwärtskompatibilität: SCREEN*_DISPLAY / SCREEN*_WINDOW_* → SLIDES_* / WEBSITE_*
if [ -z "${SLIDES_DISPLAY:-}" ] && [ -n "${SCREEN1_DISPLAY:-}" ]; then
  SLIDES_DISPLAY="${SCREEN1_DISPLAY}"
fi
if [ -z "${WEBSITE_DISPLAY:-}" ] && [ -n "${SCREEN2_DISPLAY:-}" ]; then
  WEBSITE_DISPLAY="${SCREEN2_DISPLAY}"
fi
if [ -z "${SLIDES_WINDOW_POSITION:-}" ] && [ -n "${SCREEN1_WINDOW_POSITION:-}" ]; then
  SLIDES_WINDOW_POSITION="${SCREEN1_WINDOW_POSITION}"
fi
if [ -z "${WEBSITE_WINDOW_POSITION:-}" ] && [ -n "${SCREEN2_WINDOW_POSITION:-}" ]; then
  WEBSITE_WINDOW_POSITION="${SCREEN2_WINDOW_POSITION}"
fi
if [ -z "${SLIDES_WINDOW_SIZE:-}" ] && [ -n "${SCREEN1_WINDOW_SIZE:-}" ]; then
  SLIDES_WINDOW_SIZE="${SCREEN1_WINDOW_SIZE}"
fi
if [ -z "${WEBSITE_WINDOW_SIZE:-}" ] && [ -n "${SCREEN2_WINDOW_SIZE:-}" ]; then
  WEBSITE_WINDOW_SIZE="${SCREEN2_WINDOW_SIZE}"
fi

KIOSK_HOSTNAME="$(resolve_config_value "${KIOSK_HOSTNAME:-}" "<HOSTNAME>" "$CURRENT_HOSTNAME")"
CONTEXT_SLIDES_URL="$(resolve_config_value "${CONTEXT_SLIDES_URL:-}" "<https://example.com>" "$DEFAULT_SLIDES_URL")"
CONTEXT_WEBSITE_URL="$(resolve_config_value "${CONTEXT_WEBSITE_URL:-}" "<https://example.org>" "$DEFAULT_WEBSITE_URL")"
WIFI_SSID="$(resolve_config_value "${WIFI_SSID:-}" "<SSID>" "")"
WIFI_PASSWORD="$(resolve_config_value "${WIFI_PASSWORD:-}" "<PASSWORD>" "")"
WIFI_HIDDEN="${WIFI_HIDDEN:-false}"

SLIDES_DISPLAY="${SLIDES_DISPLAY:-:0}"
WEBSITE_DISPLAY="${WEBSITE_DISPLAY:-:0}"

SLIDES_MONITOR_COUNT="$(detect_monitor_count "$SLIDES_DISPLAY")"
SLIDES_MONITOR_GEOMETRY="$(detect_monitor_geometry "$SLIDES_DISPLAY" 0)"
WEBSITE_MONITOR_GEOMETRY="$(detect_monitor_geometry "$WEBSITE_DISPLAY" 1)"

if [ "$SLIDES_DISPLAY" = "$WEBSITE_DISPLAY" ] && [ -n "$SLIDES_MONITOR_COUNT" ] && [ "$SLIDES_MONITOR_COUNT" -ge 2 ]; then
  SLIDES_MONITOR_GEOMETRY="$(detect_monitor_geometry "$SLIDES_DISPLAY" largest)"
  WEBSITE_MONITOR_GEOMETRY="$(detect_monitor_geometry "$WEBSITE_DISPLAY" smallest)"
elif [ "$WEBSITE_DISPLAY" != "$SLIDES_DISPLAY" ]; then
  WEBSITE_MONITOR_GEOMETRY="$(detect_monitor_geometry "$WEBSITE_DISPLAY" 0)"
fi

SLIDES_DEFAULTS="$(screen_defaults_from_geometry "$SLIDES_MONITOR_GEOMETRY" "$DEFAULT_SLIDES_WINDOW_POSITION" "$DEFAULT_SLIDES_WINDOW_SIZE")"
WEBSITE_DEFAULTS="$(screen_defaults_from_geometry "$WEBSITE_MONITOR_GEOMETRY" "$DEFAULT_WEBSITE_WINDOW_POSITION" "$DEFAULT_WEBSITE_WINDOW_SIZE")"

SLIDES_DEFAULT_POSITION="${SLIDES_DEFAULTS%%|*}"
SLIDES_DEFAULT_SIZE="${SLIDES_DEFAULTS##*|}"
WEBSITE_DEFAULT_POSITION="${WEBSITE_DEFAULTS%%|*}"
WEBSITE_DEFAULT_SIZE="${WEBSITE_DEFAULTS##*|}"

SLIDES_WINDOW_POSITION="${SLIDES_WINDOW_POSITION:-$SLIDES_DEFAULT_POSITION}"
WEBSITE_WINDOW_POSITION="${WEBSITE_WINDOW_POSITION:-$WEBSITE_DEFAULT_POSITION}"
SLIDES_WINDOW_SIZE="${SLIDES_WINDOW_SIZE:-$SLIDES_DEFAULT_SIZE}"
WEBSITE_WINDOW_SIZE="${WEBSITE_WINDOW_SIZE:-$WEBSITE_DEFAULT_SIZE}"

IFS=',' read -r SLIDES_POS_X SLIDES_POS_Y <<< "$SLIDES_WINDOW_POSITION"
IFS=',' read -r WEBSITE_POS_X WEBSITE_POS_Y <<< "$WEBSITE_WINDOW_POSITION"
IFS=',' read -r SLIDES_WIDTH SLIDES_HEIGHT <<< "$SLIDES_WINDOW_SIZE"
IFS=',' read -r WEBSITE_WIDTH WEBSITE_HEIGHT <<< "$WEBSITE_WINDOW_SIZE"

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
if [ -n "$SLIDES_MONITOR_GEOMETRY" ] || [ -n "$WEBSITE_MONITOR_GEOMETRY" ]; then
  echo "✅ Erkannte Monitor-Geometrie: slides=${SLIDES_MONITOR_GEOMETRY:-n/a} website=${WEBSITE_MONITOR_GEOMETRY:-n/a}"
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
sudo mkdir -p "$SLIDES_PROFILE_DIR" "$WEBSITE_PROFILE_DIR"

echo "== Config Symlink im Home-Verzeichnis =="
sudo -u "$USER_NAME" ln -sfn "$SETUP_CONFIG_FILE" "$HOME_CONFIG_SYMLINK"
echo "✅ Symlink erstellt: $HOME_CONFIG_SYMLINK -> $SETUP_CONFIG_FILE"

echo "== Kiosk Config =="
sudo tee "$CONFIG_FILE" >/dev/null <<EOF
{
  "contexts": {
    "slides": {
      "url": "$CONTEXT_SLIDES_URL",
      "display": "$SLIDES_DISPLAY",
      "windowPosition": "$SLIDES_WINDOW_POSITION",
      "windowSize": "$SLIDES_WINDOW_SIZE"
    },
    "website": {
      "url": "$CONTEXT_WEBSITE_URL",
      "display": "$WEBSITE_DISPLAY",
      "windowPosition": "$WEBSITE_WINDOW_POSITION",
      "windowSize": "$WEBSITE_WINDOW_SIZE"
    }
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

echo "== kiosk-slides.sh =="
sudo tee "$APP_DIR/kiosk-slides.sh" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/dual-kiosk-display/config.json"

URL="$(jq -r '.contexts.slides.url' "$CONFIG_FILE")"
DISPLAY_VALUE="$(jq -r '.contexts.slides.display // ":0"' "$CONFIG_FILE")"
CHROMIUM_CMD="$(jq -r '.chromiumCommand // "chromium"' "$CONFIG_FILE")"
WINDOW_POSITION="$(jq -r '.contexts.slides.windowPosition // "0,0"' "$CONFIG_FILE")"
WINDOW_SIZE="$(jq -r '.contexts.slides.windowSize // "1920,1080"' "$CONFIG_FILE")"
PROFILE_DIR="/opt/dual-kiosk-display/chromium-profile-slides"

IFS=',' read -r POS_X POS_Y <<< "$WINDOW_POSITION"
IFS=',' read -r WIDTH HEIGHT <<< "$WINDOW_SIZE"
URL_BASE="${URL%%[\?#]*}"
URL_HAS_QUERY="no"
URL_HAS_FRAGMENT="no"
if [[ "$URL" == *\?* ]]; then URL_HAS_QUERY="yes"; fi
if [[ "$URL" == *\#* ]]; then URL_HAS_FRAGMENT="yes"; fi
SAFE_URL_BASE="$(printf '%s\n' "$URL_BASE" | sed -E 's#(://)[^/@]+@#\1***@#')"

export DISPLAY="$DISPLAY_VALUE"

echo "[$(date -Is)] [kiosk-slides] Start requested (pid=$$)"
echo "[$(date -Is)] [kiosk-slides] URL_BASE=$SAFE_URL_BASE URL_HAS_QUERY=$URL_HAS_QUERY URL_HAS_FRAGMENT=$URL_HAS_FRAGMENT DISPLAY=$DISPLAY_VALUE WINDOW_POSITION=$WINDOW_POSITION WINDOW_SIZE=$WINDOW_SIZE USER_DATA_DIR=$PROFILE_DIR"

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

echo "== kiosk-website.sh =="
sudo tee "$APP_DIR/kiosk-website.sh" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/dual-kiosk-display/config.json"

URL="$(jq -r '.contexts.website.url' "$CONFIG_FILE")"
DISPLAY_VALUE="$(jq -r '.contexts.website.display // ":0"' "$CONFIG_FILE")"
CHROMIUM_CMD="$(jq -r '.chromiumCommand // "chromium"' "$CONFIG_FILE")"
WINDOW_POSITION="$(jq -r '.contexts.website.windowPosition // "1920,0"' "$CONFIG_FILE")"
WINDOW_SIZE="$(jq -r '.contexts.website.windowSize // "1920,1080"' "$CONFIG_FILE")"
PROFILE_DIR="/opt/dual-kiosk-display/chromium-profile-website"

IFS=',' read -r POS_X POS_Y <<< "$WINDOW_POSITION"
IFS=',' read -r WIDTH HEIGHT <<< "$WINDOW_SIZE"
URL_BASE="${URL%%[\?#]*}"
URL_HAS_QUERY="no"
URL_HAS_FRAGMENT="no"
if [[ "$URL" == *\?* ]]; then URL_HAS_QUERY="yes"; fi
if [[ "$URL" == *\#* ]]; then URL_HAS_FRAGMENT="yes"; fi
SAFE_URL_BASE="$(printf '%s\n' "$URL_BASE" | sed -E 's#(://)[^/@]+@#\1***@#')"

export DISPLAY="$DISPLAY_VALUE"

echo "[$(date -Is)] [kiosk-website] Start requested (pid=$$)"
echo "[$(date -Is)] [kiosk-website] URL_BASE=$SAFE_URL_BASE URL_HAS_QUERY=$URL_HAS_QUERY URL_HAS_FRAGMENT=$URL_HAS_FRAGMENT DISPLAY=$DISPLAY_VALUE WINDOW_POSITION=$WINDOW_POSITION WINDOW_SIZE=$WINDOW_SIZE USER_DATA_DIR=$PROFILE_DIR"

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
sudo chmod +x "$APP_DIR/kiosk-slides.sh" "$APP_DIR/kiosk-website.sh"
sudo chown -R "$USER_NAME:$USER_NAME" "$APP_DIR"

echo "== systemd Services =="
sudo tee /etc/systemd/system/kiosk-slides.service >/dev/null <<EOF
[Unit]
Description=Kiosk Context: slides
After=graphical.target network-online.target
Wants=network-online.target

[Service]
User=$USER_NAME
ExecStart=$APP_DIR/kiosk-slides.sh
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=kiosk-slides

[Install]
WantedBy=graphical.target
EOF

sudo tee /etc/systemd/system/kiosk-website.service >/dev/null <<EOF
[Unit]
Description=Kiosk Context: website
After=graphical.target network-online.target
Wants=network-online.target

[Service]
User=$USER_NAME
ExecStart=$APP_DIR/kiosk-website.sh
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=kiosk-website

[Install]
WantedBy=graphical.target
EOF

echo "== Enable Services =="
sudo systemctl daemon-reload
sudo systemctl enable kiosk-slides kiosk-website
sudo systemctl restart kiosk-slides kiosk-website

echo "== DONE =="
echo "👤 User: $USER_NAME"
echo "🏷️ Hostname: $KIOSK_HOSTNAME"
echo "🖥️ Kontext slides URL: $CONTEXT_SLIDES_URL"
echo "🌐 Kontext website URL: $CONTEXT_WEBSITE_URL"
echo "🔗 Config Symlink: $HOME_CONFIG_SYMLINK"
echo "📡 IP:"
hostname -I
