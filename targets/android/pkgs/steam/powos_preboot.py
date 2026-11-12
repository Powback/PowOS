#!/usr/bin/env python3
# PowOS /usr/lib/powos-steam/py/powos_preboot.py: a game's Wine session booted while Steam prepares its launch, so the
# game joins a live session instead of booting one (docs/research/broforce-engine-init.md lever 1, 2026-11-12).
#
# HACK: Proton's `waitforexitandrun` (the verb Steam launches every game with) runs `wineserver -w` first, so a game
# can't join a session that is already up, and the first Wine process of a new session runs `wineboot --init`, which
# starts services.exe and waits for its serial autostart (winedevice, plugplay, svchost): ~1.5-2 s of every ARM64
# Proton launch (8-11 s under FEX), after Steam's own 2-5 s of prep in which nothing Wine-side happens.
# Real fix: Proton/Steam booting the prefix's session while the client prepares a launch (or a wineboot that doesn't
# serialise the autostart services) - then drop this file, the gate's join and /usr/bin/steam's `start` call.
#
# Off by default. On: POWOS_WINE_PREBOOT=1 (~/.config/powos/steam-env, or a check's env:) for every game, or per game
# `powos game <appid> preboot on|off|default` (steam-compat.json apps.<id>.preboot, beats the global switch).
#
# The pieces:
#   start <appid>  (/usr/bin/steam on a steam://rungameid/<id> forward, in the background): replays the environment of
#                  the game's last launch through the gate (snapshot, written by the gate) and runs, in Valve's own
#                  runtime + Proton, `proton runinprefix cmd.exe /c set /p ...` - the first Wine process boots the
#                  session (wineserver, wineboot --init, services); cmd then waits on its stdin, a pipe this keeper
#                  holds. That cmd is the session's "holder": a user process, so Wine doesn't shut the session down.
#                  Nobody claims it within IDLE_S -> the pipe is closed, cmd exits, Wine ends the session by itself.
#   claim  (the gate, arm64-gate-entry, on the game's waitforexitandrun): a live, unclaimed session for this prefix,
#                  booted by the same Proton with the same Wine-relevant environment -> claimed, and the game runs with
#                  Proton's `run` verb (joins it). Anything else -> the session is told to end, and the launch runs
#                  `waitforexitandrun` as always (which then waits for that end, as it waits for any older session).
#   release (the gate, after Proton's `run` returned = the game exited): the holder's pipe closed, the session ends as
#                  a waitforexitandrun one does (wineserver saves the registry, exits); the gate waits for that before it
#                  exits, so Steam's reaper still sees the launch end only after the prefix's wineserver is gone - the
#                  game's exit, the reaper and the cloud sync after it come in the same order as before.
# Teardown: idle timeout, a SIGTERM to the keeper (powos game <id> stop kills it: its environ has SteamAppId), the gate
# gone without releasing (claimed_by pid dead), or the holder dying.
import fcntl
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import time

GATE = "powos-proton-arm64"
IDLE_S = float(os.environ.get("POWOS_WINE_PREBOOT_IDLE_S", "90"))   # unclaimed: Steam's prep is 2-30 s (reconnect)
END_WAIT_S = float(os.environ.get("POWOS_WINE_PREBOOT_END_S", "30"))  # the session's own shutdown, then we stop waiting
HOLD = "POWOS_WINE_PREBOOT_HOLD"
# Environment the booted processes (services, winedevice, explorer) keep for the session's life: a launch whose value
# differs from the pre-boot's must not join it.
WINE_KEYS = re.compile(r"^(WINE|PROTON_|DXVK_|VKD3D|FEX_|TU_|MESA_|PRESSURE_VESSEL_|LC_|LD_PRELOAD$|LANG$|LOCPATH$|TZ$"
                       r"|STEAM_COMPAT_DATA_PATH$|STEAM_COMPAT_CLIENT_INSTALL_PATH$|STEAM_COMPAT_TOOL_PATHS$)")
# Per-launch plumbing a replay must not carry: pressure-vessel's launcher service (its socket is the real launch's).
DROP = ("STEAM_COMPAT_LAUNCHER_SERVICE",)


def steam_dir():
    return os.environ.get("POWOS_STEAM_DIR") or os.path.expanduser("~/.local/share/Steam")


def dirs(appid, steam=None):
    cd = os.path.join(steam or steam_dir(), "steamapps/compatdata", str(appid))
    return cd, os.path.join(cd, "powos-preboot")


