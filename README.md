# kiosk-interactive-pi

Kleines Raspberry-Pi-Kiosk-Plugin für zwei Displays mit jeweils einer konfigurierbaren URL im Kiosk-Modus.

## Installation

Basis-Installation und Vorbereitung über `willi84/pi-helper`.

Danach das Plugin einfach installieren mit:

```bash
pi plugin willi84/kiosk-interactive-pi
```

## Konfiguration

`setup-kiosk.sh` liest `kiosk-config.env` (im Repo-Verzeichnis) ein und erzeugt daraus:

- `/etc/dual-kiosk-display/config.json` (Runtime-Konfiguration)
- `/opt/dual-kiosk-display/kiosk-screen1.sh`
- `/opt/dual-kiosk-display/kiosk-screen2.sh`
- systemd-Services `kiosk-screen1` und `kiosk-screen2`
- Symlink im User-Home: `~/kiosk-config.env` → lokale `kiosk-config.env`

Danach Setup ausführen:

```bash
cd /pfad/zum/plugin
sudo ./setup-kiosk.sh
```

## Root Cause + Fix (zwei Browser-Sessions)

Das Problem „Opening in existing browser session“ kam durch geteilte Chromium-Session/Profile.  
Fix: beide Screens verwenden jetzt eigene Profile via `--user-data-dir`:

- Screen 1: `/opt/dual-kiosk-display/chromium-profile-screen1`
- Screen 2: `/opt/dual-kiosk-display/chromium-profile-screen2`

Dadurch laufen zwei unabhängige Chromium-Hauptprozesse stabiler parallel.

## Betrieb prüfen

Service-Status:

```bash
systemctl status kiosk-screen1 --no-pager
systemctl status kiosk-screen2 --no-pager
```

Aktive Konfiguration prüfen:

```bash
sudo jq . /etc/dual-kiosk-display/config.json
```

Prozesse inkl. URL/Window/User-Data-Dir prüfen:

```bash
ps -efww | grep -E 'kiosk-screen|chromium.*--kiosk|--user-data-dir' | grep -v grep
```

## Logs / Debug / Restart-Schleifen

Live-Logs pro Service:

```bash
journalctl -u kiosk-screen1 -f
journalctl -u kiosk-screen2 -f
```

Gezielt die Start-Diagnose aus den Skripten:

```bash
journalctl -t kiosk-screen1 -n 50 --no-pager
journalctl -t kiosk-screen2 -n 50 --no-pager
```

Die Skripte loggen beim Start u. a.:

- URL (ohne Query/Fragment, mit maskierter User-Info)
- DISPLAY
- Fensterposition / Fenstergröße
- User-Data-Directory

Neustart-Schleifen erkennen:

```bash
journalctl -u kiosk-screen1 --since "15 minutes ago" | grep -E 'Start requested|Main process exited|Failed|Scheduled restart'
journalctl -u kiosk-screen2 --since "15 minutes ago" | grep -E 'Start requested|Main process exited|Failed|Scheduled restart'
```

## Verifizieren, dass beide Screens unterschiedliche Inhalte zeigen

URLs/Fensterpositionen aus Runtime-Config:

```bash
sudo jq -r '.screen1.url, .screen2.url, .screen1.windowPosition, .screen2.windowPosition, .screen1.display, .screen2.display' /etc/dual-kiosk-display/config.json
```

Monitor-/Layout-Check:

```bash
xrandr
xrandr --listmonitors
```

Optional (Fensterpositionen live prüfen):

```bash
sudo apt install -y wmctrl
wmctrl -lG
```
