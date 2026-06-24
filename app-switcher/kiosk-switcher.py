#!/usr/bin/env python3
"""
Kiosk App Switcher — system-level touch daemon.

Watches /dev/input for touch events. When the user taps the upper-right
corner of the screen, navigates Chromium to the other app via Chrome
DevTools Protocol (--remote-debugging-port=9222).

No browser JS injection needed — works regardless of what the app renders.
"""
import sys, os, time, json, glob, logging
import urllib.request

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s  %(levelname)-7s  %(message)s',
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger('kiosk-switcher')

HS_URL   = os.environ.get('HS_URL',   'http://localhost:8080/display')
HA_URL   = os.environ.get('HA_URL',   'http://localhost:8081')
CDP_HOST = os.environ.get('CDP_HOST', 'http://localhost:9222')

# Touch zone — single tap in the top-right corner triggers the switch
ZONE_X_FRAC = 0.82   # rightmost 18 % of screen width
ZONE_Y_FRAC = 0.14   # topmost   14 % of screen height
COOLDOWN    = 2.5    # minimum seconds between switches


# ── dependency check ──────────────────────────────────────────────────────────
try:
    import evdev
    from evdev import InputDevice, ecodes
except ImportError:
    log.error("Missing: python3-evdev  →  sudo apt-get install python3-evdev")
    sys.exit(1)

try:
    import websocket
except ImportError:
    log.error("Missing: python3-websocket  →  sudo apt-get install python3-websocket")
    sys.exit(1)


# ── touch device discovery ────────────────────────────────────────────────────
def find_touch_device():
    candidates = sorted(glob.glob('/dev/input/event*'))
    for path in candidates:
        try:
            dev  = InputDevice(path)
            caps = dev.capabilities()
            if ecodes.EV_ABS in caps:
                codes = [c for c, _ in caps[ecodes.EV_ABS]]
                if ecodes.ABS_MT_POSITION_X in codes or ecodes.ABS_X in codes:
                    log.info(f"Touch device: {path}  ({dev.name})")
                    return dev, caps
        except Exception:
            pass
    return None, None


def touch_range(caps):
    max_x, max_y = 1024, 600
    for code, info in caps.get(ecodes.EV_ABS, []):
        if   code in (ecodes.ABS_MT_POSITION_X, ecodes.ABS_X): max_x = info.max or max_x
        elif code in (ecodes.ABS_MT_POSITION_Y, ecodes.ABS_Y): max_y = info.max or max_y
    return max_x, max_y


# ── Chrome DevTools Protocol ──────────────────────────────────────────────────
def _cdp_page_ws():
    data = json.loads(urllib.request.urlopen(f'{CDP_HOST}/json', timeout=3).read())
    page = next((t for t in data if t.get('type') == 'page'), None)
    return page['webSocketDebuggerUrl'] if page else None


def cdp_navigate(url):
    try:
        ws_url = _cdp_page_ws()
        if not ws_url:
            log.warning("CDP: no page tab found")
            return
        ws = websocket.create_connection(ws_url, timeout=4)
        ws.send(json.dumps({"id": 1, "method": "Page.navigate", "params": {"url": url}}))
        ws.recv()
        ws.close()
        log.info(f"Navigated → {url}")
    except Exception as e:
        log.error(f"CDP navigate failed: {e}")


# ── main loop ─────────────────────────────────────────────────────────────────
def main():
    dev, caps = find_touch_device()
    if not dev:
        log.error("No touchscreen found in /dev/input — exiting")
        sys.exit(1)

    max_x, max_y = touch_range(caps)
    zone_x = int(max_x * ZONE_X_FRAC)
    zone_y = int(max_y * ZONE_Y_FRAC)
    log.info(f"Screen touch range : {max_x} × {max_y}")
    log.info(f"Switcher zone      : x > {zone_x}  AND  y < {zone_y}")
    log.info(f"Home Screens URL   : {HS_URL}")
    log.info(f"Home Assistant URL : {HA_URL}")

    last_switch  = 0.0
    cur_x = cur_y = 0
    in_zone      = False
    # Track which app is currently shown; start on HS (the default kiosk page)
    showing_ha   = False

    for event in dev.read_loop():
        t = event.type

        if t == ecodes.EV_ABS:
            c = event.code
            if   c in (ecodes.ABS_MT_POSITION_X, ecodes.ABS_X): cur_x = event.value
            elif c in (ecodes.ABS_MT_POSITION_Y, ecodes.ABS_Y): cur_y = event.value

        elif t == ecodes.EV_KEY and event.code == ecodes.BTN_TOUCH:
            if event.value == 1:   # touch down
                in_zone = (cur_x > zone_x and cur_y < zone_y)
                if in_zone:
                    log.debug(f"Touch in zone at ({cur_x},{cur_y})")

            elif event.value == 0 and in_zone:   # touch up — was in zone
                in_zone = False
                now = time.time()
                if (now - last_switch) < COOLDOWN:
                    log.debug("Cooldown — ignored")
                    continue
                last_switch = now
                # Toggle: internal state, no URL check needed
                if showing_ha:
                    target = HS_URL
                    showing_ha = False
                else:
                    target = HA_URL
                    showing_ha = True
                log.info(f"Switch! → {target}")
                cdp_navigate(target)


if __name__ == '__main__':
    main()
