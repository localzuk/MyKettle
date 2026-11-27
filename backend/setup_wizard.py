#!/usr/bin/env python3
"""
MyKettle interactive setup wizard.

Walks the user through:
  1. getting the kettle's Device ID + Local Key (Tuya cloud, a devices.json
     file from another tool, or typing them in),
  2. finding the kettle on the LAN (IP + protocol version),
  3. working out which Tuya data point (DP) does what,
  4. saving the config and starting the background service.
"""

from __future__ import annotations

import json
import os
import sys
import textwrap
import time
from pathlib import Path

import mykettle as mk

TTY = sys.stdout.isatty()
B = "\033[1m" if TTY else ""
D = "\033[2m" if TTY else ""
G = "\033[32m" if TTY else ""
Y = "\033[33m" if TTY else ""
R = "\033[31m" if TTY else ""
C = "\033[36m" if TTY else ""
N = "\033[0m" if TTY else ""

REGIONS = [
    ("eu", "Central Europe  (most of Europe, incl. Poland/Germany)"),
    ("eu-w", "Western Europe"),
    ("us", "Western America"),
    ("us-e", "Eastern America"),
    ("in", "India"),
    ("sg", "Singapore / Asia"),
    ("cn", "China"),
]


# --------------------------------------------------------------------------
# little UI helpers
# --------------------------------------------------------------------------
def wrap(text: str, indent="  ") -> str:
    """Re-flow plain paragraphs; keep indented / list lines exactly as written."""
    out: list[str] = []
    para: list[str] = []

    def flush():
        if para:
            out.append(textwrap.fill(" ".join(para), 78, initial_indent=indent, subsequent_indent=indent))
            para.clear()

    for line in textwrap.dedent(text).strip("\n").split("\n"):
        if not line.strip():
            flush()
            out.append("")
        elif line.startswith((" ", "-", "*")) or line.lstrip()[:2].rstrip(".").isdigit():
            flush()
            out.append(indent + line)
        else:
            para.append(line.strip())
    flush()
    return "\n".join(out)


def header(step: str, title: str):
    print(f"\n{C}{'━' * 78}{N}\n{B}{C}{step}{N}  {B}{title}{N}\n{C}{'━' * 78}{N}")


def say(text: str):
    print(wrap(text))


def ok(text):
    print(f"  {G}✔{N} {text}")


def warn(text):
    print(f"  {Y}!{N} {text}")


def fail(text):
    print(f"  {R}✘{N} {text}")


def ask(prompt: str, default: str | None = None, secret=False) -> str:
    sfx = f" {D}[{default}]{N}" if default not in (None, "") else ""
    while True:
        if secret:
            import getpass
            v = getpass.getpass(f"  {B}?{N} {prompt}{sfx}: ")
        else:
            v = input(f"  {B}?{N} {prompt}{sfx}: ")
        v = v.strip()
        if v:
            return v
        if default is not None:
            return default


def yes(prompt: str, default=True) -> bool:
    d = "Y/n" if default else "y/N"
    while True:
        v = input(f"  {B}?{N} {prompt} {D}({d}){N}: ").strip().lower()
        if not v:
            return default
        if v[0] in "yn":
            return v[0] == "y"


def choose(prompt: str, options: list[str], default: int = 1) -> int:
    for i, o in enumerate(options, 1):
        print(f"    {B}{i}{N}) {o}")
    while True:
        v = ask(prompt, str(default))
        if v.isdigit() and 1 <= int(v) <= len(options):
            return int(v)


def pause(msg="Press Enter to continue"):
    input(f"  {D}{msg}…{N}")


