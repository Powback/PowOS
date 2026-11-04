#!/usr/bin/env python3
"""Splits the full PowOS Android rootfs into the base image phones without root download first and the packs the
PowOS app adds on demand, by rootfs-packs.conf (see there). Streams the tarball twice (pacman's database, then the
split); nothing is unpacked to disk, so it runs on the Mac as well as in a container.

Usage: split-rootfs.py <full.tar.gz> <rules.conf> <outdir>
  writes <outdir>/powos-rootfs-base.tar.gz and <outdir>/powos-pack-<name>.tar.gz, each with its .sha256,
  <outdir>/powos-packs.tsv (name, compressed bytes, unpacked bytes, files) and <outdir>/powos-packs-plan.txt
  (which package went where, largest first).
       split-rootfs.py --plan <tar -tv listing> <pacman local db dir> <rules.conf>
  prints the same plan (unpacked sizes per pack and package) from a listing, without reading the tarball."""
import collections, fnmatch, glob, hashlib, io, os, re, subprocess, sys, tarfile, time


def rules(path):
    out = []  # (kind, name, how, words)
    for line in open(path):
        w = line.split('#', 1)[0].split()
        if not w:
            continue
        if w[0] in ('keep', 'drop'):
            out.append((w[0], None, 'path', w[1:]))
        elif w[0] == 'roots':
            out.append(('roots', None, 'pkg', w[1:]))
        elif w[0] == 'pack' and len(w) > 3 and w[2] in ('path', 'pkg'):
            out.append(('pack', w[1], w[2], w[3:]))
        elif w[0] == 'pack' and len(w) == 3 and w[2] == 'rest':
            out.append(('pack', w[1], 'rest', []))
        else:
            sys.exit(f'{path}: bad line: {line.strip()}')
    return out


def parse_desc(text):
    """{%SECTION%: [lines]} of a pacman local db desc file."""
    out, cur = {}, None
    for l in text.splitlines():
        if l.startswith('%') and l.endswith('%'):
            cur = out.setdefault(l, [])
        elif l and cur is not None:
            cur.append(l)
    return out


def bare(dep):
    return re.split(r'[<>=:]', dep, maxsplit=1)[0].strip()


def assign(rs, db):
    """{package: home} - 'base' or a pack name. db: {pkg: (depends, provides)}.
    Without roots every package is in the base. With roots: their dependency closure is the base, except packages a
    pack names (they leave it even when a root depends on them); each pack takes its packages plus their
    dependencies that are neither in the base nor in an earlier pack; 'rest' takes every package left."""
    providers = collections.defaultdict(set)
    for p, (_, prov) in db.items():
        providers[p].add(p)
        for v in prov:
            providers[bare(v)].add(p)
    explicit = {p for k, _, how, ws in rs if k == 'pack' and how == 'pkg' for p in ws}

    def closure(start, stop):
        seen, todo = set(), [p for p in start if p in db]
        while todo:
            p = todo.pop()
            if p in seen or p in stop:
                continue
            seen.add(p)
            for d in db[p][0]:
                todo.extend(providers.get(d, ()))
        return seen

    roots = [p for k, _, _, ws in rs if k == 'roots' for p in ws]
    for p in roots:
        if p not in db:
            print(f'split-rootfs: warning: root {p} is not installed', file=sys.stderr)
    home = {p: 'base' for p in closure(roots, explicit)}
    for k, name, how, ws in rs:
        if k == 'pack' and how == 'pkg':
            missing = [p for p in ws if p not in db]
            if missing:
                print(f'split-rootfs: warning: pack {name}: not installed: {" ".join(missing)}', file=sys.stderr)
            for p in closure(ws, set(home) - set(ws)):
                home.setdefault(p, name)
    rest = next((name for _, name, how, _ in rs if how == 'rest'), None)
    for p in db:
        home.setdefault(p, rest if (rest and roots) else 'base')
    return home


def classifier(rs, owner, home):
    """where(path) -> 'base', a pack name, or None (dropped). keep/drop first; then the owning package's home;
    then the path pack rules (unowned files, and a base package's translations)."""
    def where(n):
        for kind, name, how, globs in rs:
            if how == 'path' and kind in ('keep', 'drop') and any(fnmatch.fnmatchcase(n, g) for g in globs):
                return 'base' if kind == 'keep' else None
        pkg = owner.get(n)
        if pkg is not None and home.get(pkg, 'base') != 'base':
            return home[pkg]
        for kind, name, how, globs in rs:
            if how == 'path' and kind == 'pack' and any(fnmatch.fnmatchcase(n, g) for g in globs):
                return name
        return 'base'
    return where


def read_db(members):
    """(db, owner) from (path, bytes) pairs of var/lib/pacman/local/<pkg-ver>/{desc,files}."""
    db, dirs, owner = {}, {}, {}
    for n, data in members:
        if n.endswith('/desc'):
            d = parse_desc(data.decode())
            name = d['%NAME%'][0]
            db[name] = ([bare(x) for x in d.get('%DEPENDS%', [])], d.get('%PROVIDES%', []))
            dirs[n.split('/')[-2]] = name
    for n, data in members:
        if n.endswith('/files') and n.split('/')[-2] in dirs:
            pkg = dirs[n.split('/')[-2]]
            for l in data.decode().splitlines():
                if l and not l.startswith('%') and not l.endswith('/'):
                    owner[l] = pkg
    return db, owner


