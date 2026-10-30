# PowOS user_settings.py - installed into each Proton by /usr/bin/steam (package steam); a user_settings.py whose first
# line isn't this one is the user's own and is left alone. Proton imports it while it sets up a session (after the
# Steam Runtime container is up, before Wine starts): its `user_settings` dict becomes environment for Wine and the game.
#
# 1. Extra settings for one check or experiment: ~/.config/powos/proton-settings.json, e.g. {"FEX_ENABLECODECACHINGWIP":
#    "1"} (bf-coldstart.sh fexcache writes and removes it). Missing or broken: nothing extra.
# 2. The install script evaluator, skipped when it has nothing to do (see below).
# 3. Unreal Engine games at the current screen size (see _ue_screen below).
import glob
import hashlib
import json
import os
import sys
import time

user_settings = {}
try:
    with open(os.path.expanduser("~/.config/powos/proton-settings.json")) as _f:
        user_settings.update({str(k): str(v) for k, v in json.load(_f).items()})
except (OSError, ValueError, AttributeError):
    pass


# HACK: Steam runs the game's install script evaluator (`proton run legacycompat/iscriptevaluator.exe
# legacycompat\evaluatorscript_<appid>.vdf`, its own reaper `Install=1`) before EVERY launch, and Proton boots a whole
# Wine for it - under FEX on the phone that is 6-42 s (Broforce, 2026-10-23: ~29 s of a 82 s tap -> window), then the
# game's `waitforexitandrun` waits for that Wine's wineserver to exit and boots Wine again. The evaluator only checks
# registry keys its earlier run wrote (the redistributables' "installed" marks) and exits. So: after it exits 0, its
# input is recorded (compatdata/<appid>/powos-iscript.done: the script's bytes, Proton's version, the prefix's inode);
# the next launch with the same input exits 0 here at once, before Wine starts. Anything changed - Steam wrote a new
# script, a Proton update, a new prefix, /usr/bin/steam's reg_guard restored or rebuilt the registry (it deletes the
# record) - and the evaluator runs as always. Every decision goes to compatdata/<appid>/powos-iscript.log.
# Real fix: Valve's client skipping an evaluator run whose script it already ran in this prefix (as it does on Windows,
# where it reads the registry itself), or running it inside the game's own Wine session.
def _iscript_key(argv, data):
    steam = os.environ.get("STEAM_COMPAT_CLIENT_INSTALL_PATH", "")
    h = hashlib.sha256()
    found = False
    for a in argv[3:]:
        h.update(a.encode("utf-8", "surrogateescape") + b"\0")
        rel = a.replace("\\", "/")
        for p in (rel, os.path.join(steam, rel), os.path.join(os.path.dirname(argv[2]), "..", rel)):
            try:
                with open(p, "rb") as f:
                    h.update(f.read())
                found = True
                break
            except OSError:
                continue
    if not found:
        return None  # no script to compare: can't tell whether it changed
    try:
        with open(os.path.join(os.path.dirname(os.path.abspath(sys.argv[0])), "version"), "rb") as f:
            h.update(f.read())
        st = os.stat(os.path.join(data, "pfx"))
        h.update(("%d:%d" % (st.st_dev, st.st_ino)).encode())
    except OSError:
        return None  # no prefix yet: Proton is about to make one, the evaluator has everything to do
    if not os.path.exists(os.path.join(data, "pfx", "creation_sync_guard")):
        return None  # prefix being (re)built
    return h.hexdigest()


def _iscript():
    argv = sys.argv
    if len(argv) < 4 or argv[1] != "run" or os.path.basename(argv[2]).lower() != "iscriptevaluator.exe":
        return
    data = os.environ.get("STEAM_COMPAT_DATA_PATH", "")
    if not data:
        return
    done, logf = os.path.join(data, "powos-iscript.done"), os.path.join(data, "powos-iscript.log")

    def log(msg):
        try:
            with open(logf, "a") as f:
                f.write("%s %s\n" % (time.strftime("%F %T"), msg))
        except OSError:
            pass

    key = _iscript_key(argv, data)
    try:
        with open(done) as f:
            last = f.read().strip()
    except OSError:
        last = ""
    if key and key == last:
        log("skipped: script, Proton and prefix as at its last good run (%s)" % key[:12])
        sys.stdout.flush()
        os._exit(0)
    log("running it (%s)" % ("no record" if not last else "input changed" if key else "can't compare"))
    if not key:
        return
    real_exit = sys.exit

    def exit_and_record(rc=0):  # Proton's last line: sys.exit(rc) with the evaluator's exit code
        if rc in (0, None):
            try:
                with open(done + ".tmp", "w") as f:
                    f.write(key + "\n")
                    f.flush()
                    os.fsync(f.fileno())
                os.replace(done + ".tmp", done)
            except OSError:
                pass
        log("exited %s%s" % (rc, ", recorded" if rc in (0, None) else ""))
        real_exit(rc)

    sys.exit = exit_and_record


