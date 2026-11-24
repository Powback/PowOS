#!/usr/bin/env python3
"""waypipe-window.py CLIENT_LOG NET_JSON APP MODE: one app's numbers from the phone's waypipe client (waypipe-window.sh).

CLIENT_LOG = `waypipe --debug client` on the phone (waypipe 0.11 is not libwayland, so WAYLAND_DEBUG does nothing; its
--debug prints every message it processes, with the phone's wall clock mod 100 s in µs: "[SS.uuuuuu dbg ...]
Processing event: wl_keyboard#N.key(serial:u, time:u, key:u, state:u)"). These are client-side stamps: a key event as
it arrives from KWin, a request as waypipe writes it to KWin - the phone-side twin of §8.2's sway WAYLAND_DEBUG=server.
NET_JSON = the check's samples: {"phases": {name: [t0, t1] (phone epoch s)}, "ss": {name: {bytes_acked, ...}}, ...}.

Prints one JSON line: key->commit p50/p95/max ms (a pressed key -> the first wl_surface.commit with damage after it,
before the next key), scroll fps (damaged commits/s on the busiest surface in the scroll phase), frame gap p95/max,
stalls > 100 ms, bytes per phase (KB/s, MB/s), retransmits, buffer path (dmabuf / shm: which buffer requests the
client sent KWin, and whether KWin advertised zwp_linux_dmabuf_v1), and the §8.2 bar verdict.
"""
import json
import re
import sys

LINE = re.compile(r"^\[(\d+)\.(\d{6}) (\w+) ([^\]]*)\] (.*)$")
MSG = re.compile(r"Processing (event|request): (\w+)#(\d+)\.(\w+)\((.*)\)$")


def pct(v, p):
    if not v:
        return None
    s = sorted(v)
    return round(s[min(len(s) - 1, int(round(p / 100 * (len(s) - 1))))], 1)


def parse(path):
    """(t_abs_s, kind, iface, obj, method, args, level, text) with the mod-100 s clock unwrapped."""
    out, base, last = [], 0.0, None
    with open(path, errors="replace") as f:
        for ln in f:
            m = LINE.match(ln.rstrip("\n"))
            if not m:
                continue
            t = int(m.group(1)) + int(m.group(2)) / 1e6
            if last is not None and t + 50 < last:
                base += 100.0
            last = t
            mm = MSG.search(m.group(5))
            if mm:
                out.append((base + t, mm.group(1), mm.group(2), mm.group(3), mm.group(4), mm.group(5), m.group(3), ""))
            else:
                out.append((base + t, "log", "", "", "", "", m.group(3), m.group(5)))
    return out