def db_from_tar(tarball):
    out = []
    with tarfile.open(tarball, 'r|gz') as t:
        for m in t:
            n = m.name.removeprefix('./')
            if n.startswith('var/lib/pacman/local/') and m.isfile() and n.endswith(('/desc', '/files')):
                out.append((n, t.extractfile(m).read()))
    return read_db(out)


def plan_text(by_pkg, totals):
    G = 1 << 30
    lines = [f'{name}\t{v / G:.2f} GiB unpacked' for name, v in sorted(totals.items(), key=lambda x: -x[1])]
    for name in sorted(totals, key=lambda x: -totals[x]):
        pk = sorted(((s, p) for (p, h), s in by_pkg.items() if h == name), reverse=True)
        lines.append(f'\n[{name}] ' + ', '.join(f'{p} {s / 2**20:.0f}M' for s, p in pk[:80] if s >= 2**20))
    return '\n'.join(lines) + '\n'


class Out:
    def __init__(self, path):
        self.path, self.unpacked, self.files = path, 0, 0
        # Written beside and renamed over (as rootfs-in-container.sh): out/ files are hard links (the published copy
        # in android-app-dev/output, other worktrees' out/), and writing one in place would change every link mid-build.
        self.tmp = os.path.join(os.path.dirname(path), '.' + os.path.basename(path) + '.new')
        self.f = open(self.tmp, 'wb')
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
        with open(self.tmp, 'rb') as f:
            for b in iter(lambda: f.read(1 << 20), b''):
                h.update(b)
        with open(self.tmp + '.sha256', 'w') as f:
            f.write(f'{h.hexdigest()}  {os.path.basename(self.path)}\n')
        os.replace(self.tmp, self.path)
        os.replace(self.tmp + '.sha256', self.path + '.sha256')
        return os.path.getsize(self.path)


def main(tarball, conf, outdir):
    rs = rules(conf)
    db, owner = db_from_tar(tarball)
    where = classifier(rs, owner, assign(rs, db))
    drops = [g for k, _, how, ws in rs if k == 'drop' for g in ws]
    os.makedirs(outdir, exist_ok=True)
    outs = {'base': Out(os.path.join(outdir, 'powos-rootfs-base.tar.gz'))}
    by_pkg, totals = collections.Counter(), collections.Counter()
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
            if m.isfile():
                by_pkg[(owner.get(n, '<unowned>'), dest)] += m.size
                totals[dest] += m.size
    sizes = {name: o.close() for name, o in outs.items() if name != 'base'}
    # The base's list of what it leaves out (play/powos-pack, the app's Storage list: name, download bytes, unpacked
    # bytes); its presence is what makes a rootfs a base install.
    listing = ''.join(f'{n}\t{sizes[n]}\t{outs[n].unpacked}\n' for n in sizes).encode()
    m = tarfile.TarInfo('./etc/powos/packs'); m.size = len(listing); m.mode = 0o644; m.mtime = int(time.time())
    outs['base'].add(m, io.BytesIO(listing))
    sizes['base'] = outs['base'].close()
    with open(os.path.join(outdir, 'powos-packs.tsv'), 'w') as tsv:
        for name, o in outs.items():
            tsv.write(f'{name}\t{sizes[name]}\t{o.unpacked}\t{o.files}\n')
            print(f'split-rootfs: {name}: {sizes[name] / 1e9:.2f} GB gz, {o.unpacked / 2**30:.2f} GiB unpacked, {o.files} files')
    with open(os.path.join(outdir, 'powos-packs-plan.txt'), 'w') as f:
        f.write(plan_text(by_pkg, totals))
    print(f'split-rootfs: dropped {dropped / 2**30:.2f} GiB (docs)')


def plan(listing, dbdir, conf):
    rs = rules(conf)
    members = [('var/lib/pacman/local/' + '/'.join(p.split('/')[-2:]), open(p, 'rb').read())
               for p in glob.glob(os.path.join(dbdir, '*', '*')) if p.endswith(('/desc', '/files'))]
    db, owner = read_db(members)
    where = classifier(rs, owner, assign(rs, db))
    by_pkg, totals = collections.Counter(), collections.Counter()
    for line in open(listing):
        p = line.split(None, 8)
        if len(p) < 9 or not p[0].startswith('-'):
            continue
        n = p[8].rstrip('\n').removeprefix('./')
        dest = where(n) or '<dropped>'
        by_pkg[(owner.get(n, '<unowned>'), dest)] += int(p[4])
        totals[dest] += int(p[4])
    sys.stdout.write(plan_text(by_pkg, totals))


if __name__ == '__main__':
    if len(sys.argv) == 5 and sys.argv[1] == '--plan':
        plan(*sys.argv[2:])
    elif len(sys.argv) == 4:
        main(*sys.argv[1:])
    else:
        sys.exit(__doc__)