# Unreal Engine games at the screen's size now (folded or unfolded). A UE game starts at the resolution saved in its
# GameUserSettings.ini (ABZU, 2026-10-30: DesiredScreenWidth/Height 1280x720, bUseDesktopResolutionForFullscreen=False
# in a 2268x2314 window) and Proton scales that up with black bars. The Unity counterpart is a launch option
# (targets/android/steam/unity-screen); this one needs none: Proton imports this file in every game's own session
# (inside the Steam Runtime container, the game's env and argv), so every UE game under Proton gets it.
# A game launch (`run`/`waitforexitandrun <exe>`) of a game whose install dir is laid out as UE's (Engine/ + <Project>/
# Content/Paks, or a <Project>/Binaries/Win*/*-Shipping.exe):
#   - every GameUserSettings.ini in its prefix (AppData/Local, Documents/My Games, Saved Games) or install dir: in its
#     *GameUserSettings section, ResolutionSizeX/Y, LastUserConfirmedResolutionSizeX/Y = W x H and
#     bUseDesktopResolutionForFullscreen=True (added when missing), DesiredScreenWidth/Height and
#     LastUserConfirmedDesiredScreenWidth/Height = W x H where present. Only when one differs; every other line stays
#     byte for byte (CRLF kept); the first edit leaves GameUserSettings.ini.powos-bak.
#   - the game's arguments get -ResX=W -ResY=H and -fullscreen (-windowed when the ini says FullscreenMode=2, nothing
#     for 1 = windowed fullscreen), unless the launch already has its own -ResX/-ResY/-windowed/-fullscreen. This is
#     what a first launch (no ini yet) and a game that re-applies its own saved size rely on.
# W x H = the X root window now (libX11 through ctypes, as unity-screen). No display: nothing changes.
# Every decision goes to compatdata/<appid>/powos-screen.log.
_INI_SET = ("ResolutionSizeX", "ResolutionSizeY", "LastUserConfirmedResolutionSizeX", "LastUserConfirmedResolutionSizeY")
_INI_IF_PRESENT = ("DesiredScreenWidth", "DesiredScreenHeight",
                   "LastUserConfirmedDesiredScreenWidth", "LastUserConfirmedDesiredScreenHeight")


def _screen_size():
    import ctypes
    x = ctypes.CDLL("libX11.so.6")
    x.XOpenDisplay.restype = ctypes.c_void_p
    x.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x.XDefaultScreen.argtypes = [ctypes.c_void_p]
    x.XDisplayWidth.argtypes = x.XDisplayHeight.argtypes = [ctypes.c_void_p, ctypes.c_int]
    x.XCloseDisplay.argtypes = [ctypes.c_void_p]
    d = x.XOpenDisplay(None)
    if not d:
        return None
    n = x.XDefaultScreen(d)
    w, h = x.XDisplayWidth(d, n), x.XDisplayHeight(d, n)
    x.XCloseDisplay(d)
    return (w, h) if w > 0 and h > 0 else None


def _is_unreal(inst):
    if not inst or not os.path.isdir(inst):
        return False
    if glob.glob(os.path.join(glob.escape(inst), "*", "Binaries", "Win*", "*-Shipping.exe")):
        return True
    return os.path.isdir(os.path.join(inst, "Engine")) and bool(glob.glob(os.path.join(glob.escape(inst), "*", "Content", "Paks")))


def _ue_inis(data, inst):
    u = os.path.join(glob.escape(data), "pfx", "drive_c", "users", "steamuser")
    pats = [os.path.join(u, "AppData", "Local", "*"), os.path.join(u, "Documents", "My Games", "*"),
            os.path.join(u, "Documents", "My Games", "*", "*"), os.path.join(u, "Saved Games", "*"),
            os.path.join(glob.escape(inst), "*")]
    out = []
    for p in pats:
        out += glob.glob(os.path.join(p, "Saved", "Config", "Windows*", "GameUserSettings.ini"))
    return sorted(set(out))


