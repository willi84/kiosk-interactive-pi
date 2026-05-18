#!/usr/bin/env bash
set -euo pipefail

REPO_BASE="https://raw.githubusercontent.com/willi84/kiosk-interactive-pi/main"
TARGET_DIR="$(pwd -P)"
SETUP_SCRIPT_PATH="$TARGET_DIR/setup-kiosk.sh"
CONFIG_FILE_PATH="$TARGET_DIR/kiosk-config.env"

echo "⬇️ Lade Dateien nach: $TARGET_DIR"

curl -fsSL "$REPO_BASE/setup-kiosk.sh" -o "$SETUP_SCRIPT_PATH"
curl -fsSL "$REPO_BASE/kiosk-config.env" -o "$CONFIG_FILE_PATH"

echo "🔍 Prüfe Dateien..."
if [ ! -f "$SETUP_SCRIPT_PATH" ]; then
  echo "❌ setup-kiosk.sh wurde nicht abgelegt"
  exit 1
fi

if [ ! -f "$CONFIG_FILE_PATH" ]; then
  echo "❌ kiosk-config.env wurde nicht abgelegt"
  exit 1
fi

echo "✅ setup-kiosk.sh gefunden: $SETUP_SCRIPT_PATH"
echo "✅ kiosk-config.env gefunden: $CONFIG_FILE_PATH"

echo "🔧 Rechte setzen..."
chmod +x "$SETUP_SCRIPT_PATH"

echo "📝 Bitte ggf. config anpassen:"
echo "nano $CONFIG_FILE_PATH"

echo "🚀 Danach ausführen:"
echo "$SETUP_SCRIPT_PATH"
"$SETUP_SCRIPT_PATH"
