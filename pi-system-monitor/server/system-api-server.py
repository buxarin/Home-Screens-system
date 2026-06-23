#!/usr/bin/env python3
# =============================================================================
# System API for Home Screens  —  Pi System Monitor backend
#
#   GET /                  full JSON snapshot
#   GET /?field=system.cpu single field (plain text, backward-compatible)
#   GET /?ping=HOST        {"host","ok","ms"}  (ICMP, cached per PING_TTL)
#
# Pure stdlib + optional smbus for FanHat PWM% over I2C.
# All tunables can be overridden via environment variables in the systemd unit.
# =============================================================================
import json, os, re, time, subprocess, threading, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

# ── tunables ─────────────────────────────────────────────────────────────────
PORT         = int(os.environ.get("SYSTEM_API_PORT", "4000"))
VLESS_PORT   = int(os.environ.get("VLESS_PORT",      "8443"))
SOCKS_PORT   = int(os.environ.get("SOCKS_PORT",      "1080"))
FAN_SERVICE  = os.environ.get("FAN_SERVICE",  "fan_hat")
XRAY_SERVICE = os.environ.get("XRAY_SERVICE", "xray")
PCA9685_ADDR = int(os.environ.get("PCA9685_ADDR", "0x40"), 16)
PCA9685_BUS  = int(os.environ.get("PCA9685_BUS",  "1"))
SNAPSHOT_TTL = 2.0    # seconds; shared across clients
EXTIP_TTL    = 600.0  # external IP cached 10 min
PING_TTL     = 20.0   # ping result cached 20 s per host

_lock     = threading.Lock()
_snap     = {"data": None, "ts": 0.0}
_cpu_prev = {"idle": 0, "total": 0}
_extip    = {"ip": "N/A", "ts": 0.0}
_ping_cache: dict = {}


def sh(cmd, timeout=4) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout.strip()
    except Exception:
        return ""


# ── system metrics ────────────────────────────────────────────────────────────
def read_cpu() -> float:
    try:
        with open("/proc/stat") as f:
            parts = f.readline().split()[1:]
        vals = [int(x) for x in parts]
        idle  = vals[3] + (vals[4] if len(vals) > 4 else 0)
        total = sum(vals)
        di = idle  - _cpu_prev["idle"]
        dt = total - _cpu_prev["total"]
        _cpu_prev["idle"], _cpu_prev["total"] = idle, total
        return round((1 - di / dt) * 100, 1) if dt > 0 else 0.0
    except Exception:
        return 0.0


def read_mem():
    """Returns (total_mb, used_mb, free_mb, pct)"""
    info: dict = {}
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                k, _, v = line.partition(":")
                info[k] = int(v.strip().split()[0])  # kB
    except Exception:
        pass
    total = info.get("MemTotal", 0) // 1024
    avail = info.get("MemAvailable", 0) // 1024
    used  = max(0, total - avail)
    pct   = round(used * 100 / total, 1) if total else 0.0
    return total, used, avail, pct


def _human(nbytes: float) -> str:
    for unit in ("B", "K", "M", "G", "T"):
        if abs(nbytes) < 1024 or unit == "T":
            return f"{nbytes:.0f}{unit}" if unit == "B" else f"{nbytes:.1f}{unit}"
        nbytes /= 1024.0
    return f"{nbytes:.1f}T"


def read_disk():
    """Returns (total_str, used_str, free_str, pct)"""
    try:
        st    = os.statvfs("/")
        total = st.f_blocks * st.f_frsize
        free  = st.f_bavail * st.f_frsize
        used  = total - st.f_bfree * st.f_frsize
        pct   = round(used * 100 / total, 1) if total else 0.0
        return _human(total), _human(used), _human(free), pct
    except Exception:
        return "?", "?", "?", 0.0


def read_temp() -> float:
    try:
        with open("/sys/class/thermal/thermal_zone0/temp") as f:
            return round(int(f.read().strip()) / 1000.0, 1)
    except Exception:
        return 0.0


def read_uptime() -> str:
    try:
        with open("/proc/uptime") as f:
            secs = int(float(f.read().split()[0]))
        d, secs = divmod(secs, 86400)
        h, secs = divmod(secs, 3600)
        m = secs // 60
        parts = []
        if d: parts.append(f"{d}d")
        if h: parts.append(f"{h}h")
        parts.append(f"{m}m")
        return " ".join(parts)
    except Exception:
        return "N/A"


