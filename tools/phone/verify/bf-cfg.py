#!/usr/bin/env python3
"""bf-cfg.py: (in the PowOS session as powos, Steam NOT running) a Steam game's compat tool and launch options.

    bf-cfg.py get <appid>                 prints  tool=<CompatToolMapping name or -> opts=<LaunchOptions or ->
    bf-cfg.py tool <appid> <name|->       config.vdf CompatToolMapping: that tool (priority 250), or none (-): the
                                          game's native Linux build (Steam swaps the depot at its next launch)
    bf-cfg.py opts <appid> <text|->       every user's localconfig.vdf LaunchOptions for the app, or none

Steam rewrites both files from memory when it exits: an edit while it runs is lost, so this refuses then. Each edit
keeps the file as it was in <file>.powos-bak-<YYYYmmdd-HHMMSS> first. Only the block in question changes; the rest of
the file stays byte for byte (same tokenizer as targets/android/steam/unity-screen).
"""
import glob
import os
import re
import shutil
import sys
import time

S = os.path.expanduser("~/.local/share/Steam")
CONFIG = os.path.join(S, "config/config.vdf")
TOOLS = ["installconfigstore", "software", "valve", "steam", "compattoolmapping"]
APPS = ["userlocalconfigstore", "software", "valve", "steam", "apps"]


def steam_running():
    try:
        pid = open(os.path.expanduser("~/.steam/steam.pid")).read().strip()
        exe = os.readlink("/proc/%s/exe" % pid)
    except OSError:
        return False
    return exe.endswith("/steam") or "FEX" in exe


def tokens(t):
    return [(m.start(), m.end(), m.group()) for m in re.finditer(r'"(?:[^"\\]|\\.)*"|[{}]', t)]


def find(t, parent, key):
    """(block start token index, end token index) of `key`'s block under the key path `parent`, else None;
    and the parent's own (start, end)."""
    tok, stack, k, found, par = tokens(t), [], None, None, None
    for i, (_, _, v) in enumerate(tok):
        if v == "{":
            stack.append(((k or "").strip('"').lower(), i)); k = None
        elif v == "}":
            name, start = stack.pop()
            path = [n for n, _ in stack] + [name]
            if path == parent:
                par = (start, i)
            elif path == parent + [key.lower()]:
                found = (start, i)
            k = None
        else:
            k = v if k is None else None
    return tok, found, par


def line_span(t, s, e):
    ls = t.rfind("\n", 0, s) + 1
    le = t.find("\n", e)
    return ls, (len(t) if le < 0 else le + 1)


def child_value(t, tok, block, key):
    s, e = block
    depth = 0
    for j in range(s, e):
        v = tok[j][2]
        if v == "{": depth += 1
        elif v == "}": depth -= 1
        elif depth == 1 and v.lower() == '"%s"' % key.lower() and tok[j + 1][2] not in "{}":
            return j
    return None


def backup(path):
    b, n = "%s.powos-bak-%s" % (path, time.strftime("%Y%m%d-%H%M%S")), 1
    while os.path.exists(b):  # two edits in one second: never overwrite the older copy
        b, n = "%s.powos-bak-%s.%d" % (path, time.strftime("%Y%m%d-%H%M%S"), n), n + 1
    shutil.copy2(path, b)
    return b


def write(path, t):
    tmp = path + ".powos-tmp"
    with open(tmp, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(t); f.flush(); os.fsync(f.fileno())
    os.replace(tmp, path)


def read(path):
    return open(path, encoding="utf-8", errors="surrogateescape").read()


def get_tool(appid):
    t = read(CONFIG)
    tok, blk, _ = find(t, TOOLS, appid)
    if not blk:
        return "-"
    j = child_value(t, tok, blk, "name")
    return tok[j + 1][2].strip('"') if j is not None else "-"


def set_tool(appid, name):
    t = read(CONFIG)
    tok, blk, par = find(t, TOOLS, appid)
    if par is None:
        sys.exit("bf-cfg: no CompatToolMapping in " + CONFIG)
    ind = "\t" * len(TOOLS)  # the appid's key; its children one deeper
    new = "" if name == "-" else (
        '%s"%s"\n%s{\n%s\t"name"\t\t"%s"\n%s\t"config"\t\t""\n%s\t"priority"\t\t"250"\n%s}\n'
        % (ind, appid, ind, ind, name, ind, ind, ind))
    if blk:  # the key line before the block's "{" up to its "}" line
        ks = line_span(t, tok[blk[0] - 1][0], tok[blk[0] - 1][1])[0]
        ke = line_span(t, tok[blk[1]][0], tok[blk[1]][1])[1]
    else:
        ks = ke = line_span(t, tok[par[1]][0], tok[par[1]][1])[0]
    b = backup(CONFIG)
    write(CONFIG, t[:ks] + new + t[ke:])
    print("config.vdf: %s compat tool %s (backup %s)" % (appid, name, b))


def localconfigs():
    return sorted(glob.glob(os.path.join(S, "userdata/*/config/localconfig.vdf")))


def get_opts(appid):
    for c in localconfigs():
        t = read(c)
        tok, blk, _ = find(t, APPS, appid)
        if blk:
            j = child_value(t, tok, blk, "LaunchOptions")
            if j is not None:
                return tok[j + 1][2][1:-1].replace('\\"', '"').replace("\\\\", "\\")
    return "-"


def set_opts(appid, text):
    for c in localconfigs():
        t = read(c)
        tok, blk, par = find(t, APPS, appid)
        val = text.replace("\\", "\\\\").replace('"', '\\"')
        ind = "\t" * (len(APPS) + 1)
        line = "" if text == "-" else '%s"LaunchOptions"\t\t"%s"\n' % (ind, val)
        if blk:
            j = child_value(t, tok, blk, "LaunchOptions")
            if j is not None:
                s, e = line_span(t, tok[j][0], tok[j + 1][1])
            else:
                s = e = line_span(t, tok[blk[1]][0], tok[blk[1]][1])[0]
            t = t[:s] + line + t[e:]
        elif text != "-":
            if par is None:
                continue
            s = line_span(t, tok[par[1]][0], tok[par[1]][1])[0]
            k = ind[:-1]  # the appid's key; LaunchOptions one deeper
            t = t[:s] + '%s"%s"\n%s{\n%s%s}\n' % (k, appid, k, line, k) + t[s:]
        else:
            continue
        b = backup(c)
        write(c, t)
        print("%s: %s LaunchOptions %s (backup %s)" % (c, appid, text, b))


def main(a):
    if len(a) < 2 or a[0] not in ("get", "tool", "opts") or (a[0] != "get" and len(a) != 3):
        sys.exit(__doc__)
    if a[0] == "get":
        print("tool=%s opts=%s" % (get_tool(a[1]), get_opts(a[1])))
        return
    if steam_running():
        sys.exit("bf-cfg: Steam is running - close it first (it rewrites its config files on exit)")
    (set_tool if a[0] == "tool" else set_opts)(a[1], a[2])


if __name__ == "__main__":
    main(sys.argv[1:])