# --------------------------------------------------------------------------
# Step 1 - credentials
# --------------------------------------------------------------------------
CLOUD_GUIDE = """
To talk to the kettle directly over your Wi-Fi we need its {b}Local Key{n} (a
16-character secret the kettle uses to encrypt traffic). The SETTI+ app never
shows it, so we fetch it once from Tuya's cloud using a free Tuya developer
account. You only need to do this once.

{b}A. Make sure the kettle is in a Tuya app that can be linked{n}
   SETTI+ is a re-branded Tuya app. Tuya's developer site can link the
   {b}Smart Life{n} or {b}Tuya Smart{n} app directly. Try linking SETTI+ first (step C);
   if your kettle does not show up, move it to Smart Life:
     - In SETTI+: open the kettle > ✎ (top right) > Remove device.
     - Install {b}Smart Life{n}, sign up, tap {b}+{n} > Add device and pair the kettle
       (put it in pairing mode as the manual describes - usually hold the
       power / Wi-Fi button about 5 s until the light blinks quickly).
     - Check the kettle works in Smart Life. You can keep using Smart Life on
       your phone - it shows the same controls as SETTI+.

{b}B. Create a free Tuya developer project{n}
   1. Go to {u}https://platform.tuya.com{n} and sign up / log in.
   2. Cloud > Development > {b}Create Cloud Project{n}.
        Industry: Smart Home   Development method: Smart Home
        Data center: the region your app account is in (Europe -> Central
        Europe Data Center; you can add more later).
   3. On the "Authorize API services" page just click Authorize
      (the defaults incl. {b}IoT Core{n} and {b}Authorization Token Management{n} are enough).
   4. Open the project. The {b}Overview{n} tab shows the
      {b}Access ID / Client ID{n} and {b}Access Secret / Client Secret{n} - you'll need both.

{b}C. Link your phone app account{n}
   5. In the project open {b}Devices{n} > {b}Link App Account{n} > {b}Add App Account{n}.
      A QR code appears.
   6. In the phone app go to {b}Me{n} (Profile) and tap the {b}scan icon{n} in the top
      right corner, scan the QR code and confirm. The kettle should now be
      listed under Devices > All Devices.

{d}Note: Tuya's free "IoT Core" trial lasts a month; if fetching keys later fails
with "permission deny / 28841002", extend it (free) under Cloud > Cloud Services.
If you ever remove and re-pair the kettle, its local key changes - just run
`mykettle setup` again.{n}
"""


def credentials_from_cloud() -> dict | None:
    header("Step 1", "Fetch the local key from the Tuya cloud")
    print(wrap(CLOUD_GUIDE.format(b=B, n=N, u=C, d=D)))
    pause("Do steps A-C above, then press Enter")
    import tinytuya

    prev = (mk.load_config() or {}).get("cloud", {})
    key = ask("Access ID / Client ID", prev.get("apiKey"))
    secret = ask("Access Secret / Client Secret", prev.get("apiSecret") and "(keep saved secret)", secret=True)
    if secret == "(keep saved secret)":
        secret = prev.get("apiSecret")
    print(f"\n  {B}Data center region{N} (where your app account lives)")
    idx = choose("Region number", [f"{c:5} {d}" for c, d in REGIONS],
                 default=next((i for i, (c, _) in enumerate(REGIONS, 1) if c == prev.get("apiRegion")), 1))
    region = REGIONS[idx - 1][0]
    print(f"\n  Contacting Tuya cloud ({region})…")
    try:
        cloud = tinytuya.Cloud(apiRegion=region, apiKey=key, apiSecret=secret, configFile=os.devnull)
        if getattr(cloud, "error", None):
            raise RuntimeError(cloud.error)
        devices = cloud.getdevices(False, include_map=True)
    except Exception as exc:  # noqa: BLE001
        devices = {"Error": str(exc)}
    if isinstance(devices, dict) and ("Error" in devices or "Err" in devices):
        fail(f"Tuya cloud said: {devices.get('Error') or devices}")
        say("""
        Common causes: wrong region (it must match the data center of the linked
        app account), the app account isn't linked yet, a typo in the ID/secret,
        or the IoT Core trial has expired.""")
        return None
    if not devices:
        fail("Login worked but the device list came back empty.")
        # tinytuya hides the reason, so ask Tuya again and show its answer.
        raw = cloud.cloudrequest("/v1.0/iot-01/associated-users/devices", query={"size": "50"})
        if isinstance(raw, dict) and not raw.get("success", True):
            explain_cloud_error(raw)
        else:
            say("""
            Tuya accepted the request but listed no devices for linked app accounts.
            That is usually a region mismatch, or the link is still being processed.""")
        say("""
        You can skip the list: copy the kettle's {b}Device ID{n} from the Tuya website
        (your project > Devices > All Devices, "Device ID" column) and I'll fetch its
        key directly.""".format(b=B, n=N))
        while True:
            did = input(f"  {B}?{N} Device ID (or Enter to go back): ").strip()
            if not did:
                return None
            dev = fetch_device_by_id(cloud, did)
            if dev:
                break
        ok(f"Got the local key for {B}{dev.get('name')}{N}")
    else:
        dev = pick_device(devices)
    if dev and yes("Save the cloud Access ID/Secret (in your private config) so you can re-fetch keys later?", True):
        dev["_cloud"] = {"apiKey": key, "apiSecret": secret, "apiRegion": region}
    return dev


