# PowOS /usr/lib/powos-steam/py/powos_steam_tools.py: finding Valve's Steam tools by what they ARE, not by the name or
# build path one version had, and the state of each PowOS fix that goes into them. Shared by the ARM64 launch gate
# (arm64-gate-entry), powos-steam-compat and powos-steam-fixes, so they agree on which Proton/runtime is "the" one.
#
# Steam and Proton update themselves; every fix here must keep working - or say clearly that it doesn't - after an
# update we never saw. Rules (docs/research/version-proof-gaming.md):
#   - a tool is found by capability: ARM64 Proton = a Proton (a `proton` script) with Wine's aarch64-windows DLLs; the
#     ARM64 Steam Linux Runtime = a SteamLinuxRuntime_<n>-arm64 with _v2-entry-point (newest <n> wins);
#   - a binary overlay replaces a file only while that file is the exact upstream build ours was made from; any other
#     build keeps Valve's file and the reason is logged (fix_status), with the command that makes a matching overlay.
import hashlib
import os
import re

GATE = "powos-proton-arm64"
PREFERRED_ARM64 = "Proton Experimental (ARM64)"

# HACK (see arm64-gate-entry): Proton ARM64's kernelbase.dll with 0001-kernelbase-wow32-direct-open.patch, one entry
# per Valve build we made it for. (Proton-relative path, sha256 of Valve's file, sha256 of ours, our file next to the
# gate, the Proton version it came from). A new Valve build: targets/android/steam/proton-overlay/build.sh
# PROTON_VERSION=<that Proton's version> prints both hashes; add a row (older rows may stay: they match nothing).
# Real fix: the patch upstream (Wine kernelbase), then Valve's next Proton has it - drop the table and the overlay.
OVERLAYS = [
    ("files/lib/wine/aarch64-windows/kernelbase.dll",
     "21ab141457dc3a360d34540b362ee21bf3edb69d629a29a820b0344652a4a8a0",
     "a3f08252c4ce37840ba7bd67d0041dae0adc8d6c29aacadfee459361694ba736", "overlay-kernelbase.dll",
     "experimental-11.0-20261027b-arm64"),
]


def steam_root():
    return os.environ.get("STEAM_COMPAT_CLIENT_INSTALL_PATH") or os.path.expanduser("~/.local/share/Steam")


def is_arm64_proton(d):
    return os.path.isfile(os.path.join(d, "proton")) and os.path.isdir(os.path.join(d, "files/lib/wine/aarch64-windows"))


def arm64_protons(steam=None):
    """Every installed ARM64 Proton, best first: Valve's Proton Experimental (ARM64) by its name, then any other
    Experimental, then the newest (its version file's mtime). Our own gate is never one."""
    steam = steam or steam_root()
    found = []
    for base in ("steamapps/common", "compatibilitytools.d"):
        try:
            names = os.listdir(os.path.join(steam, base))
        except OSError:
            continue
        for n in names:
            d = os.path.join(steam, base, n)
            if n != GATE and is_arm64_proton(d):
                try:
                    m = os.stat(os.path.join(d, "version")).st_mtime
                except OSError:
                    m = 0
                found.append((n != PREFERRED_ARM64, "experimental" not in n.lower(), -m, n, d))
    return [f[-1] for f in sorted(found)]


def arm64_proton(steam=None):
    e = os.environ.get("POWOS_ARM64_PROTON")
    if e:
        return e
    p = arm64_protons(steam)
    return p[0] if p else None


def arm64_runtime(steam=None):
    """The ARM64 Steam Linux Runtime container (SteamLinuxRuntime_<n>-arm64 with _v2-entry-point), newest <n>."""
    e = os.environ.get("POWOS_ARM64_RUNTIME")
    if e:
        return e
    common = os.path.join(steam or steam_root(), "steamapps/common")
    best = None
    try:
        names = os.listdir(common)
    except OSError:
        return None
    for n in names:
        m = re.fullmatch(r"SteamLinuxRuntime_(\d+)-arm64", n)
        if m and os.path.isfile(os.path.join(common, n, "_v2-entry-point")):
            if best is None or int(m.group(1)) > best[0]:
                best = (int(m.group(1)), os.path.join(common, n))
    return best[1] if best else None


def proton_version(d):
    """Proton's own build name from its version file ("<timestamp> experimental-11.0-20261027b-arm64"), or ""."""
    try:
        with open(os.path.join(d, "version")) as f:
            return f.read().split()[-1]
    except (OSError, IndexError):
        return ""


def wine_tag(version):
    """ValveSoftware/wine's tag for a Proton build: experimental-11.0-20261027b-arm64 -> experimental-wine-11.0-20261027b
    (the tag the overlay is built from). None for a naming we don't know."""
    m = re.fullmatch(r"experimental-(\d+\.\d+-\d+[a-z]?)(?:-arm64)?", version or "")
    return "experimental-wine-" + m.group(1) if m else None


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def overlay_status(proton, here):
    """[(rel, state, reason, row)] for each overlaid file: state "ours" (in place), "apply" (Valve's build we have an
    overlay for), "skip" (any other build: Valve's file stays; reason says why and how to make a matching one),
    "missing" (not packaged / no such file)."""
    out = []
    for rel in dict.fromkeys(r[0] for r in OVERLAYS):
        rows = [r for r in OVERLAYS if r[0] == rel]
        dst = os.path.join(proton, rel)
        if not os.path.isfile(dst):
            out.append((rel, "missing", "%s has no %s (Proton's layout changed?)" % (os.path.basename(proton), rel), None))
            continue
        have = sha256(dst)
        row = next((r for r in rows if have == r[2]), None)
        if row:
            out.append((rel, "ours", "PowOS build in place", row))
            continue
        row = next((r for r in rows if have == r[1]), None)
        if row:
            src = os.path.join(here, row[3])
            if not os.path.isfile(src):
                out.append((rel, "missing", "our %s isn't packaged" % row[3], row))
            elif sha256(src) != row[2]:
                out.append((rel, "skip", "our %s isn't the file the table names (damaged copy)" % row[3], row))
            else:
                out.append((rel, "apply", "Valve's build %s: PowOS build goes in" % row[4], row))
            continue
        ver = proton_version(proton)
        tag = wine_tag(ver)
        out.append((rel, "skip", "%s %s has a Valve build (%s) we have no overlay for; Valve's file stays. Make one: "
                    "PROTON_VERSION=%s targets/android/steam/proton-overlay/build.sh%s"
                    % (os.path.basename(proton), ver or "(no version file)", have[:12], ver or "<version>",
                       "" if tag else " (wine tag unknown: set TAG=)"), None))
    return out
