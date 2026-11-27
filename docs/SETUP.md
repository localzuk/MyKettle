# MyKettle – Setup Guide

Control your **GÖTZE & JENSEN KT975K** (or any other Tuya / SETTI+ smart kettle) from a KDE Plasma 6 widget, directly over your home network.

> **Safety first:** never start the kettle remotely unless it has water in it and is sitting on its base. The kettle has dry-boil protection, but don't rely on it. You can turn on a "Is there water in the kettle?" prompt under *Configure MyKettle → General*.

---

## How it works

```
 ┌──────────────┐   HTTP on 127.0.0.1:8765   ┌──────────────────┐   encrypted Tuya LAN protocol   ┌─────────┐
 │ Plasma widget│ ─────────────────────────► │ mykettle service │ ──────────────────────────────► │ Kettle  │
 └──────────────┘                            │ (Python+tinytuya)│        (port 6668, Wi-Fi)       └─────────┘
                                             └──────────────────┘
```

* The **widget** shows the water temperature, a Start/Stop button, temperature presets, keep-warm and more.
* The **mykettle service** keeps one connection open to the kettle and receives live updates. It runs as a systemd *user* service, so no root.
* Once set up, **nothing goes through the cloud**. The kettle still works with the phone app as before.

The kettle encrypts its local traffic with a **Local Key**. The SETTI+ app never shows it, so you need to get it once from Tuya's cloud with a free developer account. The setup wizard walks you through this. Most of this guide covers that step.

---

## What you need

* KDE Plasma 6 (tested with 6.8) and Python 3.9+ (with `venv` support).
* The kettle already working in the SETTI+ (or Smart Life / Tuya Smart) app.
* Your computer on the **same network** as the kettle.
* About 15 minutes.

---

## Step 1 – Install

Open a terminal in the MyKettle folder and run:

```bash
./install.sh
```

Everything is installed into your home folder:

| What | Where |
|---|---|
| backend + Python venv with [tinytuya](https://github.com/jasonacox/tinytuya) | `~/.local/share/mykettle/` |
| `mykettle` command | `~/.local/bin/mykettle` |
| background service | `~/.config/systemd/user/mykettle.service` |
| Plasma widget | `~/.local/share/plasma/plasmoids/org.kde.plasma.mykettle/` |
| your kettle settings (incl. the key, `chmod 600`) | `~/.config/mykettle/config.json` |

At the end the installer offers to start the **setup wizard**. You can also start it later in any of these ways:

* run `mykettle setup`
* click **Run setup wizard…** in the widget
* go to *Configure MyKettle → Kettle Setup*

---

## Step 2 – Get the Local Key (the wizard's "Guided" option)

The wizard asks how you want to get the key. **Option 1 (Guided)** is recommended. It needs a free Tuya developer account. Do the following on a PC browser and your phone.

### 2a. Put the kettle in an app Tuya can link

SETTI+ is a re-branded Tuya app. Tuya's developer platform can link accounts from the **Smart Life** and **Tuya Smart** apps.

* **Try SETTI+ first** (step 2c). If the kettle appears in the device list, you're done.
* **If it doesn't appear,** move the kettle to Smart Life:
  1. In SETTI+: open the kettle → ✎ / ⋯ (top right) → **Remove Device**.
  2. Install **Smart Life** (Google Play / App Store), create an account, and tap **+ → Add Device**.
  3. Put the kettle in pairing mode as its manual describes (usually: hold the power or Wi-Fi button for about 5 seconds until the light blinks quickly), then follow the app.
  4. Check the kettle works in Smart Life. Its controls there match SETTI+, so you can keep using Smart Life on your phone.

> ⚠️ Every time a kettle is removed and paired again, it gets a **new Local Key**. If you ever do that, just run `mykettle setup` again. The saved cloud credentials make it quick.

### 2b. Create a free Tuya developer project

1. Go to **https://platform.tuya.com** and sign up (free) or log in.
2. Click **Cloud → Development → Create Cloud Project** and fill in:
   * *Project name:* anything, e.g. `MyKettle`
   * *Industry:* **Smart Home**
   * *Development Method:* **Smart Home**
   * *Data Center:* the region your app account belongs to. For accounts made in Europe (including Poland and Germany), choose **Central Europe Data Center**. You can add more data centers later.
3. On the *Authorize API Services* page, keep the defaults and click **Authorize**. These include **IoT Core** and **Authorization Token Management**, which is all MyKettle needs.
4. Open the project. The **Overview** tab shows:
   * **Access ID / Client ID**
   * **Access Secret / Client Secret** (click the eye icon to reveal it)

   Keep this page open. The wizard asks for both values.

### 2c. Link your phone app account

5. In the project, open the **Devices** tab → **Link App Account** (sometimes *Link Tuya App Account*) → **Add App Account**. A QR code appears.
6. On your phone, open the app (SETTI+ or Smart Life) → **Me / Profile** tab → tap the **scan icon** in the top-right corner. Scan the QR code and confirm (*Automatic link*, *Read/Write* permission).
7. The kettle should now appear under **Devices → All Devices** on the website.

### 2d. Let the wizard fetch the key

Back in the wizard, enter the Access ID, the Access Secret and the data center region. The wizard downloads your device list and asks you to pick the kettle. It also downloads the kettle's **data-point names**, so the controls usually map automatically.

**Troubleshooting the cloud step**

| Message | Fix |
|---|---|
| `sign invalid` / `clientId is invalid` | The Access ID or Secret has a typo. Copy them again. |
| `permission deny` / `28841002` / `No permissions` | The **IoT Core** free trial has expired. Go to *Cloud → Cloud Services → IoT Core* and extend it (free, takes a click). |
| Login works but no devices are found | The app account isn't linked (step 2c), the kettle is in SETTI+ but SETTI+ can't be linked (move it to Smart Life, step 2a), or you picked the wrong region. |

### Other ways to get the key

* **Option 2 – Import devices.json:** if you've already run another extraction tool, such as `python -m tinytuya wizard` (which writes `devices.json`), point the wizard at that file.
* **Option 3 – Type it in:** if you already know the Device ID and Local Key (for example from Home Assistant), enter them directly. The Device ID is also shown in the app under *Device Information → Virtual ID*.

---

## Step 3 – Find the kettle on the network

The wizard listens for the kettle's broadcast and fills in its **IP address** and **protocol version** (3.3, 3.4 or 3.5) automatically.

If the kettle isn't found:

* make sure the kettle is plugged in;
* the PC and kettle must be on the same subnet or VLAN (guest Wi-Fi networks often isolate devices);
* allow UDP ports **6666, 6667** and TCP port **6668** through your firewall (for example `sudo ufw allow 6666:6668/udp` and `sudo ufw allow 6668/tcp`, or the matching *firewalld* rules);
* or look up the kettle's IP in your router's client list and type it in.

**Tip:** give the kettle a fixed IP address (a DHCP reservation) in your router, so it never changes.

---

## Step 4 – Match the data points

Tuya devices report numbered **data points (DPs)**, and each kettle model numbers them differently. The wizard shows a table like this:

```
    1* Heating on/off (boil/start)      DP    1  switch Boolean
    2  Current water temperature        DP    5  temp_current Integer
    3  Target temperature               DP    2  temp_set Integer
    4  Keep-warm on/off                 DP   13  switch_keep_warm Boolean
    ...
```

* If the key came from the cloud, the rows are **filled in automatically** from the DP names. Check them and press Enter.
* To fix a row, type its number and choose **Learn it**. Then, within 25 seconds, change *only that setting* on the kettle or in the phone app. The wizard watches which DP changes and assigns it.
* Only **Heating on/off** is required. Map whatever else your kettle has. The widget hides controls that aren't mapped.

The KT975K's manual lists boil temperatures of **40 / 55 / 80 / 90 / 100 °C** and keep-warm temperatures of **40 / 55 / 80 / 90 °C**. The wizard uses these as the quick-pick buttons, and you can change them.

The wizard can then run a quick test: it switches heating on for 3 seconds and off again (only with water in the kettle!). After that it saves the settings and starts the service.

---

## Step 5 – Add the widget

Right-click your panel or desktop → **Add or Manage Widgets…** → search **MyKettle** → drag it onto the panel or desktop.

| Action | What it does |
|---|---|
| **Left-click** the panel icon | open the controls |
| **Middle-click** the panel icon | start / stop heating (can be turned off in settings) |
| Icon colour | grey = offline, normal = idle, **red and pulsing** = heating, **amber** = keeping warm |
| Right-click | Start/Stop, Run Setup Wizard, Restart Backend Service, Open Setup Guide |

The popup shows the live temperature dial, a **Heat to … / Stop** button, temperature presets with a fine slider, the keep-warm switch, keep-warm temperature and duration, mode, any fault messages, and a list of *All data points* for troubleshooting.

When the water is ready you get a desktop notification. You can turn this off in the settings.

---

## Command line

```bash
mykettle status            # current state
mykettle set power on      # start heating
mykettle set temp_set 80   # set target temperature
mykettle set keep_warm on
mykettle set 13 true       # set a raw DP by number
mykettle learn             # print DPs as they change (reverse-engineering)
mykettle scan              # list Tuya devices on the LAN
mykettle doctor            # check the whole installation
mykettle setup             # run the wizard again
journalctl --user -u mykettle -f   # service log
```

---

## Troubleshooting

| Problem | What to do |
|---|---|
| Widget says *Background service is not running* | Click **Start service**, or run `systemctl --user enable --now mykettle`. Check `journalctl --user -u mykettle -e` for errors. |
| *Can't reach the kettle* | Check the kettle is powered and its IP hasn't changed (`mykettle scan`). Close the phone app: the kettle accepts only a few local connections. |
| `Check device key or version` / error 914 | The Local Key is out of date (the kettle was re-paired) or the protocol version is wrong. Run `mykettle setup` and pick *Keep the current kettle…*, or fetch a new key. |
| A button does nothing or controls the wrong thing | A DP is mapped wrong. Run `mykettle setup` and use **Learn it** for that control. |
| Temperature shows 10× too high | The DP has a scale. Edit `~/.config/mykettle/config.json`, set `"scale": 1` for that role, then `systemctl --user restart mykettle`. |
| Widget unchanged after an upgrade | `systemctl --user restart plasma-plasmashell` |

### The config file

`~/.config/mykettle/config.json` is plain JSON, so you can edit it by hand. After any change, run `systemctl --user restart mykettle`.

```json
{
  "name": "Kitchen kettle",
  "device_id": "bf…",
  "local_key": "…",
  "ip": "192.168.1.50",
  "version": "3.4",
  "port": 8765,
  "roles": {
    "power":        {"dp": "1",  "type": "Boolean"},
    "temp_current": {"dp": "5",  "type": "Integer", "min": 0, "max": 100, "scale": 0, "unit": "°C"},
    "temp_set":     {"dp": "2",  "type": "Integer", "min": 40, "max": 100, "step": 5, "scale": 0, "unit": "°C"},
    "keep_warm":    {"dp": "13", "type": "Boolean"}
  },
  "boil_presets": [40, 55, 80, 90, 100],
  "warm_presets": [40, 55, 80, 90]
}
```

Available roles: `power`, `temp_current`, `temp_set`, `keep_warm`, `keep_warm_temp`, `warm_time`, `mode`, `status`, `remaining`, `fault`. Each role has a `type` of `Boolean`, `Integer` (with optional `min`/`max`/`step`/`scale`/`unit`) or `Enum` (with a `range` list of allowed strings).

---

## Security notes

* The Local Key and the optional cloud credentials are stored only in `~/.config/mykettle/config.json`, which is readable only by you.
* The service listens on **127.0.0.1 only**. It rejects requests with a foreign `Host` header (to block DNS rebinding) and requires a custom header for changes, so websites open in your browser can't switch your kettle on.
* Any program running as your user *can* control the kettle through the service. This is the same trust level as the rest of your desktop session.

## Licences

MyKettle is © 2026 Tony Ayre and licensed under GPL-3.0-or-later. To see every library it uses and read their licences, open *Configure MyKettle… → Licences* in the widget, run `mykettle about`, or choose *About MyKettle* in the setup wizard.

## Uninstall

```bash
./uninstall.sh            # keeps your kettle settings
./uninstall.sh --purge    # also deletes ~/.config/mykettle
```