CLOUD_ERRORS = {
    "1004": "sign invalid - the Access Secret is wrong.",
    "1010": "token invalid - check the Access ID/Secret and region.",
    "1106": "permission deny - the project can't see this device/account. Check the app account "
            "is linked in THIS project and the region matches.",
    "2008": "command or API not supported - make sure the IoT Core API service is authorized "
            "for the project (Cloud > project > Service API).",
    "2009": "device not found in this data center - pick the region shown on the Tuya Devices page.",
    "28841002": "the IoT Core subscription/trial has expired or is still pending - extend it under "
                "Cloud > Cloud Services > IoT Core (approval can take a while).",
    "28841101": "IoT Core is not activated for this project - subscribe (free) under Cloud > Cloud Services.",
}


def explain_cloud_error(resp: dict):
    code = str(resp.get("code", ""))
    fail(f"Tuya says: code {code} - {resp.get('msg', '')}")
    if code in CLOUD_ERRORS:
        warn(CLOUD_ERRORS[code])


def fetch_device_by_id(cloud, did: str) -> dict | None:
    """Fetch one device (incl. local key and DP map) straight from the cloud."""
    r = cloud.cloudrequest(f"/v1.0/devices/{did}")
    if not isinstance(r, dict) or not r.get("success"):
        explain_cloud_error(r if isinstance(r, dict) else {"msg": str(r)})
        return None
    res = r.get("result", {})
    if not res.get("local_key"):
        fail("Tuya returned the device but no local key (Bluetooth-only or sub-device?).")
        return None
    dev = {"id": res.get("id", did), "key": res["local_key"], "name": res.get("name", "Kettle"),
           "product_id": res.get("product_id"), "category": res.get("category")}
    try:
        mapping = cloud.getmapping(res.get("product_id"), did)
        if mapping:
            dev["mapping"] = mapping
    except Exception:  # noqa: BLE001 - mapping is optional
        pass
    return dev


def pick_device(devices: list[dict]) -> dict | None:
    devices = [d for d in devices if d.get("id")]
    # kettles first (Tuya category "bh" = smart kettle)
    devices.sort(key=lambda d: (d.get("category") != "bh", "kettle" not in (d.get("name", "") + d.get("product_name", "")).lower()))
    print(f"\n  Found {len(devices)} device(s):")
    opts = [f"{d.get('name', '?'):28} {D}{d.get('product_name', '')} · {d.get('category', '')} · {d['id']}{N}" for d in devices]
    n = choose("Which one is the kettle?", opts, 1)
    dev = devices[n - 1]
    if not dev.get("key"):
        fail("That device has no local key in the cloud data (is it a Bluetooth-only or sub-device?).")
        return None
    ok(f"Got the local key for {B}{dev.get('name')}{N}")
    return dev


