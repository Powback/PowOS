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


try:
    _iscript()
except Exception as e:  # never break a launch over this
    sys.stderr.write("PowOS user_settings: %s\n" % e)
