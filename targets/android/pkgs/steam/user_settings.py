# PowOS user_settings.py - installed into each Proton by /usr/bin/steam (package steam); a user_settings.py whose first
# line isn't this one is the user's own and is left alone. Proton imports it while it sets up a session (after the
# Steam Runtime container is up, before Wine starts): its `user_settings` dict becomes environment for Wine and the game.
#
# 1. Extra settings for one check or experiment: ~/.config/powos/proton-settings.json, e.g. {"FEX_ENABLECODECACHINGWIP":
#    "1"} (bf-coldstart.sh fexcache writes and removes it). Missing or broken: nothing extra.
# 2. The install script evaluator, skipped when it has nothing to do (see below).
import hashlib
import json
import os
import sys
import time

# No xalia: Proton's accessibility/gamepad-UI helper (xalia.exe) runs beside the game for its whole session - under FEX
# it took 13-16% of a core next to ABZU (10-30 17:50) for nothing (touch and the PowOS pad drive games here). Proton
# applies this before its own default ("PROTON_USE_XALIA" not in env). proton-settings.json {"PROTON_USE_XALIA": "1"}
# turns it back on for a check.
user_settings = {"PROTON_USE_XALIA": "0"}

# HACK: black 16x4-block dashes in every Unity/DXVK frame (Broforce: 17-44 % of frames, Xwayland's copy and the screen)
# come from the game's own UBWC render targets on Adreno 740 - both FEX's x86 Turnip 26.2.0 and ours (eb3e7fd4), GMEM
# and sysmem; TU_DEBUG=flushall doesn't help (not a missing flush). TU_DEBUG=noubwc: 0 of 93 frames
# (bf-checker.sh, docs/research/broforce-black-columns.md, 2026-11-04). Costs GPU bandwidth: ABZU (GPU-bound) pays it.
# Here, not in steam-env (where it was until 11-07): Proton applies a user_settings key only when the environment
# doesn't have it, so steam-env's export made every "UBWC on" check (proton-settings.json TU_DEBUG=startup/gmem/
# syncdraw) run with noubwc anyway - UBWC was never measured on since 11-04. Now a check's or the user's TU_DEBUG wins.
# Real fix: find which UBWC path dashes (bf-checker.sh ubwc syncdraw gmem 3dload, on the steam package with this
# change) and fix it in pkgs/vulkan-freedreno-kgsl, then this line goes.
user_settings["TU_DEBUG"] = "noubwc"


# HACK: FEX's disk cache (FEX_DISKCACHE=1, Proton ARM64's arm64ec FEX) also caches ANONYMOUS code by default
# (DiskCacheAnonCaching). A Mono game's anonymous code is Mono's own JIT output, different every launch, so it never
# hits - FEX only stores it again: Broforce, 2026-11-05, ~37k stores per launch, each locking both RWCacheDB files
# through LockFileEx = 4 wineserver round trips from the FEX:DiskCache thread, for the whole session (wineserver 3.3
# core-s + that thread 3.7 core-s in the 10 s load; main thread 7.8 s CPU). Off for Mono games: wineserver 0.8 core-s,
# main thread 6.0 s, exe -> first frame 10.3 -> 9.5 s. File-backed code (the game's and Mono's own DLLs) stays cached.
# Real fix: FEX not re-storing anon blocks that already missed (or batching a store's file locks), upstream.
def _mono_game():
    import glob
    p = os.environ.get("STEAM_COMPAT_INSTALL_PATH", "")
    if not p:
        return False
    p = glob.escape(p)
    return bool(glob.glob(os.path.join(p, "*_Data/Mono/EmbedRuntime/mono*.dll"))
                or glob.glob(os.path.join(p, "MonoBleedingEdge/EmbedRuntime/mono*.dll")))


# HACK: FEX's TSO emulation (x86 store/load ordering: every guest load/store an LDAPR/STLR + barriers) off for Mono
# games. The game's frame rate under touch is set by its main thread (Broforce play 11-06: 75.9 % of the prime core at
# horae's 1.59 GHz cap, 38 fps; we never touch that cap), so its per-frame cost is the lever. Measured 2026-11-05
# (bf-pacing base, cover, same 1.6-1.7 GHz cap, fps held ~39 by the display either way): main thread per frame
# 13.2-14.4 ms with TSO (3 runs) vs 11.8-11.9 ms without (3 runs) = 15-23 % fewer cycles, no crash or hang; the
# exe -> first frame A/B was flat (compile-bound, not barrier-bound). Mono's JIT output + UnityPlayer are the main
# thread's hot code; their atomics (lock-prefixed / Interlocked) stay atomic without TSO - only plain-store ordering
# is relaxed, which box64 also runs Unity games without by default (strongmem 0). TSO is part of FEX's disk cache key:
# the first launch after this recompiles once. Per game back on: launch options `FEX_TSOENABLED=1 %command%` (Proton
# applies a user_settings key only when the environment lacks it) or proton-settings.json {"FEX_TSOENABLED": "1"}.
# Real fix: hardware TSO (none on Snapdragon 8 Gen 2) or FEX eliding barriers for thread-private memory, upstream.
def _mono_settings():
    return {"FEX_DISKCACHEANONCACHING": "0", "FEX_TSOENABLED": "0"}


try:
    if _mono_game():
        user_settings.update(_mono_settings())