def credentials_from_file() -> dict | None:
    header("Step 1", "Import a devices.json file")
    say("""
    If you already used another tool to extract keys - for example
    `python -m tinytuya wizard`, which writes a {b}devices.json{n} - point me at that
    file and I'll read the kettle's ID, key and data-point map from it.""".format(b=B, n=N))
    while True:
        p = Path(os.path.expanduser(ask("Path to devices.json", str(Path.cwd() / "devices.json"))))
        try:
            data = json.loads(p.read_text())
            break
        except (OSError, ValueError) as exc:
            fail(f"Could not read {p}: {exc}")
            if not yes("Try another path?"):
                return None
    if isinstance(data, dict):
        data = data.get("devices") or [data]
    return pick_device(data)


def credentials_manual() -> dict | None:
    header("Step 1", "Enter the Device ID and Local Key")
    say("""
    The {b}Device ID{n} is ~20-22 characters (e.g. bf1234567890abcdefxyz1) and is also
    shown in the app under the kettle > ✎ > Device Information > Virtual ID.
    The {b}Local Key{n} is 16 characters and can contain symbols.""".format(b=B, n=N))
    did = ask("Device ID")
    key = ask("Local Key", secret=True)
    if len(key) != 16:
        warn(f"Local keys are normally 16 characters - this one is {len(key)}. Continuing anyway.")
    return {"id": did, "key": key, "name": "Kettle"}


# --------------------------------------------------------------------------
# Step 2 - network
# --------------------------------------------------------------------------
def locate(dev: dict) -> tuple[str, str | None]:
    header("Step 2", "Find the kettle on your network")
    import tinytuya
    say("""
    Make sure the kettle is plugged in and this computer is on the same network.
    Tip: give the kettle a fixed IP (DHCP reservation) in your router so it
    never moves.""")
    print("\n  Listening for the kettle's broadcast (up to ~20 s)…")
    ip = version = None
    try:
        r = tinytuya.find_device(dev["id"])
        ip, version = r.get("ip"), r.get("version")
    except Exception as exc:  # noqa: BLE001
        warn(f"scan failed: {exc}")
    if ip:
        ok(f"Found it at {B}{ip}{N} (protocol {version})")
        return ip, str(version) if version else None
    warn("The kettle did not answer the broadcast scan.")
    say("""
    This happens if the computer is on another subnet/VLAN, a firewall blocks
    UDP 6666-6667, or the kettle is asleep/unplugged. Look up its IP address in
    your router's client list (often named like "ESP_xxx", "wlan0" or the
    kettle model) or in the app under Device Information.""")
    old = dev.get("ip") or ""
    return ask("Kettle IP address", old or None), dev.get("version") or None


def connect_test(cfg: dict, version_hint: str | None) -> dict | None:
    header("Step 3", "Test the connection")
    versions = [v for v in [version_hint, "3.4", "3.3", "3.5", "3.1"] if v]
    seen = set()
    for v in versions:
        if v in seen:
            continue
        seen.add(v)
        cfg["version"] = str(v)
        print(f"  Trying protocol {v}…", end=" ", flush=True)
        try:
            k = mk.Kettle(cfg)
            d = k._make_device()
            d.set_socketPersistent(False)
            d.set_socketTimeout(5)
            data = d.status()
            d.close()
            if data and "dps" in data:
                print(f"{G}OK{N}")
                ok(f"The kettle replied with {len(data['dps'])} data points.")
                return {str(a): b for a, b in data["dps"].items()}
            print(f"{Y}{(data or {}).get('Error', 'no reply')}{N}")
        except Exception as exc:  # noqa: BLE001
            print(f"{Y}{exc}{N}")
    fail("Could not talk to the kettle.")
    say("""
    Checklist:
    - Is the local key current? Removing / re-pairing the kettle changes it.
    - Is the IP right and reachable (try: ping <ip>)?
    - Tuya devices accept only a few local connections - close the phone app
      or put the phone in airplane mode for a moment and try again.""")
    return None