# ── FanHat ────────────────────────────────────────────────────────────────────
def service_active(name: str) -> bool:
    return sh(["systemctl", "is-active", name]) == "active"


def read_fan_pwm():
    """Read highest active PWM channel from PCA9685 over I2C. Returns float % or None."""
    try:
        import smbus
        bus  = smbus.SMBus(PCA9685_BUS)
        best = 0.0
        found = False
        for ch in range(16):
            base = 0x06 + 4 * ch
            data = bus.read_i2c_block_data(PCA9685_ADDR, base, 4)
            on   = ((data[1] & 0x0F) << 8) | data[0]
            off  = ((data[3] & 0x0F) << 8) | data[2]
            if data[1] & 0x10:
                duty = 100.0
            elif data[3] & 0x10:
                duty = 0.0
            else:
                duty = ((off - on) & 0x0FFF) / 4096.0 * 100.0
            found = True
            best  = max(best, duty)
        bus.close()
        return round(best, 0) if found else None
    except Exception:
        return None


# ── network ───────────────────────────────────────────────────────────────────
def read_adapters() -> list:
    """Returns list of {name, ipv4, ipv6, mac, up} dicts, skipping loopback."""
    raw = sh(["ip", "-j", "addr"])
    try:
        ifaces = json.loads(raw)
    except Exception:
        return []
    out = []
    for iface in ifaces:
        name = iface.get("ifname", "")
        if not name or name == "lo":
            continue
        ipv4 = ipv6 = ""
        for a in iface.get("addr_info", []):
            if a.get("family") == "inet" and not ipv4:
                ipv4 = a.get("local", "")
            elif a.get("family") == "inet6" and a.get("scope") == "global" and not ipv6:
                ipv6 = a.get("local", "")
        out.append({
            "name": name,
            "ipv4": ipv4,
            "ipv6": ipv6,
            "mac":  iface.get("address", ""),
            "up":   iface.get("operstate") == "UP",
        })
    return out


def read_external_ip() -> str:
    now = time.time()
    if now - _extip["ts"] < EXTIP_TTL and _extip["ip"] != "N/A":
        return _extip["ip"]
    ip = "N/A"
    for url in ("https://api.ipify.org", "https://ifconfig.me/ip"):
        try:
            with urllib.request.urlopen(url, timeout=5) as r:
                candidate = r.read().decode().strip()
                if candidate:
                    ip = candidate
                    break
        except Exception:
            continue
    _extip["ip"], _extip["ts"] = ip, now
    return ip


def read_wifi() -> str:
    s = sh(["iwgetid", "-r"])
    return s or "N/A"


# ── proxy (xray VLESS + SOCKS5) ───────────────────────────────────────────────
def read_proxy():
    """Returns (vless_dict, socks5_dict)"""
    running       = service_active(XRAY_SERVICE)
    listen_output = sh(["ss", "-Hltn"])
    listening_ports = set(re.findall(r":(\d+)\s", listen_output))
    estab = sh(["ss", "-Htn", "state", "established"])
    vless_peers: set = set()
    socks_peers: set = set()
    for line in estab.splitlines():
        cols = line.split()
        if len(cols) < 4:
            continue
        local = cols[-2]
        peer  = cols[-1]
        lport   = local.rsplit(":", 1)[-1]
        peer_ip = peer.rsplit(":", 1)[0]
        if lport == str(VLESS_PORT):
            vless_peers.add(peer_ip)
        elif lport == str(SOCKS_PORT):
            socks_peers.add(peer_ip)
    vless = {
        "running":      running,
        "port":         VLESS_PORT,
        "listening":    str(VLESS_PORT) in listening_ports,
        "client_count": len(vless_peers),
    }
    socks5 = {
        "running":      running,
        "port":         SOCKS_PORT,
        "listening":    str(SOCKS_PORT) in listening_ports,
        "client_count": len(socks_peers),
    }
    return vless, socks5