def analyze(msgs, net, app, mode):
    keys, commits, damaged = [], [], set()
    dmabuf_global = dmabuf_bufs = shm_bufs = 0
    warn = []
    for t, kind, iface, obj, meth, args, lvl, text in msgs:
        if kind == "log":
            if lvl in ("Wrn", "ERR") and len(warn) < 8:
                warn.append(text[:200])
            continue
        if kind == "event" and iface == "wl_keyboard" and meth == "key":
            a = [x.split(":")[0].strip() for x in args.split(",")]
            if len(a) >= 4 and a[3] == "1":
                keys.append((t, int(a[2])))
        elif kind == "event" and iface == "wl_registry" and meth == "global" and "zwp_linux_dmabuf_v1" in args:
            dmabuf_global = 1
        elif kind == "request" and iface == "wl_surface" and meth in ("damage", "damage_buffer"):
            damaged.add(obj)
        elif kind == "request" and iface == "wl_surface" and meth == "commit":
            if obj in damaged:
                commits.append((t, obj))
                damaged.discard(obj)
        elif kind == "request" and iface == "zwp_linux_buffer_params_v1" and meth in ("create", "create_immed"):
            dmabuf_bufs += 1
        elif kind == "request" and iface == "wl_shm_pool" and meth == "create_buffer":
            shm_bufs += 1
    # The phases come from the keys themselves (the phone's clock): typing = letters, scroll = from the first
    # DOWN/F8 press for the scroll's length. KEY_DOWN 108, KEY_F8 66.
    scroll_keys = [t for t, k in keys if k in (108, 66)]
    typing = [(t, k) for t, k in keys if k not in (108, 66, 67)]
    lat = []
    ci = 0
    for i, (t, _) in enumerate(typing):
        nxt = typing[i + 1][0] if i + 1 < len(typing) else t + 1.0
        while ci < len(commits) and commits[ci][0] < t:
            ci += 1
        if ci < len(commits) and commits[ci][0] < nxt:
            lat.append((commits[ci][0] - t) * 1000)
    r = {"app": app, "mode": mode, "keys_typed": len(typing), "keys_with_frame": len(lat),
         "key_p50": pct(lat, 50), "key_p95": pct(lat, 95), "key_max": round(max(lat), 1) if lat else None,
         "kwin_dmabuf_global": dmabuf_global, "dmabuf_buffers": dmabuf_bufs, "shm_buffers": shm_bufs,
         "buffers": "dmabuf" if dmabuf_bufs and not shm_bufs else "shm" if shm_bufs and not dmabuf_bufs else
         "both" if dmabuf_bufs else "none", "client_warnings": warn}
    ph = net.get("phases", {})
    sc = ph.get("scroll")
    if sc and scroll_keys:
        t0 = scroll_keys[0]
        t1 = t0 + (sc[1] - sc[0])
        per = {}
        for t, o in commits:
            if t0 <= t <= t1:
                per.setdefault(o, []).append(t)
        if per:
            ts = max(per.values(), key=len)
            gaps = [(b - a) * 1000 for a, b in zip(ts, ts[1:])]
            r.update(scroll_fps=round(len(ts) / (t1 - t0), 1), gap_p95=pct(gaps, 95),
                     gap_max=round(max(gaps), 1) if gaps else None, stalls=sum(1 for g in gaps if g > 100))
    allk = [x for x in lat if x > 100]
    r["stalls"] = r.get("stalls", 0) + len(allk)
    ss = net.get("ss", {})

    def rate(a, b, field, secs):
        try:
            return (ss[b][field] - ss[a][field]) / secs
        except (KeyError, TypeError, ZeroDivisionError):
            return None
    for name, a, b in (("idle", "idle0", "idle1"), ("typing", "typing0", "typing1"), ("scroll", "scroll0", "scroll1")):
        p = ph.get(name)
        if not p:
            continue
        secs = max(p[1] - p[0], 0.001)
        up = rate(a, b, "bytes_acked", secs)
        down = rate(a, b, "bytes_received", secs)
        if up is not None and down is not None:
            r[f"{name}_KBps"] = round((up + down) / 1024, 1)
    if "scroll_KBps" in r:
        r["scroll_MBps"] = round(r["scroll_KBps"] / 1024, 2)
    try:
        r["retrans"] = ss["end"]["retrans_total"] - ss["start"]["retrans_total"]
        r["bytes_total_MB"] = round((ss["end"]["bytes_acked"] + ss["end"]["bytes_received"]) / 1e6, 2)
    except (KeyError, TypeError):
        pass
    r["rssi_dbm"] = net.get("rssi")
    r["link_mbps"] = net.get("link")
    # §8.2 bar: key->commit <= 30 ms p50 / <= 60 ms p95; idle and typing <= 1 MB/s; scroll >= 60 fps, gap p95 <= 33 ms,
    # <= 30 MB/s; no stall > 100 ms (no loss emulation here: the real Wi-Fi's own).
    miss = []
    if r["key_p50"] is None:
        miss.append("no key->frame samples")
    elif r["key_p50"] > 30 or (r["key_p95"] or 0) > 60:
        miss.append("latency")
    if any((r.get(f"{n}_KBps") or 0) > 1024 for n in ("idle", "typing")):
        miss.append("idle/typing bytes")
    if "scroll_fps" in r:
        if r["scroll_fps"] < 60 or (r["gap_p95"] or 0) > 33 or (r.get("scroll_MBps") or 0) > 30:
            miss.append("scroll")
    else:
        miss.append("no scroll samples")
    if r["stalls"]:
        miss.append("stalls")
    r["bar"] = "PASS" if not miss else "FAIL: " + ",".join(miss)
    return r


if __name__ == "__main__":
    log, netf, app, mode = sys.argv[1:5]
    try:
        net = json.load(open(netf))
    except (OSError, ValueError):
        net = {}
    print(json.dumps(analyze(parse(log), net, app, mode)))
