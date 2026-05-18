# kiosk-interactive-pi

Kleines Raspberry-Pi-Kiosk-Plugin für zwei Displays mit jeweils einer konfigurierbaren URL im Kiosk-Modus.

## Installation

Basis-Installation und Vorbereitung über `willi84/pi-helper`.

Danach das Plugin einfach installieren mit:

```bash
pi plugin willi84/kiosk-interactive-pi
```

## Display-Binding auf physische HDMI-Ports

Das Setup unterstützt jetzt eine robuste Zuordnung von `screen1` und `screen2` zu festen X11-Outputs (z. B. `HDMI-1`, `HDMI-2`) statt nur über statische Fensterpositionen.

### Output-Namen ermitteln

Auf dem Pi unter X11:

```bash
xrandr --query
```

Verwende die angezeigten Output-Namen als Werte für:

- `SCREEN1_OUTPUT`
- `SCREEN2_OUTPUT`

### Relevante Konfig-Keys in `kiosk-config.env`

- `SCREEN1_OUTPUT`, `SCREEN2_OUTPUT`: Physische X11-Outputs für Screen 1/2
- `SCREEN1_MODE`, `SCREEN2_MODE`: Optional feste Modi (z. B. `1920x1080`)
- `DISPLAY_LAYOUT_WAIT_SECONDS`: Wartezeit, bis X/xrandr verfügbar ist
- `DISPLAY_LAYOUT_RETRY_INTERVAL`: Retry-Intervall beim Warten
- `DISPLAY_LAYOUT_FALLBACK_TO_WINDOW_POSITION`: `true`/`false`
  - `true`: Bei fehlenden Outputs wird auf `SCREEN*_WINDOW_POSITION` und `SCREEN*_WINDOW_SIZE` zurückgefallen
  - `false`: Service startet nicht, wenn Outputs/Layout nicht zuverlässig gesetzt werden können

### Startverhalten

- Vor jedem Chromium-Start wird ein `xrandr`-Layout angewandt:
  - `screen1` Output bei `0x0`
  - `screen2` Output rechts von `screen1`
- Die Chromium-Fenstergröße/-position wird aus der echten Output-Geometrie abgeleitet.
- Beide Browser nutzen getrennte Profile, damit es keine Profil-Locks zwischen Instanzen gibt.