# --------------------------------------------------------------------------
# Step 4 - data points
# --------------------------------------------------------------------------
def describe(dps: dict, mapping: dict):
    print(f"\n  {B}{'DP':>4}  {'value':<14} {'code (from cloud)':<22} type{N}")
    for dp in sorted(dps, key=lambda x: int(x) if x.isdigit() else 999):
        m = mapping.get(dp, {}) if mapping else {}
        print(f"  {dp:>4}  {json.dumps(dps[dp])[:14]:<14} {m.get('code', '-'):<22} {m.get('type', '')}")


def infer_spec(dp: str, value, mapping: dict, role: str) -> dict:
    if mapping and dp in mapping:
        return mk.spec_from_mapping(dp, mapping[dp])
    if isinstance(value, bool):
        return {"dp": dp, "type": "Boolean"}
    if isinstance(value, int):
        spec = {"dp": dp, "type": "Integer", "scale": 0}
        if role.startswith("temp") or role == "keep_warm_temp":
            spec.update({"min": 40 if role != "temp_current" else 0, "max": 100, "step": 1, "unit": "°C"})
        return spec
    spec = {"dp": dp, "type": "Enum" if role in ("mode", "status", "temp_set", "keep_warm_temp", "warm_time") else "String"}
    if spec["type"] == "Enum":
        spec["range"] = [str(value)]
    return spec


def learn_role(cfg: dict, role: str, mapping: dict, roles: dict) -> None:
    label = mk.ROLES[role]["label"]
    say(f"""
    {B}Learning: {label}{N}
    Get ready to change {B}only{N} this setting - using the buttons on the kettle
    or the phone app - within the next 25 seconds. (The service is paused while
    we listen.)""")
    if role == "power":
        warn("Only switch heating on if there is water in the kettle!")
    pause("Press Enter, then change the setting")
    try:
        changes = mk.learn_loop(cfg, 25, quiet=False)
    except Exception as exc:  # noqa: BLE001
        fail(f"listening failed: {exc}")
        return
    want = mk.ROLES[role]["types"]
    cands = [dp for dp, vals in changes.items()
             if (("Boolean" in want) == isinstance(vals[-1], bool))]
    if not cands:
        warn("Nothing suitable changed.")
        return
    dp = cands[0]
    if len(cands) > 1:
        dp = cands[choose("Several DPs changed - which one is it?", [f"DP {c}: {changes[c]}" for c in cands]) - 1]
    spec = infer_spec(dp, changes[dp][-1], mapping, role)
    if spec.get("type") == "Enum" and not mapping.get(dp):
        spec["range"] = sorted({str(v) for v in changes[dp]})
    roles[role] = spec
    ok(f"{label} -> DP {dp}")


def map_datapoints(cfg: dict, dps: dict, mapping: dict, previous: dict | None = None) -> dict:
    header("Step 4", "Work out what each data point does")
    say("""
    Tuya devices expose numbered "data points" (DPs) and every kettle model
    numbers them differently. Let's match them to the widget's controls.""")
    describe(dps, mapping)
    if previous:
        roles = {k: dict(v) for k, v in previous.items()}
        print(f"\n  {G}Your current mapping:{N}")
    elif mapping:
        roles = mk.auto_map_roles(mapping)
        print(f"\n  {G}Auto-detected from the cloud's DP names:{N}")
    else:
        roles = mk.guess_roles_from_values(dps)
        print(f"\n  {Y}No cloud DP names available - this is only a rough guess:{N}")

    while True:
        print()
        for i, (role, meta) in enumerate(mk.ROLES.items(), 1):
            spec = roles.get(role)
            tag = f"DP {spec['dp']:>4}  {D}{spec.get('code', '')} {spec.get('type', '')}{N}" if spec else f"{D}— not used —{N}"
            req = f"{R}*{N}" if role == "power" else " "
            print(f"   {i:>2}{req} {meta['label']:<32} {tag}")
        print(f"\n  {D}* required. Most kettles have power, current temp and target temp; the rest is optional.{N}")
        v = ask("Press Enter to accept, or type a number to change it", "ok")
        if v.lower() in ("ok", "y", "yes"):
            if "power" not in roles:
                fail("The heating on/off DP is required.")
                continue
            return roles
        if not v.isdigit() or not 1 <= int(v) <= len(mk.ROLES):
            continue
        role = list(mk.ROLES)[int(v) - 1]
        how = choose(f"{mk.ROLES[role]['label']}:",
                     ["Learn it - I'll change it on the kettle/app and you watch",
                      "Type the DP number",
                      "Not used / remove"], 1)
        if how == 1:
            learn_role(cfg, role, mapping, roles)
        elif how == 2:
            dp = ask("DP number")
            roles[role] = infer_spec(dp, dps.get(dp), mapping, role)
            if roles[role]["type"] == "Enum" and not mapping.get(dp):
                rng = ask("Allowed values, comma separated", ",".join(roles[role].get("range", [])))
                roles[role]["range"] = [x.strip() for x in rng.split(",") if x.strip()]
            ok(f"{mk.ROLES[role]['label']} -> DP {dp}")
        else:
            roles.pop(role, None)


