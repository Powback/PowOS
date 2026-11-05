#!/usr/bin/env python3
# bf-lprof.py <installdir> <t0 (epoch s)> <stopfile> [game log]: (on the phone, in the session; bf-coldstart-phone.sh
# starts it at the tap) where a game's launch time goes between its exe and its first frame, read-only, 4 Hz from /proc
# and sysfs until <stopfile> exists (or 150 s). Per sample of the game's process (a command line running a file from
# common/<installdir>/ under Wine or FEX, not a launch wrapper): every thread's CPU (utime+stime) and the process's
# file reads (/proc/pid/io rchar, read_bytes = from storage, not the page cache); the whole phone's CPU busy share
# (/proc/stat) and each cpufreq policy's clock. A [game log] (a path the session sees) is tailed: each new line
# stamped with the sample time it appeared at. Prints, ms from the tap:
#   LPROF <ms> game <cpu% of one core> rd <MB rchar> io <MB read_bytes> sys <busy % all cores> mhz <policy clocks> | <top threads %> || <top other processes %>
#   LPROF-LOG <ms> <game log line>
#   LPROF-OTHERS <process core-s ...>  the busiest other processes over the same span (wineserver, Xwayland, ...)
#   LPROF-SUM exe..frame: game <core-seconds> on <s> wall; threads <name core-s ...>; read <MB> (<MB> from storage)
import os, sys, time

idir, t0, stop = sys.argv[1], float(sys.argv[2]), sys.argv[3]
ulog = sys.argv[4] if len(sys.argv) > 4 else ""
HZ = os.sysconf("SC_CLK_TCK")
WRAP = ("proton", "reaper", "python", "pressure-vessel", "steam-launch-wrapper", "unity-screen", "entry-point",
        "steam-runtime", "steam.exe", "SteamLaunch")


def rd(p):
    try:
        with open(p, "rb") as f:
            return f.read()
    except OSError:
        return b""


def game_pid():
    keys = (("common/%s/" % idir).encode(), ("common\\%s\\" % idir).encode())
    for p in os.listdir("/proc"):
        if not p.isdigit():
            continue
        c = rd("/proc/%s/cmdline" % p).replace(b"\0", b" ")
        if not any(k in c for k in keys) or any(w.encode() in c for w in WRAP):
            continue
        try:
            x = os.readlink("/proc/%s/exe" % p)
        except OSError:
            continue
        if "FEX" in x or "wine" in x:
            return p
    return None


def threads(pid):
    out = {}
    try:
        tids = os.listdir("/proc/%s/task" % pid)
    except OSError:
        return out
    for t in tids:
        s = rd("/proc/%s/task/%s/stat" % (pid, t)).decode(errors="replace")
        if not s:
            continue
        name = s[s.find("(") + 1:s.rfind(")")]
        f = s[s.rfind(")") + 2:].split()
        out[t] = (name, int(f[11]) + int(f[12]))
    return out


def io(pid):
    d = {}
    for ln in rd("/proc/%s/io" % pid).decode().splitlines():
        k, _, v = ln.partition(":")
        d[k] = int(v or 0)
    return d.get("rchar", 0), d.get("read_bytes", 0)


def sysbusy():
    f = [int(x) for x in rd("/proc/stat").split(b"\n", 1)[0].split()[1:]]
    idle = f[3] + f[4]
    return sum(f), idle


def procs():  # every process's cpu ticks and name: what else runs beside the game (wineserver, Xwayland, KWin...)
    out = {}
    for p in os.listdir("/proc"):
        if p.isdigit():
            s = rd("/proc/%s/stat" % p).decode(errors="replace")
            if s:
                f = s[s.rfind(")") + 2:].split()
                out[p] = (s[s.find("(") + 1:s.rfind(")")], int(f[11]) + int(f[12]))
    return out


def clocks():
    base, r = "/sys/devices/system/cpu/cpufreq", []
    try:
        pols = sorted(os.listdir(base), key=lambda s: int(s[6:]) if s[6:].isdigit() else 0)
    except OSError:
        return "-"
    for p in pols:
        c = rd("%s/%s/scaling_cur_freq" % (base, p)).strip()
        r.append(str(int(c) // 1000) if c.isdigit() else "?")
    return "/".join(r)


pid, prev, pio, psys, ptime, upos = None, {}, None, sysbusy(), time.time(), 0
pprev, others = procs(), {}
first = None
total, wall0, wall1, tot_thr = 0, None, None, {}
rd0 = None
while not os.path.exists(stop) and time.time() - t0 < 150:
    time.sleep(0.25)
    now = time.time()
    ms = int((now - t0) * 1000)
    s = sysbusy()
    dt_all, di = s[0] - psys[0], s[1] - psys[1]
    busy = 100 * (dt_all - di) / dt_all if dt_all else 0
    psys = s
    if pid is None or not os.path.isdir("/proc/%s" % pid):
        pid, prev, pio = game_pid(), {}, None
    pnow = procs()
    od = sorted(((v - pprev.get(q, (n, v))[1], n) for q, (n, v) in pnow.items() if q != pid), reverse=True)
    pprev = pnow
    if ulog:
        try:
            with open(ulog, "rb") as f:
                f.seek(upos)
                chunk = f.read()
            nl = chunk.rfind(b"\n")
            if nl >= 0:
                upos += nl + 1
                for ln in chunk[:nl].decode(errors="replace").splitlines():
                    ln = ln.strip()
                    if ln:
                        print("LPROF-LOG %d %s" % (ms, ln[:150]), flush=True)
        except OSError:
            pass
    if pid is None:
        continue
    th, (rc, rb) = threads(pid), io(pid)
    dt = now - ptime
    ptime = now
    if pio is None:
        pio, prev = (rc, rb), th
        rd0 = rd0 or (rc, rb)
        wall0 = wall0 or now
        continue
    deltas = []
    for t, (name, v) in th.items():
        d = v - prev.get(t, (name, v))[1]
        if d > 0:
            deltas.append((d, name))
            tot_thr[name] = tot_thr.get(name, 0) + d
    prev = th
    g = sum(d for d, _ in deltas)
    total += g
    wall1 = now
    deltas.sort(reverse=True)
    top = " ".join("%s:%d" % (n.replace(" ", "_"), 100 * d / HZ / dt) for d, n in deltas[:4])
    for d, n in od:
        others[n] = others.get(n, 0) + d
    top += " || " + " ".join("%s:%d" % (n.replace(" ", "_"), 100 * d / HZ / dt) for d, n in od[:3] if d > 0)
    print("LPROF %d game %d rd %.1f io %.1f sys %d mhz %s thr %d | %s" % (
        ms, 100 * g / HZ / dt, (rc - rd0[0]) / 1e6, (rb - rd0[1]) / 1e6, busy, clocks(), len(th), top), flush=True)
if wall0 and wall1:
    rc, rb = io(pid) if pid else (0, 0)
    tops = sorted(((v, n) for n, v in tot_thr.items()), reverse=True)[:8]
    print("LPROF-SUM game %.1f core-s on %.1f s wall; threads %s; read %.0f MB (%.0f MB from storage)" % (
        total / HZ, wall1 - wall0, " ".join("%s=%.1f" % (n.replace(" ", "_"), v / HZ) for v, n in tops),
        (rc - rd0[0]) / 1e6, (rb - rd0[1]) / 1e6), flush=True)
    print("LPROF-OTHERS %s" % " ".join("%s=%.1f" % (n.replace(" ", "_"), v / HZ) for n, v in sorted(
        others.items(), key=lambda kv: -kv[1])[:8]), flush=True)