def log(d, msg):
    try:
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "log"), "a") as f:
            f.write("%s [%d] %s\n" % (time.strftime("%F %T"), os.getpid(), msg))
    except OSError:
        pass


def env_key(env):
    h = hashlib.sha256()
    for k in sorted(k for k in env if WINE_KEYS.match(k) and k != HOLD):
        h.update(("%s=%s\0" % (k, env[k])).encode())
    return h.hexdigest()[:16]


def env_diff(a, b):
    ks = {k for k in list(a) + list(b) if WINE_KEYS.match(k) and k != HOLD}
    return sorted(k for k in ks if a.get(k) != b.get(k))


# ---- the switch ----
def enabled(appid, env=None):
    env = os.environ if env is None else env
    st = os.path.expanduser(env.get("POWOS_STEAM_COMPAT_STATE", "~/.local/share/powos/steam-compat.json"))
    try:
        with open(st) as f:
            v = json.load(f).get("apps", {}).get(str(appid), {}).get("preboot")
        if v in ("on", "off"):
            return v == "on"
    except (OSError, ValueError, AttributeError):
        pass
    return env.get("POWOS_WINE_PREBOOT", "0") == "1"


def mapped_tool(appid, steam=None):
    """config.vdf CompatToolMapping's name for the app (Steam keeps it current while it runs)."""
    try:
        with open(os.path.join(steam or steam_dir(), "config/config.vdf"), errors="replace") as f:
            t = f.read()
    except OSError:
        return None
    # The whole block by brace depth: a lazy "(.*?)\n\t*}" stopped at the FIRST app's closing brace, so only the first
    # mapped app was ever found (11-12: Broforce after 346010/294100 -> "runs on None", every preboot skipped).
    m = re.search(r'"CompatToolMapping"\s*\{', t, re.I)
    if not m:
        return None
    i, depth = m.end(), 1
    while i < len(t) and depth:
        depth += {"{": 1, "}": -1}.get(t[i], 0)
        i += 1
    m = re.search(r'"%s"\s*\{[^{}]*?"name"\s*"([^"]*)"' % re.escape(str(appid)), t[m.end():i], re.S)
    return m.group(1) if m else None


def prefix_current(cd, proton):
    """The prefix needs no Proton upgrade (setup_prefix would edit it under a live session otherwise)."""
    try:
        with open(os.path.join(proton, "proton")) as f:
            want = re.search(r'^CURRENT_PREFIX_VERSION\s*=\s*"([^"]+)"', f.read(), re.M).group(1)
        with open(os.path.join(cd, "version")) as f:
            return f.readline().strip() == want
    except (OSError, AttributeError):
        return False


# ---- processes ----
def proc_start(pid):
    try:
        with open("/proc/%d/stat" % pid) as f:
            st = f.read().rsplit(")", 1)[1].split()
        return None if st[0] in ("Z", "X") else st[19]  # a zombie has ended (its parent just hasn't reaped it)
    except (OSError, IndexError, ValueError):
        return None


def alive(pid, start):
    return bool(pid) and proc_start(int(pid)) == start


def server_dir(pfx):
    """Wine's socket dir for a prefix: <root>/.wine-<uid>/server-<dev>-<ino> (wineserver chdirs into it)."""
    st = os.stat(pfx)
    root = os.environ.get("POWOS_WINE_SERVER_ROOT", "/tmp")
    return os.path.join(root, ".wine-%d" % os.getuid(), "server-%x-%x" % (st.st_dev, st.st_ino))


def wineserver_up(pfx):
    try:
        sd = server_dir(pfx)
    except OSError:
        return False
    for p in os.listdir("/proc"):
        if p.isdigit():
            try:
                if os.readlink("/proc/%s/cwd" % p) == sd:
                    return True
            except OSError:
                pass
    return False


def services_up(pfx):
    for p in os.listdir("/proc"):
        if not p.isdigit():
            continue
        try:
            with open("/proc/%s/cmdline" % p, "rb") as f:
                if b"services.exe" not in f.read().lower():
                    continue
            with open("/proc/%s/environ" % p, "rb") as f:
                if ("WINEPREFIX=%s" % pfx.rstrip("/")).encode() in f.read().replace(b"/\0", b"\0"):
                    return True
        except OSError:
            pass
    return False


