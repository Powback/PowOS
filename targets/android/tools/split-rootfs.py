#!/usr/bin/env python3
"""Splits the full PowOS Android rootfs into the base image phones without root download first and the packs the
PowOS app adds on demand, by rootfs-packs.conf (see there). Streams the tarball twice (pacman's file lists, then the
split); nothing is unpacked to disk, so it runs on the Mac as well as in a container.

Usage: split-rootfs.py <full.tar.gz> <rules.conf> <outdir>
  writes <outdir>/powos-rootfs-base.tar.gz and <outdir>/powos-pack-<name>.tar.gz, each with its .sha256, and
  <outdir>/powos-packs.tsv (name, compressed bytes, unpacked bytes, files)."""
import fnmatch, hashlib, io, os, subprocess, sys, tarfile, time

def rules(path):
    out = []  # (kind, name, globs)
    for line in open(path):
        w = line.split('#', 1)[0].split()
        if not w:
            continue
        if w[0] in ('keep', 'drop'):
            out.append((w[0], None, 'path', w[1:]))
        elif w[0] == 'pack' and len(w) > 3 and w[2] in ('path', 'pkg'):
            out.append(('pack', w[1], w[2], w[3:]))
        else:
            sys.exit(f'{path}: bad line: {line.strip()}')
    return out

def pkg_files(tarball, wanted):
    """{path: pack} for every file of the packages the pkg rules name, from the rootfs's pacman database."""
    owner = {}
    with tarfile.open(tarball, 'r|gz') as t:
        for m in t:
            n = m.name.removeprefix('./')
            if not (n.startswith('var/lib/pacman/local/') and n.endswith('/files') and m.isfile()):
                continue
            pkg = n.split('/')[4].rsplit('-', 2)[0]
            if pkg in wanted:
                for l in t.extractfile(m).read().decode().splitlines():
                    if l and not l.startswith('%') and not l.endswith('/'):
                        owner[l] = wanted[pkg]
    return owner

class Out:
    def __init__(self, path):
        self.path, self.unpacked, self.files = path, 0, 0
        self.f = open(path, 'wb')
        self.gz = subprocess.Popen(['gzip', '-6'], stdin=subprocess.PIPE, stdout=self.f)
        self.tar = tarfile.open(fileobj=self.gz.stdin, mode='w|', format=tarfile.GNU_FORMAT)

    def add(self, m, data):
        self.tar.addfile(m, data)
        if m.isfile():
            self.unpacked += m.size
            self.files += 1

    def close(self):
        self.tar.close(); self.gz.stdin.close()
        if self.gz.wait():
            sys.exit(f'gzip failed for {self.path}')
        self.f.close()
        h = hashlib.sha256()
        with open(self.path, 'rb') as f:
            for b in iter(lambda: f.read(1 << 20), b''):
                h.update(b)
        with open(self.path + '.sha256', 'w') as f:
            f.write(f'{h.hexdigest()}  {os.path.basename(self.path)}\n')
        return os.path.getsize(self.path)

def main(tarball, conf, outdir):
    rs = rules(conf)
    wanted = {p: r[1] for r in rs if r[2] == 'pkg' for p in r[3]}
    owner = pkg_files(tarball, wanted)
    found = set(owner.values())
    for pack in set(wanted.values()) - found:
        print(f'split-rootfs: warning: pack {pack}: none of its packages is installed', file=sys.stderr)
    drops = [g for r in rs if r[0] == 'drop' for g in r[3]]

    def where(n):
        for kind, name, how, globs in rs:
            if how == 'pkg':
                if owner.get(n) == name:
                    return name
            elif any(fnmatch.fnmatchcase(n, g) for g in globs):
                return {'keep': 'base', 'drop': None}.get(kind, name)
        return 'base'

    os.makedirs(outdir, exist_ok=True)
    outs = {'base': Out(os.path.join(outdir, 'powos-rootfs-base.tar.gz'))}
    dropped = 0
    with tarfile.open(tarball, 'r|gz') as t:
        for m in t:
            n = m.name.removeprefix('./')
            dest = 'base' if m.isdir() else where(n)  # directories stay in the base: packs land in them
            if dest is None:
                dropped += m.size
                continue
            data = t.extractfile(m) if m.isfile() else None
            if n == 'etc/pacman.conf' and dest == 'base':
                # Keep pacman from bringing dropped files back with the next update.
                text = data.read().decode().replace('[options]\n', '[options]\nNoExtract = ' + ' '.join(drops) + '\n', 1)
                raw = text.encode(); m.size = len(raw); data = io.BytesIO(raw)
            if dest not in outs:
                outs[dest] = Out(os.path.join(outdir, f'powos-pack-{dest}.tar.gz'))
            outs[dest].add(m, data)
    sizes = {name: o.close() for name, o in outs.items() if name != 'base'}
    # The base's list of what it leaves out (play/powos-pack: name, download bytes, unpacked bytes); its presence is
    # what makes a rootfs a base install.
    listing = ''.join(f'{n}\t{sizes[n]}\t{outs[n].unpacked}\n' for n in sizes).encode()
    m = tarfile.TarInfo('./etc/powos/packs'); m.size = len(listing); m.mode = 0o644; m.mtime = int(time.time())
    outs['base'].add(m, io.BytesIO(listing))
    sizes['base'] = outs['base'].close()
    with open(os.path.join(outdir, 'powos-packs.tsv'), 'w') as tsv:
        for name, o in outs.items():
            tsv.write(f'{name}\t{sizes[name]}\t{o.unpacked}\t{o.files}\n')
            print(f'split-rootfs: {name}: {sizes[name] / 1e9:.2f} GB gz, {o.unpacked / 2**30:.2f} GiB unpacked, {o.files} files')
    print(f'split-rootfs: dropped {dropped / 2**30:.2f} GiB (docs)')

if __name__ == '__main__':
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