# ── snapshot ──────────────────────────────────────────────────────────────────
def build_snapshot() -> dict:
    cpu                       = read_cpu()
    total, used, avail, mpct  = read_mem()
    dtot, dused, dfree, dpct  = read_disk()
    fan_running               = service_active(FAN_SERVICE)
    vless, socks5             = read_proxy()
    return {
        "system": {
            "cpu":         cpu,
            "ram_used_mb": used,
            "ram_total_mb":total,
            "ram_free_mb": avail,
            "ram_pct":     mpct,
            "disk_used":   dused,
            "disk_total":  dtot,
            "disk_free":   dfree,
            "disk_pct":    dpct,
            "temp_c":      read_temp(),
            "uptime":      read_uptime(),
        },
        "fanhat": {
            "running": fan_running,
            "status":  "online" if fan_running else "offline",
            "pwm_pct": read_fan_pwm(),
            "rpm":     None,
        },
        "network": {
            "external_ip": read_external_ip(),
            "wifi_ssid":   read_wifi(),
            "adapters":    read_adapters(),
        },
        "vless":  vless,
        "socks5": socks5,
    }


def get_snapshot() -> dict:
    now = time.time()
    with _lock:
        if _snap["data"] is None or now - _snap["ts"] > SNAPSHOT_TTL:
            _snap["data"] = build_snapshot()
            _snap["ts"]   = now
        return _snap["data"]  # type: ignore[return-value]


# ── ping ──────────────────────────────────────────────────────────────────────
def get_ping(host: str) -> dict:
    host = host.strip()
    if not host or not re.match(r"^[A-Za-z0-9_.:\-]+$", host):
        return {"host": host, "ok": False, "ms": None}
    now = time.time()
    cached = _ping_cache.get(host)
    if cached and now - cached["ts"] < PING_TTL:
        return {"host": host, "ok": cached["ok"], "ms": cached["ms"]}
    ok, ms = False, None
    try:
        out = sh(["ping", "-c", "1", "-W", "2", host], timeout=5)
        m = re.search(r"time[=<]([\d.]+)\s*ms", out)
        if m:
            ok, ms = True, round(float(m.group(1)), 1)
    except Exception:
        pass
    _ping_cache[host] = {"ok": ok, "ms": ms, "ts": now}
    return {"host": host, "ok": ok, "ms": ms}


# ── backward-compat ?field= accessor ─────────────────────────────────────────
def get_field(field: str, snap: dict) -> str:
    s, fh, net = snap["system"], snap["fanhat"], snap["network"]
    table = {
        "system.cpu":        f'{s["cpu"]}%',
        "system.ram_used":   f'{s["ram_used_mb"]}MB',
        "system.ram_total":  f'{s["ram_total_mb"]}MB',
        "system.ram_free":   f'{s["ram_free_mb"]}MB',
        "system.ram_pct":    f'{s["ram_pct"]}%',
        "system.disk_used":  s["disk_used"],
        "system.disk_total": s["disk_total"],
        "system.disk_pct":   f'{s["disk_pct"]}%',
        "system.temp":       f'{s["temp_c"]}°C',
        "system.uptime":     s["uptime"],
        "fan.status":        fh["status"],
        "fan.pwm":           "n/a" if fh["pwm_pct"] is None else f'{fh["pwm_pct"]}%',
        "network.external_ip": net["external_ip"],
        "network.wifi_ssid":   net["wifi_ssid"],
        "vless.status":        "online" if snap["vless"]["running"] else "offline",
        "vless.client_count":  str(snap["vless"]["client_count"]),
        "socks5.status":       "online" if snap["socks5"]["running"] else "offline",
        "socks5.client_count": str(snap["socks5"]["client_count"]),
    }
    return table.get(field, f"Unknown field: {field}")


# ── HTTP handler ──────────────────────────────────────────────────────────────
class Handler(BaseHTTPRequestHandler):
    def _send(self, body: str, ctype: str = "application/json") -> None:
        data = body.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", ctype + ("; charset=utf-8" if "text" in ctype else ""))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_OPTIONS(self) -> None:
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.end_headers()

    def do_GET(self) -> None:
        q = parse_qs(urlparse(self.path).query)
        try:
            if "ping" in q:
                self._send(json.dumps(get_ping(q["ping"][0])))
                return
            snap = get_snapshot()
            if "field" in q:
                self._send(get_field(q["field"][0], snap), "text/plain")
                return
            self._send(json.dumps(snap))
        except Exception as e:
            self._send(json.dumps({"error": str(e)}))

    def log_message(self, *_):
        pass


if __name__ == "__main__":
    read_cpu()  # prime CPU delta baseline
    print(f"System API listening on 0.0.0.0:{PORT}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