# ---- session file (under flock) ----
class Locked:
    def __init__(self, d):
        os.makedirs(d, exist_ok=True)
        self.d, self.f = d, open(os.path.join(d, "lock"), "a+")

    def __enter__(self):
        fcntl.flock(self.f, fcntl.LOCK_EX)
        return self

    def __exit__(self, *a):
        fcntl.flock(self.f, fcntl.LOCK_UN)
        self.f.close()

    def read(self):
        try:
            with open(os.path.join(self.d, "session.json")) as f:
                return json.load(f)
        except (OSError, ValueError):
            return None

    def write(self, s):
        p = os.path.join(self.d, "session.json")
        if s is None:
            try:
                os.unlink(p)
            except OSError:
                pass
            return
        with open(p + ".tmp", "w") as f:
            json.dump(s, f)
        os.replace(p + ".tmp", p)


# ---- the gate's side ----
def snapshot(appid, env, proton, slr):
    """The launch's environment, for the next pre-boot of this game (the gate, every real launch)."""
    _, d = dirs(appid, env.get("STEAM_COMPAT_CLIENT_INSTALL_PATH"))
    try:
        os.makedirs(d, exist_ok=True)
        p = os.path.join(d, "env.json")
        fd = os.open(p + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump({"env": dict(env), "proton": proton, "slr": slr, "time": time.time()}, f)
        os.replace(p + ".tmp", p)
    except OSError:
        pass


def claim(appid, env, proton):
    """A session to join (dict) or None. A live session that can't be joined is told to end."""
    _, d = dirs(appid, env.get("STEAM_COMPAT_CLIENT_INSTALL_PATH"))
    if not os.path.isfile(os.path.join(d, "session.json")):
        return None
    with Locked(d) as L:
        s = L.read()
        if not s:
            return None
        if not alive(s.get("pid"), s.get("start")):
            L.write(None)
            log(d, "claim: keeper %s gone, stale session removed" % s.get("pid"))
            return None
        why = None
        if s.get("state") not in ("booting", "up"):
            why = "state %s" % s.get("state")
        elif s.get("proton") != proton:
            why = "another Proton (%s)" % s.get("proton")
        elif s.get("envkey") != env_key(env):
            why = "environment differs: %s" % (", ".join(env_diff(s.get("wine_env", {}), env)) or "?")
        if why:
            s["state"] = "ending"
            L.write(s)
            os.kill(int(s["pid"]), signal.SIGTERM)
            log(d, "claim refused (%s): session ended, the launch waits for it (waitforexitandrun)" % why)
            return None
        s.update(state="claimed", claimed_by=os.getpid(), claimed_start=proc_start(os.getpid()),
                 claimed_at=time.time(), booted=s.get("up_ms") is not None)
        L.write(s)
    log(d, "claimed by the game's launch (%s, %.0f ms after the pre-boot started)"
        % ("booted" if s["booted"] else "still booting", (time.time() - s["t0"]) * 1000))
    return s


def release_and_wait(appid, env, s, timeout=END_WAIT_S + 15):
    """The game exited: end the session and wait for it (the keeper exits after the prefix's wineserver)."""
    _, d = dirs(appid, env.get("STEAM_COMPAT_CLIENT_INSTALL_PATH"))
    try:
        os.kill(int(s["pid"]), signal.SIGUSR1)
    except OSError:
        return
    t = time.time()
    while alive(s["pid"], s["start"]) and time.time() - t < timeout:
        time.sleep(0.1)
    log(d, "released after the game: session ended in %.0f ms" % ((time.time() - t) * 1000))


# ---- the keeper ----
def start(appid):
    appid = str(appid)
    steam = steam_dir()
    cd, d = dirs(appid, steam)
    if not enabled(appid):
        return 0
    try:
        with open(os.path.join(d, "env.json")) as f:
            snap = json.load(f)
    except (OSError, ValueError):
        log(d, "start: no launch environment yet (the game's first launch through %s writes it)" % GATE)
        return 0
    env, proton, slr = dict(snap["env"]), snap["proton"], snap["slr"]
    pfx = os.path.join(cd, "pfx")
    why = None
    tool = mapped_tool(appid, steam)
    if tool != GATE:
        why = "the game runs on %s, not %s" % (tool, GATE)
    elif not os.path.isfile(os.path.join(proton, "proton")) or not os.path.isfile(os.path.join(slr, "_v2-entry-point")):
        why = "Proton/runtime of the last launch gone"
    elif not prefix_current(cd, proton):
        why = "the prefix needs Proton's upgrade first (the launch does it)"
    elif wineserver_up(pfx):
        why = "a session is already up on the prefix (the game, or its install script)"
    if why:
        log(d, "start: skipped, " + why)
        return 0
    for k in DROP:
        env.pop(k, None)
    env[HOLD] = "1"
    with Locked(d) as L:
        s = L.read()
        if s and alive(s.get("pid"), s.get("start")):
            log(d, "start: skipped, a pre-boot is already there (%s)" % s.get("state"))
            return 0
        t0 = time.time()
        wine_env = {k: v for k, v in snap["env"].items() if WINE_KEYS.match(k)}
        s = {"pid": os.getpid(), "start": proc_start(os.getpid()), "state": "booting", "proton": proton,
             "envkey": env_key(snap["env"]), "wine_env": wine_env, "t0": t0, "up_ms": None}
        L.write(s)
    return keep(appid, d, pfx, env, proton, slr, s)


def keep(appid, d, pfx, env, proton, slr, s):
    flags = {"release": False, "end": False}
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    r, w = os.pipe()
    entry = os.path.join(slr, "_v2-entry-point")
    cmd = [entry, "--verb=run", "--", os.path.join(proton, "proton"), "runinprefix",
           "cmd.exe", "/c", "set /p %s=" % HOLD]
    try:
        out = open(os.path.join(d, "boot.log"), "w")
        child = subprocess.Popen(cmd, stdin=r, stdout=out, stderr=out, env=env, start_new_session=True)
    except OSError as e:
        with Locked(d) as L:
            L.write(None)
        log(d, "start: failed: %s" % e)
        return 1
    os.close(r)
    # Signals taken synchronously (blocked only now: the child must not inherit the mask): USR1 = the game's launch
    # released it, TERM = end it. Polls at 10 Hz while booting/unclaimed, 1 Hz while the game runs (no busy keeper).
    sigs = {signal.SIGUSR1, signal.SIGTERM}
    signal.pthread_sigmask(signal.SIG_BLOCK, sigs)
    log(d, "start: booting the session (%s)" % os.path.basename(proton))
    why, st = None, "booting"
    while why is None:
        got = signal.sigtimedwait(sigs, 1.0 if st == "claimed" else 0.1)
        if got:
            flags["release" if got.si_signo == signal.SIGUSR1 else "end"] = True
        if child.poll() is not None:
            why = "holder exited (rc %s) - see boot.log" % child.returncode
            break
        with Locked(d) as L:
            cur = L.read() or {}
            if cur.get("state") == "booting" and services_up(pfx):
                cur["state"] = "up"
                cur["up_ms"] = s["up_ms"] = int((time.time() - s["t0"]) * 1000)
                L.write(cur)
                log(d, "session up in %d ms (services.exe running)" % cur["up_ms"])
            st = cur.get("state")
            if flags["end"]:
                why = "told to end"
            elif flags["release"]:
                why = "released by the game's launch"
            elif st == "claimed" and not alive(cur.get("claimed_by"), cur.get("claimed_start")):
                why = "the game's launch (gate %s) is gone" % cur.get("claimed_by")
            elif st in ("booting", "up") and time.time() - s["t0"] > IDLE_S:
                why = "not claimed in %.0f s" % IDLE_S
            elif st == "ending":
                why = "ending"
            if why:
                cur["state"] = "ending"
                L.write(cur)
    os.close(w)  # cmd's `set /p` reads EOF -> exits -> no user process left -> Wine ends the session
    t = time.time()
    try:
        child.wait(END_WAIT_S)
    except subprocess.TimeoutExpired:
        pass
    while wineserver_up(pfx) and time.time() - t < END_WAIT_S:
        time.sleep(0.1)
    left = wineserver_up(pfx)
    with Locked(d) as L:
        L.write(None)
    log(d, "end: %s; session %s %.0f ms later" % (why, "STILL UP" if left else "gone", (time.time() - t) * 1000))
    return 0


def status(appid):
    _, d = dirs(appid)
    with Locked(d) as L:
        s = L.read()
    on = enabled(appid)
    if not s or not alive(s.get("pid"), s.get("start")):
        print("%s: pre-boot %s, no session" % (appid, "on" if on else "off"))
    else:
        print("%s: pre-boot %s, session %s (keeper %s, %.0f s old)" % (appid, "on" if on else "off", s["state"],
                                                                     s["pid"], time.time() - s["t0"]))
    return 0


def stop(appid):
    _, d = dirs(appid)
    with Locked(d) as L:
        s = L.read()
    if s and alive(s.get("pid"), s.get("start")):
        os.kill(int(s["pid"]), signal.SIGTERM)
    return 0


def main(a):
    if len(a) == 2 and a[0] in ("start", "status", "stop") and a[1].isdigit():
        return {"start": start, "status": status, "stop": stop}[a[0]](a[1])
    sys.stderr.write("usage: powos_preboot.py start|status|stop <appid>\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
