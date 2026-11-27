# ☕ MyKettle

A KDE Plasma 6 widget for Tuya-based smart kettles that you'd normally control with the **SETTI+** app, such as the **GÖTZE & JENSEN KT975K**. It controls the kettle directly over your Wi-Fi, with no cloud involved once it's set up.

* live water temperature in the panel, with a pulsing icon while heating
* Start/Stop, "heat to" presets (40 / 55 / 80 / 90 / 100 °C) and a fine slider
* keep-warm switch, keep-warm temperature and duration, mode, fault messages
* a "water is ready" notification, middle-click to start/stop, and a right-click menu
* a guided setup wizard that fetches the kettle's Local Key, finds it on the network and maps its data points
* a `mykettle` command-line tool

## Quick start

```bash
./install.sh
```

Then follow the wizard, and add **MyKettle** via *Add or Manage Widgets…*.

👉 Full step-by-step instructions, including how to get the Local Key: **[docs/SETUP.md](docs/SETUP.md)**

## Layout

```
install.sh / uninstall.sh
backend/mykettle.py        service + CLI (tinytuya, HTTP API on 127.0.0.1)
backend/setup_wizard.py    interactive terminal wizard
package/                   the Plasma 6 widget (org.kde.plasma.mykettle)
docs/SETUP.md              user guide
```

Backend API (localhost only; `POST` requests must send `X-MyKettle: 1`):

* `GET  /api/status`  – state, mapped roles and raw DPs
* `POST /api/set`     – `{"values": {"temp_set": 80, "power": true}}`; keys are role names or DP numbers
* `POST /api/reload`  – re-read the config file

Licence: GPL-2.0-or-later. Not affiliated with Tuya, SETTI+ or GÖTZE & JENSEN.
