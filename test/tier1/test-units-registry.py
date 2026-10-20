#!/usr/bin/env python3
"""test-units-registry.py - nothing is installed on a host without a unit (lib/apps/powos-units, units/<host>/).

The rule (CLAUDE.md, capabilities.md "Units"): whatever a deploy puts on a host - a file, a package, a process - is
registered as a unit with an owner, a purpose, limits and a way out. Without a check the rule rots the first time a
deploy grows a line, so this reads every deploy script and fails on anything it installs that no unit in units/ claims.

Deploy scripts: tracked shell files under targets/ named *deploy*.sh, or carrying the line `# powos-units: deploy`.
What counts as installing, line by line (inside quoted remote commands too): install, cp, ln -s, sed -i, a redirect
(> / >>) to a path, pacman -S / -U, apt-get install, brew install. Variables are followed as the script assigns them
($R is PowOS's root on the phone -> host "phone"; other /data/... -> "phone-android"; /data/local/tmp, /tmp and /dev
are staging, never installs). A destination this can't read literally is written down before the command:
`# powos-units: <path-pattern> ...` - the patterns that line installs.

Also: every manifest in units/ is valid (lib/apps/powos-units' own validation), ids are unique per host, and the
checker itself flags an install no unit claims (a synthetic deploy script).

Usage:  python3 test/tier1/test-units-registry.py
"""
import glob
import json
import os
import re
import subprocess
import sys
import tempfile
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader

ROOT = os.path.realpath(os.path.join(os.path.dirname(__file__), "..", ".."))
PASS = FAIL = 0


def ok(msg):
    global PASS
    PASS += 1
    print(f"  ok   - {msg}")


def bad(msg):
    global FAIL
    FAIL += 1
    print(f"  FAIL - {msg}")


os.environ["POWOS_UNITS_DIR"] = tempfile.mkdtemp()  # never the host's own registry
loader = SourceFileLoader("powos_units", os.path.join(ROOT, "lib", "apps", "powos-units"))
units = module_from_spec(spec_from_loader("powos_units", loader))
loader.exec_module(units)

# units/<dir>/ -> the host its manifests describe (the system module's are Android's side, shipped in the module).
HOST_OF_DIR = {"system-module": "phone-android"}


def manifests():
    out = {}
    for d in sorted(glob.glob(os.path.join(ROOT, "units", "*", ""))):
        name = os.path.basename(os.path.dirname(d))
        host = HOST_OF_DIR.get(name, name)
        for p in sorted(glob.glob(os.path.join(d, "*.json"))):
            out.setdefault(host, []).append((p, json.load(open(p))))
    return out


def claimed_by(host_units, dest, edits=True):
    for _, u in host_units:
        for f in (u.get("files") or []) + ((u.get("edits") or []) if edits else []):
            if units.claims(os.path.expanduser(f), dest):
                return u["id"]
    return None


# ── what a deploy script installs ───────────────────────────────────────────

