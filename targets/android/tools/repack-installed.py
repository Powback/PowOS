#!/usr/bin/env python3
"""Rebuilds pacman packages from what is installed (pacman-contrib's old bacman, which it no longer ships).

Usage: repack-installed.py <outdir> <package>...   (inside the rootfs, as root: reads /var/lib/pacman/local)

Each package's .PKGINFO and .INSTALL come from its local database entry, its files from the file list there. Used by
plasma-pin.sh to keep Plasma at our KWin's version (see the HACK note there).
"""
import os, subprocess, sys, tarfile, io

DB = "/var/lib/pacman/local"
FIELDS = [("NAME", "pkgname"), ("BASE", "pkgbase"), ("VERSION", "pkgver"), ("DESC", "pkgdesc"), ("URL", "url"),
          ("BUILDDATE", "builddate"), ("PACKAGER", "packager"), ("SIZE", "size"), ("ARCH", "arch"),
          ("LICENSE", "license"), ("GROUPS", "group"), ("REPLACES", "replaces"), ("DEPENDS", "depend"),
          ("OPTDEPENDS", "optdepend"), ("CONFLICTS", "conflict"), ("PROVIDES", "provides")]


def sections(path):
    out, key = {}, None
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        if line.startswith("%") and line.endswith("%"):
            key = line[1:-1]; out[key] = []
        elif line and key:
            out[key].append(line)
    return out


def entry(name):
    for d in os.listdir(DB):
        if d.rsplit("-", 2)[0] == name and os.path.isfile(f"{DB}/{d}/desc"):
            desc = sections(f"{DB}/{d}/desc")
            if desc.get("NAME") == [name]:
                return f"{DB}/{d}", desc
    sys.exit(f"repack-installed: {name} is not installed")


def repack(outdir, name):
    d, desc = entry(name)
    files = sections(f"{d}/files")
    info = [f"{k} = {v}" for f, k in FIELDS for v in desc.get(f, [])]
    info += [f"backup = {b.split(chr(9))[0]}" for b in files.get("BACKUP", [])]
    out = f"{outdir}/{name}-{desc['VERSION'][0]}-{desc['ARCH'][0]}.pkg.tar.zst"
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.GNU_FORMAT) as t:
        def meta(n, data):
            ti = tarfile.TarInfo(n); ti.size = len(data); ti.mode = 0o644; t.addfile(ti, io.BytesIO(data))
        meta(".PKGINFO", ("\n".join(["# repacked from the installed files (targets/android/tools/repack-installed.py)"] + info) + "\n").encode())
        if os.path.isfile(f"{d}/install"):
            meta(".INSTALL", open(f"{d}/install", "rb").read())
        for f in files.get("FILES", []):
            p = "/" + f.rstrip("/")
            if not os.path.lexists(p):
                sys.exit(f"repack-installed: {name}: {p} is missing from the rootfs")
            t.add(p, arcname=f.rstrip("/"), recursive=False)
    subprocess.run(["zstd", "-q", "-T0", "-9", "-o", out], input=buf.getvalue(), check=True)
    return out


if __name__ == "__main__":
    for n in sys.argv[2:]:
        print(repack(sys.argv[1], n))
