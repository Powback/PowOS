# PowOS /usr/lib/powos-steam/py/sitecustomize.py - on PYTHONPATH for Steam and everything it starts (steam-env), so
# Python imports it at the start of every Python under Steam. It acts in ONE place, Valve's FEX compat tool
# (steamapps/common/FEX-Emu/fex-compat-tool, the first layer of every x86 Proton launch), and returns at once anywhere
# else (a few stat-free string compares).
#
# HACK: Steam runs the game's install script evaluator before EVERY launch, through the whole chain: fex-compat-tool ->
# FEX (RootFS mount) -> pressure-vessel (SteamLinuxRuntime_4 container, locale-gen) -> Proton's Python under FEX ->
# PowOS's user_settings.py, which only then sees the evaluator has nothing to do and exits 0. Measured 2026-11-04 on
# Broforce (x86 Proton Experimental): 7-33 s from Steam's "Running install script evaluator" to that skip, every
# launch. Here the same check (the same key and record, the Proton's own PowOS user_settings.py) runs before any of
# that: input as at the last good run -> exit 0, so the game's own launch starts right away. Anything changed, no
# record, not PowOS's user_settings.py, any error: nothing happens here and the chain runs as before.
# Real fix: Valve's client skipping an evaluator run whose script it already ran in this prefix (see user_settings.py).
import os
import sys


def _powos_iscript_early():
    a = getattr(sys, "argv", None) or []
    if len(a) < 6 or os.path.basename(a[0]) != "fex-compat-tool" or a[1] != "run":
        return
    for i in range(2, len(a) - 2):
        if os.path.basename(a[i]) == "proton" and a[i + 1] == "run" \
                and os.path.basename(a[i + 2].replace("\\", "/")).lower() == "iscriptevaluator.exe":
            break
    else:
        return
    proton_dir = os.path.dirname(os.path.abspath(a[i]))
    us = os.path.join(proton_dir, "user_settings.py")
    with open(us) as f:
        if not f.readline().startswith("# PowOS user_settings"):
            return  # the user's own user_settings.py: Proton runs the evaluator as it decides
    import importlib.util
    spec = importlib.util.spec_from_file_location("powos_user_settings", us)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    if mod.iscript_skip_early(a[i:], proton_dir, "before the container (FEX compat tool)"):
        sys.stdout.flush()
        os._exit(0)


try:
    _powos_iscript_early()
except Exception as e:  # never break a launch (or any other Python) over this
    try:
        sys.stderr.write("PowOS sitecustomize: %s\n" % e)
    except Exception:
        pass