STAGING = ("/data/local/tmp", "/tmp", "/dev/", "/proc", "/sys", "/run")
ASSIGN = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=([^\s;&|]*)")
VAR = re.compile(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?")


def expand(word, env):
    word = word.strip("'\"")
    word = re.sub(r"\$\([^)]*\)", "*", word)
    word = re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", lambda m: env.get(m.group(1), "*"), word)
    word = re.sub(r"\$\{[^}]*\}", "*", word)
    for _ in range(5):
        new = VAR.sub(lambda m: env.get(m.group(1), "*"), word)
        if new == word:
            break
        word = new
    return word.replace("\\", "")


def host_of(path):
    """(host, path on that host), or None for staging and things that are not paths."""
    if not path.startswith("/") and not path.startswith("*/"):
        return None
    if path.startswith("/data/powos/root/") or path == "/data/powos/root":
        p = path[len("/data/powos/root"):] or "/"
        return None if p.startswith(STAGING) or p == "/" else ("phone", p)
    if path.startswith(STAGING) or path in ("/dev/null",):
        return None
    if path.startswith("/data/"):
        return "phone-android", path
    if path.startswith("*"):
        return None
    return "phone", path   # absolute paths in the scripts' chroot commands are PowOS's


def commands(line):
    """The shell commands in a line, quoted remote commands (asu "...", sh -c '...') included."""
    parts = re.split(r"\s*(?:&&|\|\||;|\||\bthen\b|\bdo\b|\belse\b)\s*", line)
    out = []
    for p in parts:
        p = p.strip().lstrip("({").strip()
        m = re.match(r"^(?:asu|adb shell|su -c|sh -c|bash -c)\s+[\"'](.*)$", p)
        out.append(m.group(1) if m else p)
    return [c for c in out if c]


def installs(script):
    """[(lineno, kind, host, what)] - kind: file | package."""
    env = {"R": "/data/powos/root", "HOME": "/home/powos"}
    out, override = [], None
    lines = open(script, errors="replace").read().splitlines()
    for n, raw in enumerate(lines, 1):
        line = raw.strip()
        m = re.match(r"^#\s*powos-units:\s*(.*)$", line)
        if m:
            if not m.group(1).strip().startswith("deploy"):
                override = m.group(1).split()
            continue
        if not line or line.startswith("#"):
            continue
        a = ASSIGN.match(line)
        if a and not line.startswith(("if ", "for ")):
            env[a.group(1)] = expand(a.group(2), env)
        found = []
        for c in commands(line):
            words = c.split()
            if not words:
                continue
            cmd = words[0]
            if cmd in ("install", "cp", "ln") or (cmd == "sed" and "-i" in words):
                args = [w for w in words[1:] if not w.startswith("-") and w not in ("644", "755", "440", "600")]
                if cmd == "install":
                    args = [w for i, w in enumerate(words[1:], 1) if not w.startswith("-")
                            and words[i - 1] not in ("-m", "-o", "-g")]
                if len(args) >= (1 if cmd == "sed" else 2):
                    found.append(("file", args[-1]))
            for r in re.finditer(r"(?<![0-9&])>>?\s*([^\s;&|)]+)", c):
                found.append(("file", r.group(1)))
            pm = re.search(r"\bpacman\s+(-S|-U)\b(.*)", c)
            if pm:
                for w in pm.group(2).split():
                    w = w.strip("'\";)")
                    if w.startswith("-") or w in ("4", ">/dev/null", "2>&1") or not w or w.startswith(">"):
                        continue
                    if pm.group(1) == "-U":
                        w = re.sub(r"-\d.*$", "", os.path.basename(expand(w, env)))
                    found.append(("package", w))
            for pm2 in re.finditer(r"\b(?:apt-get|apt)\s+install\b(.*)|\bbrew\s+install\b(.*)", c):
                for w in (pm2.group(1) or pm2.group(2) or "").split():
                    if not w.startswith("-"):
                        found.append(("package", w.strip("'\";")))
        if override is not None and found:
            files = [f for f in override if not f.startswith("pkg:")]
            pkgs = [f[4:] for f in override if f.startswith("pkg:")]
            found = [("file", f) for f in files] + [("package", p) for p in pkgs]
            override = None
            for kind, what in found:
                h = host_of(what) if kind == "file" else ("phone", what)
                if h:
                    out.append((n, kind, h[0], h[1]))
            continue
        for kind, what in found:
            if kind == "package":
                out.append((n, kind, "phone", what))
                continue
            dest = expand(what, env)
            h = host_of(dest)
            if h:
                out.append((n, kind, h[0], h[1].rstrip("/") or "/"))
    return list(dict.fromkeys(out))


def deploy_scripts():
    files = subprocess.run(["git", "-C", ROOT, "ls-files", "targets"], capture_output=True, text=True).stdout.split()
    out = []
    for f in files:
        p = os.path.join(ROOT, f)
        if not f.endswith(".sh") and "rooted/" not in f:
            continue
        try:
            text = open(p, errors="replace").read()
        except OSError:
            continue
        if "deploy" in os.path.basename(f) and f.endswith(".sh") or "# powos-units: deploy" in text:
            out.append(p)
    return out


def uncovered(script, ms):
    miss = []
    for n, kind, host, what in installs(script):
        hu = ms.get(host, [])
        if kind == "package":
            if not any(what in (u.get("packages") or []) for _, u in hu):
                miss.append(f"{os.path.relpath(script, ROOT)}:{n}: package {what} ({host}) - no unit lists it")
        elif units.ignored(what):
            continue  # the registry's own directory and the like
        elif not claimed_by(hu, what):
            miss.append(f"{os.path.relpath(script, ROOT)}:{n}: {what} ({host}) - no unit in units/{host}/ claims it")
    return miss


def main():
    print("== unit registry (units/, lib/apps/powos-units) ==")
    ms = manifests()
    if not ms:
        bad("no manifests in units/")
    n = 0
    for host, items in sorted(ms.items()):
        seen = {}
        for p, u in items:
            n += 1
            errs = units.validate(units.norm(u, p))
            if errs:
                bad(f"{os.path.relpath(p, ROOT)}: {'; '.join(errs)}")
            if u.get("id") in seen:
                bad(f"{host}: id {u['id']} in both {seen[u['id']]} and {os.path.basename(p)}")
            seen[u.get("id")] = os.path.basename(p)
            if os.path.basename(p) != f"{u.get('id')}.json":
                bad(f"{os.path.relpath(p, ROOT)}: file name is not <id>.json ({u.get('id')})")
    if not FAIL:
        ok(f"{n} manifests valid, ids unique per host")

    scripts = deploy_scripts()
    if not scripts:
        bad("no deploy scripts found under targets/ (the discovery broke)")
    for s in scripts:
        miss = uncovered(s, ms)
        if miss:
            for m in miss:
                bad(m + "  -> add it to a unit in units/<host>/ (or a `# powos-units:` line if the path is computed)")
        else:
            k = len(installs(s))
            ok(f"{os.path.relpath(s, ROOT)}: all {k} install(s) registered")

    # The checker itself: a deploy that installs something no unit claims must be caught.
    with tempfile.NamedTemporaryFile("w", suffix="-deploy.sh", delete=False) as t:
        t.write('R=/data/powos/root\ninstall -m 755 $T/x $R/usr/local/bin/sneaky-daemon\n'
                'chroot $R sh -c "pacman -S --noconfirm left-pad"\n')
    miss = uncovered(t.name, ms)
    os.unlink(t.name)
    if any("sneaky-daemon" in m for m in miss) and any("left-pad" in m for m in miss):
        ok("an unregistered install in a deploy script is caught (file and package)")
    else:
        bad(f"the checker missed an unregistered install: {miss}")

    # The tool's own CLI: every verb its help documents dispatches (read from its table, never run here).
    out = subprocess.run([sys.executable, os.path.join(ROOT, "lib", "apps", "powos-units"), "--help"],
                         capture_output=True, text=True).stdout
    verbs = set(re.findall(r"^  powos units \[?(\w+)", out, re.M))
    missing = sorted(v for v in verbs if v not in units.COMMANDS)
    if missing:
        bad(f"powos units --help documents {missing}, which don't dispatch")
    elif verbs >= {"list", "show", "check", "remove", "register", "unregister", "enforce"}:
        ok(f"powos units --help documents {', '.join(sorted(verbs))}; each dispatches")
    else:
        bad(f"powos units --help lacks verbs: {sorted({'list', 'show', 'check', 'remove'} - verbs)}")

    # remove --dry-run changes nothing and shows the plan.
    d = os.environ["POWOS_UNITS_DIR"]
    f = os.path.join(d, "probe.json")
    json.dump({"id": "probe", "owner": "user", "purpose": "test", "files": [os.path.join(d, "nothing-here")]},
              open(f, "w"))
    r = subprocess.run([sys.executable, os.path.join(ROOT, "lib", "apps", "powos-units"), "remove", "probe",
                        "--dry-run"], capture_output=True, text=True, env=os.environ)
    if r.returncode == 0 and "the plan" in r.stdout and os.path.exists(f):
        ok("remove --dry-run shows the plan and changes nothing")
    else:
        bad(f"remove --dry-run: {r.returncode} {r.stdout[-200:]} {r.stderr[-200:]}")

    print(f"\n== Results: {PASS} passed, {FAIL} failed ==")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
