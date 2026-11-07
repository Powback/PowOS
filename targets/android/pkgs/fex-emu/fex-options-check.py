#!/usr/bin/env python3
# fex-options-check.py: every FEX option and thunk library PowOS sets must still exist in the FEX it builds against.
# FEX renames/drops options between monthly releases; FEX ignores an unknown key in Config.json and an unknown FEX_*
# variable silently, so a renamed option would turn a fix off without a word. This fails the build loudly instead
# ("fex option X not in FEX-2611: ..."), the moment a pkgver bump would lose it.
#
# Usage: fex-options-check.py --fex <FEX source tree> [file...] [--opts "A:1,B:1"]
#   file: a FEX JSON config ({"Config": {Option: ...}}), a thunks config ({"ThunksDB": {Lib: 0|1}}), or any text file
#         whose FEX_<OPTION> words are FEX options (steam-env, scripts, user_settings.py).
#   --opts: a STEAM_COMPAT_FEX_CONFIG-style list ("Option:value,..."; ThunksDB_<Lib> names a thunk library).
# Options come from FEXCore/Source/Interface/Config/Config.json.in, thunk libraries from Data/ThunksDB.json.
import json
import os
import re
import sys

# FEX_* names that are not Config.json.in options (FEX's own tools/env, or ours).
NOT_OPTIONS = {"FEX_APP_CONFIG_LOCATION", "FEX_APP_DATA_LOCATION", "FEX_APP_CACHE_LOCATION", "FEX_STEAM_SUPPORT",
               "FEX_ROOTFS_FETCHER", "FEX_COMPAT_TOOL"}


def fex_names(src):
    t = json.load(open(os.path.join(src, "FEXCore/Source/Interface/Config/Config.json.in")))
    opts = set()
    for group in ("Options", "UnnamedOptions"):
        for sect in t.get(group, {}).values():
            opts.update(sect)
    libs = set(json.load(open(os.path.join(src, "Data/ThunksDB.json")))["DB"])
    return opts, libs


def main(argv):
    if len(argv) < 3 or argv[1] != "--fex":
        sys.exit(__doc__ or "usage: fex-options-check.py --fex <src> [file...] [--opts LIST]")
    src, rest = argv[2], argv[3:]
    opts, libs = fex_names(src)
    upper = {o.upper(): o for o in opts}
    ver = os.environ.get("FEX_VERSION") or os.path.basename(os.path.abspath(src))
    bad, n = [], 0

    def opt(name, where):
        nonlocal n
        n += 1
        if name not in opts:
            bad.append("fex option %s (%s) not in %s: renamed or dropped upstream" % (name, where, ver))

    def lib(name, where):
        nonlocal n
        n += 1
        if name not in libs:
            bad.append("fex thunk library %s (%s) not in %s's ThunksDB.json" % (name, where, ver))

    def opts_list(s, where):
        for kv in filter(None, s.split(",")):
            k = kv.split(":", 1)[0]
            lib(k[len("ThunksDB_"):], where) if k.startswith("ThunksDB_") else opt(k, where)

    i = 0
    while i < len(rest):
        a = rest[i]
        if a == "--opts":
            opts_list(rest[i + 1], "--opts")
            i += 2
            continue
        where = os.path.basename(a)
        text = open(a, encoding="utf-8", errors="replace").read()
        try:
            j = json.loads(text)
        except ValueError:
            j = None
        if isinstance(j, dict) and "Config" in j:
            for k in j["Config"]:
                opt(k, where)
        elif isinstance(j, dict) and "ThunksDB" in j:
            for k in j["ThunksDB"]:
                lib(k, where)
        else:
            # FEX_<OPTION> words outside comments; STEAM_COMPAT_FEX_CONFIG=... lists.
            for line in text.splitlines():
                code = line.split("#", 1)[0]
                for m in re.finditer(r"\bFEX_([A-Z0-9_]+)\b", code):
                    w = "FEX_" + m.group(1)
                    if w in NOT_OPTIONS:
                        continue
                    n += 1
                    if m.group(1) not in upper:
                        bad.append("fex option %s (%s) not in %s: renamed or dropped upstream" % (w, where, ver))
                for m in re.finditer(r"STEAM_COMPAT_FEX_CONFIG:-([A-Za-z0-9_:,]+)", code):
                    opts_list(m.group(1), where)
        i += 1
    for b in bad:
        print(b, file=sys.stderr)
    print("fex-options-check: %d names, %d missing in %s" % (n, len(bad), ver))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