except OSError:
    pass
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
# input is recorded (compatdata/<appid>/powos-iscript.done: the script's bytes and the prefix's inode); the next
# launch with the same input exits 0 here at once, before Wine starts. Anything changed - Steam wrote a new script, a
# new prefix, /usr/bin/steam's reg_guard restored or rebuilt the registry (it deletes the record) - and the evaluator
# runs as always. Every decision goes to compatdata/<appid>/powos-iscript.log.
# Proton's version is NOT part of the key (2026-11-11): the marks the evaluator checks live in the prefix's registry,
# which a Proton update keeps (its upgrade_pfx/wineboot -u run in the game's own launch); a rebuilt prefix changes the
# inode / drops creation_sync_guard. With the version in it, every Proton Experimental update (Valve's, ~weekly, in the
# background) re-ran the evaluator at each game's next tap: +20 s on Broforce/ABZU 11-11 (ARM64 Proton 04:17 update).
# Records written with the old key (version included) are still honoured when they match today's Proton, and rewritten.
# For x86 Proton (Valve's FEX compat tool layer first) the skip happens even earlier, in that layer's own Python, before
# FEX, the Steam Runtime container and Proton's Python (under FEX) start: /usr/lib/powos-steam/py/sitecustomize.py
# calls iscript_skip_early() with the same key - that container alone took 7-33 s per launch (Broforce, 2026-11-04).
# Real fix: Valve's client skipping an evaluator run whose script it already ran in this prefix (as it does on Windows,
# where it reads the registry itself), or running it inside the game's own Wine session.
def _iscript_key(argv, data, proton_dir=None, with_version=False):
    # argv: [proton, "run", <iscriptevaluator.exe>, <script>...]; proton_dir: that Proton's directory.
    # with_version: the pre-11-11 key (Proton's version file hashed in), only to honour records written with it.
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
        if with_version:
            with open(os.path.join(proton_dir or os.path.dirname(os.path.abspath(argv[0])), "version"), "rb") as f:
                h.update(f.read())
        st = os.stat(os.path.join(data, "pfx"))
        h.update(("%d:%d" % (st.st_dev, st.st_ino)).encode())
    except OSError:
        return None  # no prefix yet: Proton is about to make one, the evaluator has everything to do
    if not os.path.exists(os.path.join(data, "pfx", "creation_sync_guard")):
        return None  # prefix being (re)built
    return h.hexdigest()


def _is_evaluator(argv):
    return len(argv) >= 4 and argv[1] == "run" and os.path.basename(argv[2]).lower() == "iscriptevaluator.exe"


def _iscript_log(data, msg):
    try:
        with open(os.path.join(data, "powos-iscript.log"), "a") as f:
            f.write("%s %s\n" % (time.strftime("%F %T"), msg))
    except OSError:
        pass


def _iscript_state(argv, proton_dir=None):
    """(compatdata dir, this run's key or None, the last good run's key or "") - argv as _iscript_key's."""
    data = os.environ.get("STEAM_COMPAT_DATA_PATH", "")
    if not data:
        return "", None, ""
    try:
        with open(os.path.join(data, "powos-iscript.done")) as f:
            last = f.read().strip()
    except OSError:
        last = ""
    key = _iscript_key(argv, data, proton_dir)
    if key and last and last != key and last == _iscript_key(argv, data, proton_dir, with_version=True):
        _iscript_record(data, key)  # a pre-11-11 record (version in its key) for this same input: carry it over
        last = key
    return data, key, last


def _iscript_record(data, key):
    done = os.path.join(data, "powos-iscript.done")
    try:
        with open(done + ".tmp", "w") as f:
            f.write(key + "\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(done + ".tmp", done)
    except OSError:
        pass


def iscript_skip_early(argv, proton_dir, where):
    """True (logged) when this evaluator run's input matches its last good run: the caller exits 0 at once, before
    the Steam Runtime container, FEX and Proton start (sitecustomize.py, in Valve's FEX compat tool). Never records -
    only a real run inside Proton does."""
    if not _is_evaluator(argv):
        return False
    data, key, last = _iscript_state(argv, proton_dir)
    if data and key and key == last:
        _iscript_log(data, "skipped %s: script and prefix as at its last good run (%s)" % (where, key[:12]))
        return True
    return False


def _iscript():
    argv = sys.argv
    if not _is_evaluator(argv):
        return
    data, key, last = _iscript_state(argv)
    if not data:
        return

    def log(msg):
        _iscript_log(data, msg)

    if key and key == last:
        log("skipped: script and prefix as at its last good run (%s)" % key[:12])
        sys.stdout.flush()
        os._exit(0)
    log("running it (%s)" % ("no record" if not last else "input changed" if key else "can't compare"))
    if not key:
        return
    real_exit = sys.exit

    def exit_and_record(rc=0):  # Proton's last line: sys.exit(rc) with the evaluator's exit code
        if rc in (0, None):
            _iscript_record(data, key)
        log("exited %s%s" % (rc, ", recorded" if rc in (0, None) else ""))
        real_exit(rc)

    sys.exit = exit_and_record


if __name__ == "user_settings":  # Proton's own import (sitecustomize.py loads it under another name, for its functions)
    try:
        _iscript()
    except Exception as e:  # never break a launch over this
        sys.stderr.write("PowOS user_settings: %s\n" % e)
