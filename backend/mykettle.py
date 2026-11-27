#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Tony Ayre <me@tonyayre.net>
# SPDX-License-Identifier: GPL-3.0-or-later
"""
MyKettle backend - local control of a Tuya / SETTI+ smart kettle.

Runs as a small user service that keeps a persistent LAN connection to the
kettle (via tinytuya) and exposes a tiny JSON API on 127.0.0.1 for the KDE
Plasma widget.

Subcommands
    serve            run the service (used by systemd --user)
    status           print the kettle state
    set ROLE VALUE   change something, e.g. `set power on`, `set temp_set 80`
    setup            interactive setup wizard (keys, IP, data-point mapping)
    scan             look for Tuya devices on the local network
    learn            watch the kettle and print every data point that changes
    doctor           check the installation and print hints
    about            version, copyright, third-party libraries and licences
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import queue
import shutil
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

__version__ = "0.1.2"

APP = "mykettle"
CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / APP
CONFIG_FILE = CONFIG_DIR / "config.json"
DEFAULT_PORT = 8765
SERVICE = "mykettle.service"

log = logging.getLogger(APP)

# --------------------------------------------------------------------------
# Roles: the things the widget knows how to show / control.
# Each role is bound to one Tuya data point (DP) in the config file.
# --------------------------------------------------------------------------
ROLES: dict[str, dict] = {
    "power":          {"label": "Heating on/off (boil/start)", "types": ["Boolean"], "writable": True},
    "temp_current":   {"label": "Current water temperature",   "types": ["Integer"], "writable": False},
    "temp_set":       {"label": "Target temperature",          "types": ["Integer", "Enum"], "writable": True},
    "keep_warm":      {"label": "Keep-warm on/off",            "types": ["Boolean"], "writable": True},
    "keep_warm_temp": {"label": "Keep-warm temperature",       "types": ["Integer", "Enum"], "writable": True},
    "warm_time":      {"label": "Keep-warm duration",          "types": ["Integer", "Enum"], "writable": True},
    "mode":           {"label": "Work mode",                   "types": ["Enum"], "writable": True},
    "status":         {"label": "Work status (read only)",     "types": ["Enum", "String"], "writable": False},
    "remaining":      {"label": "Time remaining",              "types": ["Integer"], "writable": False},
    "fault":          {"label": "Fault / alarm",               "types": ["Bitmap", "Integer", "Enum", "Fault"], "writable": False},
}

# Known Tuya "code" names for each role (exact matches first, then substrings).
CODE_HINTS: dict[str, list[str]] = {
    "power":          ["switch", "start", "switch_boil", "boil", "switch_1", "power", "heat_switch"],
    "temp_current":   ["temp_current", "cur_temp", "temp_cur", "water_temp", "temp_current_c", "temperature"],
    "temp_set":       ["temp_set", "temp_boiling_c", "temp_setting", "set_temp", "target_temp", "temp_set_c", "temp_boil"],
    "keep_warm":      ["switch_keep_warm", "keep_warm", "warm_switch", "keep_warm_switch", "switch_warm", "insulation"],
    "keep_warm_temp": ["temp_keep_warm", "keep_warm_temp", "warm_temp", "temp_warm", "warm_temp_set"],
    "warm_time":      ["warm_time", "keep_warm_time", "warm_duration", "keep_time"],
    "mode":           ["work_type", "work_mode", "mode"],
    "status":         ["status", "work_state", "work_status", "state"],
    "remaining":      ["remain_time", "countdown_left", "remaining_time"],
    "fault":          ["fault", "alarm", "error"],
}

# Defaults taken from the GÖTZE & JENSEN KT975K manual.
DEFAULT_BOIL_PRESETS = [40, 55, 80, 90, 100]
DEFAULT_WARM_PRESETS = [40, 55, 80, 90]


# --------------------------------------------------------------------------
# Config helpers
# --------------------------------------------------------------------------
def load_config() -> dict | None:
    try:
        with open(CONFIG_FILE, encoding="utf-8") as fh:
            return json.load(fh)
    except FileNotFoundError:
        return None


def save_config(cfg: dict) -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(CONFIG_DIR, 0o700)
    tmp = CONFIG_FILE.with_suffix(".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(cfg, fh, indent=2, ensure_ascii=False)
    os.replace(tmp, CONFIG_FILE)


def config_ready(cfg: dict | None) -> bool:
    return bool(cfg and cfg.get("device_id") and cfg.get("local_key") and cfg.get("roles", {}).get("power"))


def normalise_values(values) -> dict:
    """Tuya mapping 'values' may be a JSON string or a dict."""
    if isinstance(values, str):
        try:
            values = json.loads(values)
        except ValueError:
            return {}
    return values if isinstance(values, dict) else {}


def spec_from_mapping(dp: str, m: dict) -> dict:
    """Turn a tinytuya cloud mapping entry into a role spec."""
    v = normalise_values(m.get("values"))
    spec = {"dp": str(dp), "type": m.get("type", "Integer"), "code": m.get("code", "")}
    for k in ("min", "max", "step", "scale", "unit"):
        if k in v:
            spec[k] = v[k]
    if "range" in v:
        spec["range"] = [str(x) for x in v["range"]]
    if spec["type"] == "Enum" and "range" not in spec:
        spec["range"] = []
    return spec


def auto_map_roles(mapping: dict) -> dict:
    """Guess role -> DP from the Tuya cloud DP mapping (code names)."""
    roles: dict[str, dict] = {}
    used: set[str] = set()
    items = [(str(dp), m) for dp, m in mapping.items() if isinstance(m, dict)]

    def ok_type(role, m):
        t = m.get("type", "")
        return t in ROLES[role]["types"] or (role == "fault" and t)

    for role, hints in CODE_HINTS.items():
        found = None
        # pass 1: exact code match, in hint priority order
        for hint in hints:
            for dp, m in items:
                if dp not in used and m.get("code", "").lower() == hint and ok_type(role, m):
                    found = (dp, m)
                    break
            if found:
                break
        # pass 2: substring match, avoid Fahrenheit duplicates
        if not found:
            for hint in hints:
                for dp, m in items:
                    code = m.get("code", "").lower()
                    if dp in used or code.endswith("_f") or not ok_type(role, m):
                        continue
                    if hint in code:
                        found = (dp, m)
                        break
                if found:
                    break
        if found:
            used.add(found[0])
            roles[role] = spec_from_mapping(found[0], found[1])
    return roles


def guess_roles_from_values(dps: dict) -> dict:
    """Very rough guess when no cloud mapping is available."""
    roles: dict[str, dict] = {}
    keys = sorted(dps.keys(), key=lambda k: int(k) if str(k).isdigit() else 9999)
    bools = [k for k in keys if isinstance(dps[k], bool)]
    ints = [k for k in keys if isinstance(dps[k], int) and not isinstance(dps[k], bool)]
    if bools:
        roles["power"] = {"dp": bools[0], "type": "Boolean"}
    temps = [k for k in ints if 0 <= dps[k] <= 110]
    if temps:
        # cold water is usually the lowest reading; a target is usually 40-100 in steps of 5
        cur = min(temps, key=lambda k: dps[k])
        roles["temp_current"] = {"dp": cur, "type": "Integer", "min": 0, "max": 100, "scale": 0, "unit": "°C"}
        targets = [k for k in temps if k != cur and 40 <= dps[k] <= 100 and dps[k] % 5 == 0]
        if targets:
            roles["temp_set"] = {"dp": targets[0], "type": "Integer", "min": 40, "max": 100, "step": 5,
                                 "scale": 0, "unit": "°C"}
    if len(bools) > 1:
        roles["keep_warm"] = {"dp": bools[1], "type": "Boolean"}
    return roles


# --------------------------------------------------------------------------
# Value conversion between "nice" values and raw Tuya values
# --------------------------------------------------------------------------
def to_display(spec: dict, raw):
    if raw is None:
        return None
    if spec.get("type") == "Integer" and isinstance(raw, (int, float)) and not isinstance(raw, bool):
        scale = int(spec.get("scale", 0) or 0)
        return raw / (10 ** scale) if scale else raw
    return raw


def to_raw(spec: dict, value):
    t = spec.get("type")
    if t == "Boolean":
        if isinstance(value, str):
            value = value.strip().lower() in ("1", "true", "on", "yes", "start")
        return bool(value)
    if t == "Integer":
        v = float(value)
        scale = int(spec.get("scale", 0) or 0)
        raw = int(round(v * (10 ** scale)))
        if "min" in spec:
            raw = max(int(spec["min"]), raw)
        if "max" in spec:
            raw = min(int(spec["max"]), raw)
        return raw
    if t == "Enum":
        value = str(value)
        rng = spec.get("range") or []
        if rng and value not in rng:
            # allow "80" to match "80" / "temp_80" style enums
            matches = [r for r in rng if r.endswith(str(value)) or str(value) in r]
            if len(matches) == 1:
                return matches[0]
            raise ValueError(f"'{value}' is not one of {rng}")
        return value
    return value


# --------------------------------------------------------------------------
# Kettle connection (one background thread owns the tinytuya socket)
# --------------------------------------------------------------------------
class Kettle:
    HEARTBEAT = 9          # seconds between heartbeats
    FULL_POLL = 30         # seconds between full status queries
    STALE = 35             # reconnect if nothing received for this long

    def __init__(self, cfg: dict | None):
        self.cfg = cfg or {}
        self.lock = threading.Lock()
        self.dps: dict = {}
        self.connected = False
        self.error: str | None = None if config_ready(cfg) else "not_configured"
        self.updated: float | None = None
        self.cmdq: queue.Queue = queue.Queue()
        self.stop_evt = threading.Event()
        self.thread: threading.Thread | None = None

    # -- lifecycle --------------------------------------------------------
    def start(self):
        if not config_ready(self.cfg):
            return
        self.stop_evt.clear()
        self.thread = threading.Thread(target=self._run, name="kettle", daemon=True)
        self.thread.start()

    def stop(self):
        self.stop_evt.set()
        if self.thread:
            self.thread.join(timeout=5)

    # -- public api -------------------------------------------------------
    def snapshot(self) -> dict:
        with self.lock:
            dps = dict(self.dps)
            connected, error, updated = self.connected, self.error, self.updated
        roles_out = {}
        for role, spec in self.cfg.get("roles", {}).items():
            out = {k: spec[k] for k in ("dp", "type", "min", "max", "step", "scale", "unit", "range") if k in spec}
            out["writable"] = ROLES.get(role, {}).get("writable", False)
            if spec.get("type") == "Integer":
                sc = 10 ** int(spec.get("scale", 0) or 0)
                for k in ("min", "max", "step"):
                    if k in spec and sc != 1:
                        out[k] = spec[k] / sc
            out["value"] = to_display(spec, dps.get(spec["dp"]))
            roles_out[role] = out
        return {
            "ok": True,
            "version": __version__,
            "configured": config_ready(self.cfg),
            "connected": connected,
            "error": error,
            "updated": updated,
            "name": self.cfg.get("name", "Kettle"),
            "roles": roles_out,
            "dps": dps,
            "boil_presets": self.cfg.get("boil_presets", DEFAULT_BOIL_PRESETS),
            "warm_presets": self.cfg.get("warm_presets", DEFAULT_WARM_PRESETS),
        }

    def queue_values(self, values: list[tuple[str, object]]) -> list[tuple[str, object]]:
        """values: ordered list of (role-or-dp, nice value). Returns raw pairs."""
        roles = self.cfg.get("roles", {})
        raw_pairs = []
        for key, value in values:
            if key in roles:
                spec = roles[key]
                if not ROLES.get(key, {}).get("writable", False):
                    raise ValueError(f"'{key}' is read only")
                raw_pairs.append((spec["dp"], to_raw(spec, value)))
            elif str(key).isdigit():
                raw_pairs.append((str(key), value))
            else:
                raise ValueError(f"unknown role or DP '{key}'")
        if not self.connected:
            raise RuntimeError("kettle is not connected")
        for dp, raw in raw_pairs:
            self.cmdq.put((dp, raw))
        with self.lock:  # optimistic update; the kettle will confirm
            for dp, raw in raw_pairs:
                self.dps[dp] = raw
        return raw_pairs

    # -- worker -----------------------------------------------------------
    def _make_device(self):
        import tinytuya
        c = self.cfg
        ip = c.get("ip") or "Auto"
        d = tinytuya.Device(c["device_id"], address=ip, local_key=c["local_key"],
                            version=float(c.get("version", 3.3)), persist=True,
                            connection_timeout=5, connection_retry_limit=2,
                            connection_retry_delay=2, port=int(c.get("tuya_port", 6668)))
        d.set_socketPersistent(True)
        return d

    def _merge(self, data) -> bool:
        if not isinstance(data, dict):
            return False
        dps = data.get("dps")
        if not dps and isinstance(data.get("data"), dict):
            dps = data["data"].get("dps")
        if not isinstance(dps, dict):
            return False
        with self.lock:
            self.dps.update({str(k): v for k, v in dps.items()})
            self.updated = time.time()
        return True

    def _set_state(self, connected: bool, error: str | None):
        with self.lock:
            self.connected, self.error = connected, error

    def _run(self):
        backoff = 2
        while not self.stop_evt.is_set():
            d = None
            try:
                d = self._make_device()
                d.set_socketTimeout(5)
                data = d.status()
                if not data or "Error" in data:
                    raise ConnectionError((data or {}).get("Error", "no response"))
                self._merge(data)
                self._set_state(True, None)
                log.info("connected to kettle, dps=%s", self.dps)
                backoff = 2
                d.set_socketTimeout(1)
                now = time.time()
                last_hb = last_full = last_rx = now
                while not self.stop_evt.is_set():
                    # 1. send queued commands
                    try:
                        while True:
                            dp, raw = self.cmdq.get_nowait()
                            log.info("set dp %s = %r", dp, raw)
                            d.set_value(int(dp) if dp.isdigit() else dp, raw, nowait=True)
                            last_hb = time.time()
                    except queue.Empty:
                        pass
                    now = time.time()
                    if now - last_full > self.FULL_POLL:
                        d.status(nowait=True)
                        last_full = last_hb = now
                    elif now - last_hb > self.HEARTBEAT:
                        d.heartbeat(nowait=True)
                        last_hb = now
                    # 2. read whatever the kettle pushes
                    data = d.receive()
                    if data is None:
                        if time.time() - last_rx > self.STALE:
                            raise ConnectionError("kettle stopped responding")
                        continue
                    if "Error" in data and str(data.get("Err")) != "902":
                        raise ConnectionError(data.get("Error"))
                    last_rx = time.time()
                    if self._merge(data):
                        log.debug("update %s", data)
            except Exception as exc:  # noqa: BLE001 - keep the service alive
                msg = friendly_error(str(exc) or exc.__class__.__name__)
                log.warning("connection problem: %s (retry in %ss)", msg, backoff)
                self._set_state(False, msg)
            finally:
                if d is not None:
                    try:
                        d.close()
                    except Exception:  # noqa: BLE001
                        pass
            self.stop_evt.wait(backoff)
            backoff = min(backoff * 2, 30)


def friendly_error(msg: str) -> str:
    low = msg.lower()
    if "unable to connect" in low or "timeout" in low or "no response" in low:
        return "kettle unreachable - is it plugged in and is the IP right?"
    if "key or version" in low or "decrypt" in low or "914" in low:
        return "wrong local key or protocol version - run 'mykettle setup'"
    if "unexpected payload" in low or "stopped responding" in low:
        return "connection to the kettle dropped - reconnecting"
    return msg


# --------------------------------------------------------------------------
# HTTP API (localhost only)
# --------------------------------------------------------------------------
class Api:
    def __init__(self, port: int):
        self.port = port
        self.kettle = Kettle(load_config())
        self.kettle.start()
        self.lock = threading.Lock()

    def reload(self):
        with self.lock:
            self.kettle.stop()
            self.kettle = Kettle(load_config())
            self.kettle.start()


def make_handler(api: Api):
    allowed_hosts = {f"127.0.0.1:{api.port}", f"localhost:{api.port}", f"[::1]:{api.port}"}

    class Handler(BaseHTTPRequestHandler):
        server_version = f"MyKettle/{__version__}"

        def log_message(self, fmt, *args):  # quieter logs
            log.debug("http: " + fmt, *args)

        def _send(self, code: int, obj):
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _guard(self, write: bool) -> bool:
            # Block DNS-rebinding and drive-by browser requests.
            if self.headers.get("Host", "") not in allowed_hosts:
                self._send(403, {"ok": False, "error": "bad host"})
                return False
            if write and self.headers.get("X-MyKettle") != "1":
                self._send(403, {"ok": False, "error": "missing X-MyKettle header"})
                return False
            return True

        def do_GET(self):  # noqa: N802
            if not self._guard(False):
                return
            if self.path in ("/api/status", "/"):
                self._send(200, api.kettle.snapshot())
            elif self.path == "/api/health":
                self._send(200, {"ok": True, "version": __version__})
            else:
                self._send(404, {"ok": False, "error": "not found"})

        def do_POST(self):  # noqa: N802
            if not self._guard(True):
                return
            try:
                n = int(self.headers.get("Content-Length", 0) or 0)
                body = json.loads(self.rfile.read(n) or b"{}") if n else {}
            except ValueError:
                return self._send(400, {"ok": False, "error": "invalid json"})
            try:
                if self.path == "/api/set":
                    if "values" in body:
                        pairs = list(body["values"].items())
                    else:
                        pairs = [(body.get("role") or body.get("dp"), body.get("value"))]
                    raw = api.kettle.queue_values(pairs)
                    return self._send(200, {"ok": True, "sent": raw})
                if self.path == "/api/reload":
                    api.reload()
                    return self._send(200, {"ok": True})
                return self._send(404, {"ok": False, "error": "not found"})
            except (ValueError, RuntimeError) as exc:
                return self._send(400, {"ok": False, "error": str(exc)})

    return Handler


def cmd_serve(args):
    cfg = load_config() or {}
    port = args.port or int(cfg.get("port", DEFAULT_PORT))
    api = Api(port)
    httpd = ThreadingHTTPServer(("127.0.0.1", port), make_handler(api))
    httpd.daemon_threads = True

    def bye(*_):
        threading.Thread(target=httpd.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, bye)
    signal.signal(signal.SIGINT, bye)
    signal.signal(signal.SIGHUP, lambda *_: api.reload())
    log.info("MyKettle %s listening on http://127.0.0.1:%d (configured=%s)",
             __version__, port, config_ready(cfg))
    httpd.serve_forever()
    api.kettle.stop()


# --------------------------------------------------------------------------
# Talking to the running service from the CLI
# --------------------------------------------------------------------------
def service_url(path: str) -> str:
    cfg = load_config() or {}
    return f"http://127.0.0.1:{int(cfg.get('port', DEFAULT_PORT))}{path}"


def service_call(path: str, body: dict | None = None, timeout=3):
    req = urllib.request.Request(service_url(path), method="POST" if body is not None else "GET",
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"X-MyKettle": "1", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        return json.loads(e.read() or b"{}")


def service_running() -> bool:
    try:
        return bool(service_call("/api/health", timeout=1).get("ok"))
    except (OSError, ValueError):
        return False


def systemctl(*args) -> int:
    if not shutil.which("systemctl"):
        return 1
    return subprocess.call(["systemctl", "--user", *args], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def direct_status(cfg: dict) -> dict:
    """One-shot status without the service (used by CLI and wizard)."""
    k = Kettle(cfg)
    d = k._make_device()
    d.set_socketPersistent(False)
    data = d.status()
    d.close()
    if not data or "Error" in data:
        raise ConnectionError((data or {}).get("Error", "no response"))
    k._merge(data)
    k.connected = True
    k.error = None
    return k.snapshot()


def print_state(s: dict):
    print(f"{s.get('name', 'Kettle')}: {'connected' if s.get('connected') else 'NOT connected'}"
          + (f" ({s['error']})" if s.get("error") else ""))
    for role, r in s.get("roles", {}).items():
        unit = r.get("unit", "")
        print(f"  {role:15} DP {r['dp']:>4}  = {r.get('value')!r} {unit}")
    mapped = {r["dp"] for r in s.get("roles", {}).values()}
    other = {k: v for k, v in s.get("dps", {}).items() if k not in mapped}
    if other:
        print("  other DPs:", json.dumps(other))


def cmd_status(args):
    cfg = load_config()
    if not config_ready(cfg):
        sys.exit("Not configured yet - run:  mykettle setup")
    if service_running():
        s = service_call("/api/status")
    else:
        s = direct_status(cfg)
    print(json.dumps(s, indent=2) if args.json else "", end="")
    if not args.json:
        print_state(s)


def parse_cli_value(v: str):
    low = v.lower()
    if low in ("on", "true", "yes", "start"):
        return True
    if low in ("off", "false", "no", "stop"):
        return False
    try:
        return int(v)
    except ValueError:
        try:
            return float(v)
        except ValueError:
            return v


def cmd_set(args):
    cfg = load_config()
    if not config_ready(cfg):
        sys.exit("Not configured yet - run:  mykettle setup")
    value = parse_cli_value(args.value)
    if service_running():
        r = service_call("/api/set", {"values": {args.key: value}})
        print(json.dumps(r))
        sys.exit(0 if r.get("ok") else 1)
    k = Kettle(cfg)
    k.connected = True
    pairs = k.queue_values([(args.key, value)])
    d = k._make_device()
    for dp, raw in pairs:
        print(d.set_value(int(dp), raw))
    d.close()


def cmd_scan(args):
    import tinytuya
    print("Scanning the local network for Tuya devices (about 20 seconds)...")
    found = tinytuya.deviceScan(verbose=False, color=False, poll=False, byID=True)
    if not found:
        print("No devices answered. Make sure the kettle is plugged in, on the same network/VLAN,"
              " and that UDP ports 6666/6667/7000 are not blocked by a firewall.")
    for dev_id, info in found.items():
        print(f"  {dev_id}  ip={info.get('ip')}  version={info.get('version')}  product={info.get('productKey')}")
    return found


def cmd_learn(args):
    cfg = load_config()
    if not cfg or not cfg.get("device_id"):
        sys.exit("Need at least device_id/local_key/ip in the config - run:  mykettle setup")
    stopped = service_running() and systemctl("stop", SERVICE) == 0
    try:
        learn_loop(cfg, args.seconds)
    finally:
        if stopped:
            systemctl("start", SERVICE)


def learn_loop(cfg: dict, seconds: int, quiet=False) -> dict:
    """Watch the kettle and return {dp: [values seen]} for DPs that changed."""
    k = Kettle(cfg)
    d = k._make_device()
    d.set_socketTimeout(5)
    first = d.status()
    if not first or "Error" in first:
        raise ConnectionError((first or {}).get("Error", "no response"))
    base = {str(a): b for a, b in first.get("dps", {}).items()}
    if not quiet:
        print("Current data points:", json.dumps(base))
        print(f"Watching for {seconds}s - change things on the kettle or in the phone app now...")
    changes: dict[str, list] = {}
    d.set_socketTimeout(1)
    end = time.time() + seconds
    last_hb = time.time()
    while time.time() < end:
        if time.time() - last_hb > 8:
            d.heartbeat(nowait=True)
            last_hb = time.time()
        data = d.receive()
        if not data or "dps" not in data:
            continue
        for dp, v in data["dps"].items():
            dp = str(dp)
            if base.get(dp) != v or dp not in base:
                changes.setdefault(dp, []).append(v)
                base[dp] = v
                if not quiet:
                    print(f"  DP {dp:>4} -> {v!r}")
    d.close()
    return changes


def cmd_doctor(args):
    ok = True

    def chk(cond, good, bad):
        nonlocal ok
        print(("  [ OK ] " + good) if cond else ("  [FAIL] " + bad))
        ok &= bool(cond)

    print(f"MyKettle {__version__} doctor")
    try:
        import tinytuya
        chk(True, f"tinytuya {tinytuya.__version__} available", "")
    except ImportError:
        chk(False, "", "tinytuya is missing - re-run install.sh")
    cfg = load_config()
    chk(cfg is not None, f"config file {CONFIG_FILE}", "no config file - run: mykettle setup")
    if cfg:
        chk(config_ready(cfg), "device id, local key and power DP present", "config incomplete - run: mykettle setup")
        mode = CONFIG_FILE.stat().st_mode & 0o777
        chk(mode == 0o600, "config file permissions are 600", f"config permissions are {oct(mode)} - run: chmod 600 {CONFIG_FILE}")
    run = service_running()
    chk(run, "service is running", "service not running - run: systemctl --user enable --now mykettle")
    if run:
        s = service_call("/api/status")
        chk(s.get("connected"), "service is connected to the kettle",
            f"service cannot reach the kettle: {s.get('error')}")
    kp = shutil.which("kpackagetool6")
    if kp:
        r = subprocess.run([kp, "-t", "Plasma/Applet", "-s", "org.kde.plasma.mykettle"], capture_output=True, text=True)
        chk(r.returncode == 0, "Plasma widget is installed", "Plasma widget not installed - re-run install.sh")
    sys.exit(0 if ok else 1)


# --------------------------------------------------------------------------
# About / third-party components and licences
# --------------------------------------------------------------------------
COPYRIGHT = "Copyright © 2026 Tony Ayre <me@tonyayre.net>"
LICENSE_NAME = "GPL-3.0-or-later"
LICENSE_FILES = ("LICENSE", "LICENCE", "COPYING", "NOTICE", "AUTHORS")

# Parts of the widget that come from the desktop itself (not bundled).
SYSTEM_COMPONENTS = [
    ("Python", "%d.%d.%d" % sys.version_info[:3], "PSF-2.0",
     "https://www.python.org", "runs the backend and wizard"),
    ("Qt 6 / Qt Quick", "system", "LGPL-3.0-only", "https://www.qt.io", "widget user interface"),
    ("KDE Frameworks (Kirigami, KCMUtils)", "system", "LGPL-2.1-or-later", "https://kde.org", "widget user interface"),
    ("KDE Plasma libraries", "system", "LGPL-2.0-or-later / GPL-2.0-or-later",
     "https://kde.org/plasma-desktop", "panel widget host (plasmoid, components, plasma5support)"),
]


def _dist_license(dist) -> str:
    md = dist.metadata
    lic = md.get("License-Expression") or ""
    if not lic:
        raw = (md.get("License") or "").strip()
        if raw and "\n" not in raw and len(raw) < 60:
            lic = raw
    if not lic:
        cls = [c.split("::")[-1].strip() for c in (md.get_all("Classifier") or []) if c.startswith("License ::")]
        lic = " / ".join(c for c in cls if c != "OSI Approved")
    return lic or "see licence file"


def _dist_url(dist) -> str:
    md = dist.metadata
    if md.get("Home-page"):
        return md["Home-page"]
    for entry in md.get_all("Project-URL") or []:
        label, _, url = entry.partition(",")
        if label.strip().lower() in ("homepage", "source", "source code", "repository", "github"):
            return url.strip()
    urls = [u.partition(",")[2].strip() for u in md.get_all("Project-URL") or []]
    urls = [u for u in urls if not any(x in u.lower() for x in ("change", "issue", "news", "release"))] or urls
    return urls[0] if urls else ""


def python_components(root: str = "tinytuya") -> list:
    """tinytuya plus everything it pulls in, read from the installed packages."""
    import re
    from importlib import metadata

    seen: dict[str, object] = {}
    parent: dict[str, str] = {}
    todo = [root]
    while todo:
        name = todo.pop(0)
        key = name.lower().replace("_", "-")
        if key in seen:
            continue
        try:
            dist = metadata.distribution(name)
        except metadata.PackageNotFoundError:
            continue
        seen[key] = dist
        for req in dist.requires or []:
            if "extra ==" in req:          # optional extras are not installed
                continue
            m = re.match(r"\s*([A-Za-z0-9][A-Za-z0-9._-]*)", req)
            if m:
                todo.append(m.group(1))
                parent.setdefault(m.group(1).lower().replace("_", "-"), dist.metadata["Name"])
    for key, dist in seen.items():
        dist.required_by = parent.get(key)
    return list(seen.values())


def components() -> list[dict]:
    """Every component, as dicts: name, version, license, url, role, dist/file."""
    here = Path(__file__).resolve().parent
    own_license = next((p for p in (here / "LICENSE", here.parent / "LICENSE") if p.exists()), None)
    out = [{"name": "MyKettle", "version": __version__, "license": LICENSE_NAME,
            "url": "", "role": COPYRIGHT, "file": own_license}]
    for d in python_components():
        name = d.metadata["Name"]
        out.append({"name": name, "version": d.version, "license": _dist_license(d), "url": _dist_url(d),
                    "role": "Tuya LAN protocol" if name.lower() == "tinytuya"
                    else f"required by {getattr(d, 'required_by', None) or 'tinytuya'}",
                    "dist": d})
    for name, ver, lic, url, role in SYSTEM_COMPONENTS:
        out.append({"name": name, "version": ver, "license": lic, "url": url, "role": role + " (provided by your system)"})
    return out


def license_text(comp: dict) -> str | None:
    if comp.get("file"):
        return Path(comp["file"]).read_text(encoding="utf-8", errors="replace")
    dist = comp.get("dist")
    if dist is None:
        return None
    texts = []
    for f in dist.files or []:
        base = f.name.upper()
        if any(base.startswith(n) for n in LICENSE_FILES):
            try:
                texts.append(f"===== {f} =====\n" + Path(dist.locate_file(f)).read_text(encoding="utf-8", errors="replace"))
            except OSError:
                pass
    return "\n\n".join(texts) or None


def print_components(comps: list[dict], bold="", dim="", reset="") -> None:
    print(f"\n  {bold}MyKettle {__version__}{reset}  {COPYRIGHT}")
    print(f"  Licensed under the GNU General Public License v3 or later; no warranty.\n")
    print(f"  {bold}{'#':>3}  {'Component':<36} {'Version':<10} Licence{reset}")
    for i, c in enumerate(comps, 1):
        print(f"  {i:>3}  {c['name'][:36]:<36} {str(c['version'])[:10]:<10} {c['license']}")
        detail = c["role"] + (f" - {c['url']}" if c.get("url") else "")
        print(f"       {dim}{detail}{reset}")
    print(f"\n  {dim}Tuya, Smart Life, SETTI+ and GÖTZE & JENSEN are trademarks of their owners;"
          f" MyKettle is not affiliated with them.{reset}")


def about_interactive(bold="", dim="", reset="") -> None:
    """List components; let the user open any licence text in a pager."""
    import pydoc
    comps = components()
    while True:
        print_components(comps, bold, dim, reset)
        if not sys.stdin.isatty():
            return
        v = input(f"\n  Type a number to read its licence text, or press Enter to go back: ").strip()
        if not v:
            return
        if v.isdigit() and 1 <= int(v) <= len(comps):
            c = comps[int(v) - 1]
            text = license_text(c)
            if text:
                pydoc.pager(f"{c['name']} {c['version']} - {c['license']}\n\n{text}")
            else:
                print(f"\n  {c['name']} is part of your system; its licence is {c['license']}."
                      + (f" See {c['url']}" if c.get("url") else ""))
                input(f"  {dim}Press Enter…{reset}")


def cmd_about(args):
    if args.license:
        comps = components()
        match = [c for c in comps if c["name"].lower() == args.license.lower()]
        text = license_text(match[0]) if match else None
        if not text:
            sys.exit(f"No licence text found for '{args.license}'.")
        print(text)
    elif args.json:
        comps = [{"name": c["name"], "version": str(c["version"]), "license": c["license"],
                  "url": c.get("url", ""), "role": c["role"],
                  "has_text": bool(c.get("file") or c.get("dist"))} for c in components()]
        print(json.dumps({"version": __version__, "copyright": COPYRIGHT,
                          "license": LICENSE_NAME, "components": comps}))
    else:
        about_interactive()


def cmd_setup(args):
    import setup_wizard
    setup_wizard.main()


def main(argv=None):
    p = argparse.ArgumentParser(prog=APP, description="Local control for Tuya / SETTI+ smart kettles")
    p.add_argument("-v", "--verbose", action="store_true")
    p.add_argument("--version", action="version", version=__version__)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("serve", help="run the background service")
    s.add_argument("--port", type=int)
    s.set_defaults(fn=cmd_serve)
    s = sub.add_parser("status", help="show kettle state")
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=cmd_status)
    s = sub.add_parser("set", help="set a role or DP, e.g. 'set power on', 'set temp_set 80', 'set 1 true'")
    s.add_argument("key")
    s.add_argument("value")
    s.set_defaults(fn=cmd_set)
    sub.add_parser("setup", help="interactive setup wizard").set_defaults(fn=cmd_setup)
    sub.add_parser("scan", help="scan the LAN for Tuya devices").set_defaults(fn=cmd_scan)
    s = sub.add_parser("learn", help="print data points as they change")
    s.add_argument("--seconds", type=int, default=60)
    s.set_defaults(fn=cmd_learn)
    sub.add_parser("doctor", help="check installation").set_defaults(fn=cmd_doctor)
    s = sub.add_parser("about", aliases=["licenses", "licences"],
                       help="version, copyright, third-party components and their licences")
    s.add_argument("--license", metavar="NAME", help="print the full licence text of one component")
    s.add_argument("--json", action="store_true", help="machine-readable list (used by the widget)")
    s.set_defaults(fn=cmd_about)
    args = p.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s")
    if not args.verbose:
        logging.getLogger("tinytuya").setLevel(logging.WARNING)
    try:
        args.fn(args)
    except KeyboardInterrupt:
        print()
        sys.exit(130)
    except (ConnectionError, OSError) as exc:
        sys.exit(f"Error: {exc}")


if __name__ == "__main__":
    main()