def _ue_ini_edit(path, w, h):
    """(changes, FullscreenMode or None). Edits only the resolution keys of the *GameUserSettings section."""
    with open(path, "rb") as f:
        raw = f.read()
    lines = raw.decode("utf-8", "surrogateescape").splitlines(True)
    nl = "\r\n" if "\r\n" in raw.decode("utf-8", "surrogateescape") else "\n"
    want = {k: str(w if k.endswith(("X", "Width")) else h) for k in _INI_SET + _INI_IF_PRESENT}
    want["bUseDesktopResolutionForFullscreen"] = "True"
    start = end = None
    for i, l in enumerate(lines):
        s = l.strip()
        if s.startswith("["):
            if start is not None:
                end = i
                break
            if s.endswith("GameUserSettings]"):
                start = i
    if start is None:
        return [], None
    end = len(lines) if end is None else end
    seen, changes, mode = set(), [], None
    for i in range(start + 1, end):
        k, eq, v = lines[i].partition("=")
        k = k.strip()
        if not eq:
            continue
        if k == "FullscreenMode":
            mode = v.strip()
        if k in want:
            seen.add(k)
            if v.strip() != want[k]:
                eol = lines[i][len(lines[i].rstrip("\r\n")):] or nl
                changes.append("%s %s -> %s" % (k, v.strip(), want[k]))
                lines[i] = "%s=%s%s" % (k, want[k], eol)
    add = [k for k in _INI_SET + ("bUseDesktopResolutionForFullscreen",) if k not in seen]
    if add:
        at = end
        while at > start + 1 and not lines[at - 1].strip():  # after the section's last key, before its blank lines
            at -= 1
        if not lines[at - 1].endswith(("\n", "\r")):
            lines[at - 1] += nl
        lines[at:at] = ["%s=%s%s" % (k, want[k], nl) for k in add]
        changes += ["%s added = %s" % (k, want[k]) for k in add]
    if changes:
        if not os.path.exists(path + ".powos-bak"):
            with open(path + ".powos-bak", "wb") as f:
                f.write(raw)
        tmp = path + ".powos-tmp"
        with open(tmp, "wb") as f:
            f.write("".join(lines).encode("utf-8", "surrogateescape"))
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    return changes, mode


def _ue_screen():
    argv = sys.argv
    if len(argv) < 3 or argv[1] not in ("run", "waitforexitandrun"):
        return
    if os.path.basename(argv[2]).lower() == "iscriptevaluator.exe":
        return
    data = os.environ.get("STEAM_COMPAT_DATA_PATH", "")
    inst = os.environ.get("STEAM_COMPAT_INSTALL_PATH", "")
    if not inst:  # .../steamapps/common/<game>/... from the exe's path
        p = os.path.abspath(argv[2]).split(os.sep)
        if "common" in p[:-2]:
            i = len(p) - 1 - p[::-1].index("common")
            inst = os.sep.join(p[:i + 2])
    if not data or not _is_unreal(inst):
        return

    def log(msg):
        try:
            with open(os.path.join(data, "powos-screen.log"), "a") as f:
                f.write("%s %s\n" % (time.strftime("%F %T"), msg))
        except OSError:
            pass

    size = _screen_size() if os.environ.get("DISPLAY") else None
    if not size:
        log("Unreal game %s: no screen size (DISPLAY=%s) - unchanged" % (inst, os.environ.get("DISPLAY", "unset")))
        return
    w, h = size
    mode = None
    for ini in _ue_inis(data, inst):
        try:
            changes, m = _ue_ini_edit(ini, w, h)
        except OSError as e:
            log("%s: %s" % (ini, e))
            continue
        mode = m if m is not None else mode
        log("%s: %s" % (ini, "; ".join(changes) if changes else "already %dx%d" % (w, h)))
    have = [a.lower() for a in argv[3:]]
    add = []
    if not any(a.startswith(("-resx=", "-resy=")) for a in have):
        add += ["-ResX=%d" % w, "-ResY=%d" % h]
    if not any(a in ("-windowed", "-fullscreen") for a in have) and mode != "1":
        add.append("-windowed" if mode == "2" else "-fullscreen")
    argv += add  # Proton's run() reads sys.argv[2:] after this import
    log("Unreal game %s at %dx%d, arguments %s" % (os.path.basename(inst), w, h, " ".join(add) or "(its own)"))


for _f in (_iscript, _ue_screen):
    try:
        _f()
    except Exception as e:  # never break a launch over this
        sys.stderr.write("PowOS user_settings: %s: %s\n" % (_f.__name__, e))
