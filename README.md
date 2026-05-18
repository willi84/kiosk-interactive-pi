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

- `/etc/dual-kiosk-display/config.json` (Runtime-Konfiguration mit Kontexten)
- `/opt/dual-kiosk-display/kiosk-slides.sh`
- `/opt/dual-kiosk-display/kiosk-website.sh`
- systemd-Services `kiosk-slides` und `kiosk-website`
- Symlink im User-Home: `~/kiosk-config.env` → lokale `kiosk-config.env`

Danach Setup ausführen:

```bash
cd /pfad/zum/plugin
sudo ./setup-kiosk.sh
```

### Kontext-Konfiguration

Die URL-Konfiguration erfolgt über Kontexte in `kiosk-config.env`:

| Variable              | Kontext   | Beschreibung                              |
|-----------------------|-----------|-------------------------------------------|
| `CONTEXT_SLIDES_URL`  | `slides`  | Google Slides Präsentation (großer Monitor) |
| `CONTEXT_WEBSITE_URL` | `website` | Website (kleiner Monitor / Touch)         |

Wenn `SLIDES_WINDOW_POSITION`, `SLIDES_WINDOW_SIZE`, `WEBSITE_WINDOW_POSITION` oder `WEBSITE_WINDOW_SIZE` in `kiosk-config.env` nicht gesetzt sind, übernimmt `setup-kiosk.sh` nach Möglichkeit die aktuelle Monitor-Geometrie aus `xrandr --listmonitors`. Bei zwei Monitoren auf demselben `DISPLAY` wird `slides` automatisch auf den größeren und `website` auf den kleineren Monitor gelegt. Ohne erkennbare X-Layout-Infos bleiben die bisherigen Standardwerte aktiv.

Standard-URLs:

- `slides` (größerer Screen): Google Slides Präsentation
- `website` (kleinerer Screen): `https://pendler-alarm.de/`

Hinweis zur Touch-Erkennung: Aktuell wird Touch nicht separat per Input-Device-Mapping erkannt, sondern über die Größen-Heuristik abgebildet (`kleinerer Screen = Touch`, sofern das Setup so verdrahtet ist). Das kann abweichen, wenn der Touch-Monitor nicht der kleinere Screen ist oder wenn `xrandr --listmonitors` die Displays nicht korrekt liefert.

Beispiel für gemischte Auflösungen:

```dotenv
SLIDES_DISPLAY=:0
SLIDES_WINDOW_POSITION=0,0
SLIDES_WINDOW_SIZE=1920,1080

WEBSITE_DISPLAY=:0
WEBSITE_WINDOW_POSITION=1920,0
WEBSITE_WINDOW_SIZE=1024,600
```

Die WLAN-Konfiguration bleibt unverändert über `WIFI_SSID`, `WIFI_PASSWORD` und `WIFI_HIDDEN` in `kiosk-config.env` steuerbar.

### Rückwärtskompatibilität

Die alten Variablen `SCREEN1_URL` und `SCREEN2_URL` werden weiterhin unterstützt: Sind `CONTEXT_SLIDES_URL` / `CONTEXT_WEBSITE_URL` nicht gesetzt, verwendet `setup-kiosk.sh` automatisch `SCREEN1_URL` bzw. `SCREEN2_URL` als Fallback. Entsprechendes gilt für `SCREEN1_DISPLAY`, `SCREEN1_WINDOW_POSITION`, `SCREEN1_WINDOW_SIZE` usw.

## Root Cause + Fix (zwei Browser-Sessions)

Das Problem "Opening in existing browser session" kam durch geteilte Chromium-Session/Profile.  
Fix: beide Kontexte verwenden jetzt eigene Profile via `--user-data-dir`:

- Kontext `slides`: `/opt/dual-kiosk-display/chromium-profile-slides`
- Kontext `website`: `/opt/dual-kiosk-display/chromium-profile-website`

Dadurch laufen zwei unabhängige Chromium-Hauptprozesse stabiler parallel.

## Betrieb prüfen

Service-Status:

```bash
systemctl status kiosk-slides --no-pager
systemctl status kiosk-website --no-pager
```

Aktive Konfiguration prüfen:

```bash
sudo jq . /etc/dual-kiosk-display/config.json
```

Prozesse inkl. URL/Window/User-Data-Dir prüfen:

```bash
ps -efww | grep -E 'kiosk-(slides|website)|chromium.*--kiosk|--user-data-dir' | grep -v grep
```

## Logs / Debug / Restart-Schleifen

Live-Logs pro Service:

```bash
journalctl -u kiosk-slides -f
journalctl -u kiosk-website -f
```

Gezielt die Start-Diagnose aus den Skripten:

```bash
journalctl -t kiosk-slides -n 50 --no-pager
journalctl -t kiosk-website -n 50 --no-pager
```

Die Skripte loggen beim Start u. a.:

- URL-Basis (maskierte User-Info) + Marker, ob Query/Fragment vorhanden sind
- DISPLAY
- Fensterposition / Fenstergröße
- User-Data-Directory

Neustart-Schleifen erkennen:

```bash
journalctl -u kiosk-slides --since "15 minutes ago" | grep -E 'Start requested|Main process exited|Failed|Scheduled restart'
journalctl -u kiosk-website --since "15 minutes ago" | grep -E 'Start requested|Main process exited|Failed|Scheduled restart'
```

Hinweis: Der Filter `Start requested` bezieht sich auf die Log-Zeile aus den generierten `kiosk-*.sh`-Skripten.

## Verifizieren, dass beide Kontexte unterschiedliche Inhalte zeigen

URLs/Fensterpositionen aus Runtime-Config:

```bash
sudo jq -r '.contexts.slides.url, .contexts.website.url, .contexts.slides.windowPosition, .contexts.website.windowPosition, .contexts.slides.display, .contexts.website.display' /etc/dual-kiosk-display/config.json
```

Monitor-/Layout-Check:

```bash
DISPLAY=:0 xrandr
DISPLAY=:0 xrandr --listmonitors
```

Beispiel-Ausgabe für zwei unterschiedlich große Displays:

```text
Monitors: 2
 0: +HDMI-A-1 1920/370x1080/140+0+0  HDMI-A-1
 1: +HDMI-A-2 1024/150x600/90+1920+0  HDMI-A-2
```

Dazu passende Runtime-Config:

```bash
sudo jq '.contexts.slides, .contexts.website' /etc/dual-kiosk-display/config.json
```

Erwartete Werte im Beispiel oben:

- `contexts.slides.windowPosition`: `0,0`
- `contexts.slides.windowSize`: `1920,1080`
- `contexts.website.windowPosition`: `1920,0`
- `contexts.website.windowSize`: `1024,600`

Optional (Fensterpositionen live prüfen):

```bash
sudo apt install -y wmctrl
wmctrl -lG
```
