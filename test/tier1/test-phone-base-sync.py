#!/usr/bin/env python3
"""lib/phone-base-sync.py: which packages an older base image lacks (gh#13, razr 11-10: spacetimedb installed per
pacman but its files left in the apps pack). A fake root with a pacman local db and a small rootfs-packs.conf."""
import os, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SYNC = os.path.join(ROOT, "lib", "phone-base-sync.py")
CONF = """drop usr/share/doc/*
roots base spacetimedb tmux newroot provided
pack apps pkg brave
pack apps rest
"""
fail = 0


def check(cond, what):
    global fail
    print(f"  {'ok' if cond else 'FAIL'}: {what}")
    fail |= not cond


def pkg(r, name, files, present, deps=(), provides=()):
    d = os.path.join(r, "var/lib/pacman/local", f"{name}-1-1")
    os.makedirs(d)
    with open(os.path.join(d, "desc"), "w") as f:
        f.write(f"%NAME%\n{name}\n\n%VERSION%\n1-1\n\n")
        if deps:
            f.write("%DEPENDS%\n" + "\n".join(deps) + "\n\n")
        if provides:
            f.write("%PROVIDES%\n" + "\n".join(provides) + "\n\n")
    with open(os.path.join(d, "files"), "w") as f:
        f.write("%FILES%\n" + "".join(x + "\n" for x in files))
    for x in files[:present]:
        p = os.path.join(r, x)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "w").close()


def run(r, conf):
    out = subprocess.run([sys.executable, "-I", SYNC, "--root", r, "--conf", conf], capture_output=True, text=True)
    return out.stdout.split()


with tempfile.TemporaryDirectory() as r:
    conf = os.path.join(r, "packs.conf")
    open(conf, "w").write(CONF)
    pkg(r, "base", ["usr/bin/base", "usr/share/doc/base/README"], 1, deps=["libz"])   # doc dropped: complete
    pkg(r, "libz", ["usr/lib/libz.so"], 1)
    pkg(r, "spacetimedb", ["usr/bin/spacetime", "usr/lib/spacetimedb/a", "usr/lib/spacetimedb/b"], 0)
    pkg(r, "tmux", ["usr/bin/tmux", "usr/share/tmux/x", "usr/share/tmux/y"], 2)        # one file gone: on purpose
    pkg(r, "brave", ["usr/bin/brave"], 0)                                                # pack package: not base
    pkg(r, "kgsl", ["usr/lib/kgsl.so"], 1, provides=["provided=1"])
    os.makedirs(os.path.join(r, "etc/powos"))
    check(run(r, conf) == [], "a full rootfs (no /etc/powos/packs): nothing")
    open(os.path.join(r, "etc/powos/packs"), "w").write("apps 1 2\n")
    got = run(r, conf)
    check("spacetimedb" in got, f"a base package left in a pack is named ({got})")
    check("newroot" in got, "a root the image never had is named")
    check(not {"base", "libz", "tmux", "brave", "provided"} & set(got),
          "complete, partly-trimmed, pack and provided packages aren't")
    check(os.path.isfile(os.path.join(r, "var/lib/powos/base-sync.cache")) and run(r, conf) == got, "cached, same answer")
    for x in ["usr/bin/spacetime", "usr/lib/spacetimedb/a", "usr/lib/spacetimedb/b"]:
        os.makedirs(os.path.dirname(os.path.join(r, x)), exist_ok=True)
        open(os.path.join(r, x), "w").close()
    os.rename(os.path.join(r, "var/lib/pacman/local/spacetimedb-1-1"), os.path.join(r, "var/lib/pacman/local/spacetimedb-1-2"))  # pacman's reinstall

    check("spacetimedb" not in run(r, conf), "after the reinstall: complete")
sys.exit(fail)
