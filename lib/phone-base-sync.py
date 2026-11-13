#!/usr/bin/env python3
"""phone-base-sync.py - the packages a phone's base image should have but doesn't: an image split before a package
joined the base (rootfs-packs.conf `roots`) left its files in a pack the phone never added. pacman lists it as
installed, so no update brings it back (razr 11-10: spacetimedb-2.12.0-1 installed, /usr/lib/spacetimedb/2.12.0 empty,
no SpacetimeDB for any PowOS app). lib/phone-update.sh reinstalls what this prints (docs/PHONE-UPDATES.md, "base").

  phone-base-sync.py [--root R] [--conf rootfs-packs.conf]   one package name per line, nothing on a full rootfs

A package counts when most of the files today's split puts in the base are missing from disk: a whole package left in
a pack, not one file a script removed on purpose. A pack the phone added has its files there, so it never counts.
Uses tools/split-rootfs.py's own rules (the same classification the image build applies)."""
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.realpath(__file__))
SPLIT = [os.environ.get("POWOS_SPLIT_ROOTFS", ""), "/usr/lib/powos/split-rootfs.py",
         os.path.join(HERE, "..", "targets", "android", "tools", "split-rootfs.py")]
CONF = [os.environ.get("POWOS_PACKS_CONF", ""), "/usr/share/powos/rootfs-packs.conf",
        os.path.join(HERE, "..", "targets", "android", "rootfs-packs.conf")]


def first(paths):
    return next((p for p in paths if p and os.path.isfile(p)), None)


def load_split():
    p = first(SPLIT)
    if not p:
        sys.exit("phone-base-sync: no split-rootfs.py")
    spec = importlib.util.spec_from_file_location("split_rootfs", p)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def local_db(root):
    d = os.path.join(root, "var/lib/pacman/local")
    members = []
    for e in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        for f in ("desc", "files"):
            p = os.path.join(d, e, f)
            if os.path.isfile(p):
                with open(p, "rb") as fh:
                    members.append((f"var/lib/pacman/local/{e}/{f}", fh.read()))
    return members


def missing(root, conf):
    split = load_split()
    rs = split.rules(conf)
    db, owner = split.read_db(local_db(root))
    home = split.assign(rs, db)
    where = split.classifier(rs, owner, home)
    by_pkg = {}
    for path, pkg in owner.items():
        if home.get(pkg) == "base":
            by_pkg.setdefault(pkg, []).append(path)
    out = []
    for pkg in sorted(by_pkg):
        gone = [f for f in by_pkg[pkg] if not os.path.lexists(os.path.join(root, f))]
        if not gone:
            continue  # the common case, without classifying a single path
        fs = [f for f in by_pkg[pkg] if where(f) == "base"]
        gone = [f for f in gone if where(f) == "base"]
        if fs and len(gone) * 2 > len(fs):
            out.append(pkg)
    # A root the image never had (github-cli joined after the razr's base): installed too, unless something installed
    # provides it already (vulkan-freedreno-kgsl for vulkan-freedreno).
    provided = {split.bare(v) for _, prov in db.values() for v in prov} | set(db)
    for k, _, _, ws in rs:
        if k == "roots":
            out.extend(p for p in ws if p not in provided and p not in out)
    return out


def main(a):
    root, conf = "/", None
    while a:
        k = a.pop(0)
        if k == "--root" and a:
            root = a.pop(0)
        elif k == "--conf" and a:
            conf = a.pop(0)
        else:
            sys.exit(__doc__)
    # A full rootfs (rooted phones, base-less builds) has no pack list: nothing was split off.
    if not os.path.exists(os.path.join(root, "etc/powos/packs")):
        return
    conf = conf or first(CONF)
    if not conf:
        sys.exit("phone-base-sync: no rootfs-packs.conf")
    # ~20 s of classifying on a phone: done again only when the packages, the rules or the added packs changed.
    def stat(p):
        try:
            st = os.stat(os.path.join(root, p))
            return f"{st.st_mtime_ns}:{st.st_size}"
        except OSError:
            return "-"
    packs = os.path.join(root, "var/lib/powos/packs")
    key = " ".join([stat("var/lib/pacman/local"), stat(conf), stat("var/lib/powos/packs"),
                    ",".join(sorted(os.listdir(packs))) if os.path.isdir(packs) else "-"])
    cache = os.path.join(root, "var/lib/powos/base-sync.cache")
    try:
        with open(cache) as f:
            lines = f.read().splitlines()
        if lines and lines[0] == key:
            for p in lines[1:]:
                if p:
                    print(p)
            return
    except OSError:
        pass
    out = missing(root, conf)
    try:
        os.makedirs(os.path.dirname(cache), exist_ok=True)
        with open(cache, "w") as f:
            f.write(key + "\n" + "".join(p + "\n" for p in out))
    except OSError:
        pass
    for p in out:
        print(p)


if __name__ == "__main__":
    main(sys.argv[1:])