def verify_power(cfg: dict):
    if not yes("Do a quick test: switch heating ON for 3 seconds and OFF again? (only with water in the kettle!)", False):
        return
    spec = cfg["roles"]["power"]
    try:
        k = mk.Kettle(cfg)
        d = k._make_device()
        d.set_socketPersistent(False)
        d.set_value(int(spec["dp"]), True)
        time.sleep(3)
        d.set_value(int(spec["dp"]), False)
        d.close()
        if yes("Did the kettle switch on (light/beep) and back off?", True):
            ok("Power control confirmed.")
        else:
            warn("Then the power DP is probably wrong - re-run `mykettle setup` and use 'Learn it'.")
    except Exception as exc:  # noqa: BLE001
        fail(f"test failed: {exc}")


# --------------------------------------------------------------------------
# main flow
# --------------------------------------------------------------------------
def main():
    print(f"""
{B}{C}  ☕  MyKettle setup{N}  {D}v{mk.__version__}{N}
{wrap('''
This wizard connects the Plasma widget to your Tuya / SETTI+ kettle (e.g. GÖTZE &
JENSEN KT975K) over your local network - no cloud needed once set up.
It takes about 10 minutes the first time. Press Ctrl+C to quit at any time;
nothing is saved until the end.''')}""")

    try:
        import tinytuya  # noqa: F401
    except ImportError:
        fail("tinytuya is not installed. Please run install.sh first.")
        sys.exit(1)

    old = mk.load_config() or {}
    stopped_service = False
    if mk.service_running():
        # The kettle allows few connections; pause our own service while testing.
        stopped_service = mk.systemctl("stop", mk.SERVICE) == 0

    try:
        dev = None
        while dev is None:
            header("Step 1", "How do you want to get the kettle's Local Key?")
            opts = [
                f"{B}Guided{N}: fetch it from Tuya's cloud with a free developer account {G}(recommended){N}",
                "Import a devices.json made by another tool (e.g. tinytuya wizard)",
                "I already have the Device ID and Local Key - type them in",
            ]
            if mk.config_ready(old):
                opts.append(f"Keep the current kettle ({old.get('name')}, {old.get('device_id')}) and just redo the network/DP steps")
            c = choose("Choose", opts, 4 if mk.config_ready(old) else 1)
            if c == 1:
                dev = credentials_from_cloud()
            elif c == 2:
                dev = credentials_from_file()
            elif c == 3:
                dev = credentials_manual()
            else:
                dev = {"id": old["device_id"], "key": old["local_key"], "name": old.get("name"),
                       "ip": old.get("ip"), "version": old.get("version"), "mapping": old.get("mapping"),
                       "_cloud": old.get("cloud")}
            if dev is None and not yes("Try again?", True):
                sys.exit(1)

        mapping = dev.get("mapping") or {}
        mapping = {str(k): v for k, v in mapping.items()} if isinstance(mapping, dict) else {}

        ip, version = locate(dev)
        cfg = {
            "name": dev.get("name") or "Kettle",
            "device_id": dev["id"],
            "local_key": dev["key"],
            "ip": ip,
            "version": version or "3.4",
            "port": old.get("port", mk.DEFAULT_PORT),
        }
        if old.get("tuya_port"):  # non-standard device port (testing / port forwarding)
            cfg["tuya_port"] = old["tuya_port"]
        dps = None
        while dps is None:
            dps = connect_test(cfg, version)
            if dps is None:
                if not yes("Change the IP / key and try again?", True):
                    sys.exit(1)
                cfg["ip"] = ask("Kettle IP address", cfg["ip"])
                if yes("Re-enter the local key?", False):
                    cfg["local_key"] = ask("Local Key", secret=True)

        previous = old.get("roles") if old.get("device_id") == cfg["device_id"] else None
        cfg["roles"] = map_datapoints(cfg, dps, mapping, previous)
        if mapping:
            cfg["mapping"] = mapping

        header("Step 5", "Presets and name")
        ts = cfg["roles"].get("temp_set", {})
        if ts.get("type") == "Enum" and ts.get("range"):
            boil = [r for r in ts["range"]]
            ok(f"Boil temperatures come from the kettle: {', '.join(boil)}")
        else:
            boil = old.get("boil_presets", mk.DEFAULT_BOIL_PRESETS)
            v = ask("Quick-pick boil temperatures (°C, comma separated)", ",".join(map(str, boil)))
            boil = [int(x) for x in v.replace(" ", "").split(",") if x.isdigit()]
        cfg["boil_presets"] = boil
        warm = old.get("warm_presets", mk.DEFAULT_WARM_PRESETS)
        if "keep_warm" in cfg["roles"] or "keep_warm_temp" in cfg["roles"]:
            v = ask("Quick-pick keep-warm temperatures (°C)", ",".join(map(str, warm)))
            warm = [int(x) for x in v.replace(" ", "").split(",") if x.isdigit()]
        cfg["warm_presets"] = warm
        cfg["name"] = ask("Name shown in the widget", cfg["name"])
        if dev.get("_cloud"):
            cfg["cloud"] = dev["_cloud"]

        verify_power(cfg)

        header("Step 6", "Save and start")
        mk.save_config(cfg)
        ok(f"Saved to {mk.CONFIG_FILE} (readable only by you)")
        stopped_service = False
        if mk.systemctl("enable", "--now", mk.SERVICE) == 0:
            mk.systemctl("restart", mk.SERVICE)
            time.sleep(2)
            if mk.service_running():
                s = mk.service_call("/api/status")
                for _ in range(8):
                    if s.get("connected"):
                        break
                    time.sleep(1)
                    s = mk.service_call("/api/status")
                if s.get("connected"):
                    ok("Background service is running and connected to the kettle.")
                else:
                    warn(f"Service is running but not connected yet ({s.get('error')}). It keeps retrying.")
            else:
                warn("Service did not start - check:  journalctl --user -u mykettle -e")
        else:
            warn("Could not start the systemd user service. You can run it by hand:  mykettle serve")

        print(f"""
{G}{B}  All done!{N}
{wrap(f'''
Add the widget: right-click your panel or desktop > {B}Add or Manage Widgets…{N} >
search for {B}MyKettle{N} and drag it where you want it. If it was already added,
it picks up the new settings within a few seconds.

Useful commands:
   mykettle status        show the current state
   mykettle set power on  start heating
   mykettle doctor        check everything
   mykettle setup         run this wizard again''')}
""")
    except (KeyboardInterrupt, EOFError):
        print(f"\n  {Y}Setup cancelled - nothing was changed.{N}")
    finally:
        if stopped_service:
            mk.systemctl("start", mk.SERVICE)
    if TTY and os.environ.get("MYKETTLE_FROM_WIDGET"):
        pause("Press Enter to close this window")


if __name__ == "__main__":
    main()
