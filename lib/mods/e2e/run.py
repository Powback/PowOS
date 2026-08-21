#!/usr/bin/env python3
"""`powos mods e2e` — drive a game and assert on what it actually does.

The generic half of end-to-end mod testing. Everything game-specific lives in
two places and nowhere else:

  * `config/mods/games.d/<game>.conf`  — declares how the game is launched,
    where its logs are, and how to read its state.
  * `lib/mods/e2e/scenarios/<game>.py` — the test cases themselves.

Adding a third game is those two files. The launch, the virtual controllers,
the state polling, the screenshots and the verdict are shared.

See CONTRACT.md in this directory for what a game must expose to be testable.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import logs as logs_mod          # noqa: E402
import pads as pads_mod          # noqa: E402
import proc as proc_mod          # noqa: E402
import report as report_mod      # noqa: E402
import shot as shot_mod          # noqa: E402
import state as state_mod        # noqa: E402

CYAN, GREEN, RED, YELLOW, DIM, NC = (
    "\033[0;36m", "\033[0;32m", "\033[0;31m", "\033[0;33m", "\033[2m", "\033[0m")


def log(msg):
    print(f"{CYAN}[e2e]{NC} {msg}", flush=True)


def warn(msg):
    print(f"{YELLOW}[e2e]{NC} {msg}", flush=True)


def err(msg):
    print(f"{RED}[e2e]{NC} {msg}", file=sys.stderr, flush=True)


# ── games.d ───────────────────────────────────────────────────────────────────

CONF_DIRS = [
    os.environ.get("MODS_GAMES_CONF_DIR", ""),
    "/usr/lib/powos/mods/games.d",
    os.path.abspath(os.path.join(HERE, "..", "..", "..", "config", "mods", "games.d")),
    "/var/lib/powos/src/config/mods/games.d",
]


def find_conf(game):
    for d in CONF_DIRS:
        if not d:
            continue
        path = os.path.join(d, f"{game}.conf")
        if os.path.isfile(path):
            return path
    return None


def load_conf(path):
    """Source a games.d conf in bash and hand back its variables.

    The confs are bash by design (the rest of the mods subsystem sources them),
    so bash is what reads them. Arrays come back as lists; everything else as
    strings, with $HOME and friends already expanded by the shell.
    """
    script = r'''
set -u
source "$1"
emit() {
  local name="$1"
  if [[ "$(declare -p "$name" 2>/dev/null)" == "declare -a"* ]]; then
    local -n ref="$name"
    printf '%s\t@\t' "$name"
    printf '%s\x1f' "${ref[@]}"
    printf '\n'
  else
    printf '%s\t=\t%s\n' "$name" "${!name}"
  fi
}
for v in $(compgen -v | grep -E '^(GAME|E2E)_'); do emit "$v"; done
'''
    out = subprocess.run(["bash", "-c", script, "bash", path],
                         capture_output=True, text=True, timeout=30)
    if out.returncode != 0:
        raise RuntimeError(f"could not read {path}: {out.stderr.strip()}")
    conf = {}
    for line in out.stdout.splitlines():
        parts = line.split("\t", 2)
        if len(parts) != 3:
            continue
        name, kind, value = parts
        if kind == "@":
            conf[name] = [v for v in value.split("\x1f") if v != ""]
        else:
            conf[name] = value
    return conf


def expand(value, conf):
    """Expand ${GAME_DIR} style placeholders in a conf string."""
    if not isinstance(value, str):
        return value
    for key, val in conf.items():
        if isinstance(val, str):
            value = value.replace("${%s}" % key, val).replace("$%s" % key, val)
    return os.path.expanduser(os.path.expandvars(value))


# ── Steam paths ───────────────────────────────────────────────────────────────

def steam_root():
    for d in ("~/.local/share/Steam", "~/.steam/steam", "~/.steam/root"):
        p = os.path.expanduser(d)
        if os.path.isdir(os.path.join(p, "steamapps")):
            return p
    return os.path.expanduser("~/.local/share/Steam")


def game_dir(appid, installdir=None):
    root = steam_root()
    acf = os.path.join(root, "steamapps", f"appmanifest_{appid}.acf")
    name = installdir
    if not name and os.path.isfile(acf):
        with open(acf, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                if '"installdir"' in line:
                    name = line.split('"')[3]
                    break
    if not name:
        return None
    path = os.path.join(root, "steamapps", "common", name)
    return path if os.path.isdir(path) else None


def prefix_dir(appid):
    return os.path.join(steam_root(), "steamapps", "compatdata", str(appid), "pfx")


# ── reversible environment changes ────────────────────────────────────────────

class Reversible:
    """Changes the harness makes to the machine, and undoes afterwards.

    Two kinds, both mandatory for a rig you can leave running unattended:

    * config edits — a debug channel that must be off in normal play has to be
      switched on for the run and switched back off after, including when the
      run crashes. Anything else eventually ships a listening socket to a
      player.
    * save backups — a test that loads a save and walks the character around
      writes to that save. Restoring it is not politeness, it is the
      difference between a rig you can run and one you run once.
    """

    def __init__(self, workdir):
        self.workdir = workdir
        os.makedirs(workdir, exist_ok=True)
        self._files = []          # (path, backup_path_or_None)
        self._trees = []          # (path, backup_path)

    def set_ini(self, path, key, value, section=None):
        """Set `key = value` in an INI config, remembering the original.

        Section-aware on purpose. INI keys are scoped to the section they sit
        under, so appending `DebugServer = true` to the end of a file puts it in
        whatever section happens to be last — where the code looking for it in
        `[Debug]` will never find it, the setting silently keeps its default,
        and the failure surfaces a hundred lines later as "the feature did not
        turn on". Name the section and the key lands where it is read.
        """
        path = os.path.abspath(path)
        if not os.path.isfile(path):
            warn(f"config {path} does not exist yet — cannot set {key}")
            return False
        self._backup_file(path)
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()

        current = None
        target_end = None          # last line index belonging to `section`
        for i, line in enumerate(lines):
            stripped = line.strip()
            if stripped.startswith("[") and stripped.endswith("]"):
                current = stripped[1:-1]
                continue
            if section is None or current == section:
                if stripped and not stripped.startswith("#") and "=" in stripped:
                    if stripped.split("=", 1)[0].strip() == key:
                        lines[i] = f"{key} = {value}"
                        with open(path, "w", encoding="utf-8") as f:
                            f.write("\n".join(lines) + "\n")
                        return True
            if section is not None and current == section:
                target_end = i

        if section is None:
            lines.append(f"{key} = {value}")
        elif target_end is not None:
            lines.insert(target_end + 1, f"{key} = {value}")
        else:
            lines += ["", f"[{section}]", f"{key} = {value}"]
        with open(path, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
        return True

    def backup(self, pattern):
        """Back up every file or directory matching a glob.

        Globs rather than directories on purpose. Backing up a whole save
        folder and restoring it afterwards also restores everything else that
        lives there — for Hollow Knight that is Player.log, so the run's own
        game log was being reverted to the previous run's copy the moment the
        run finished, and every log-based diagnosis read stale lines.
        """
        import glob as globmod
        import shutil
        hits = globmod.glob(os.path.expanduser(pattern))
        if not hits:
            warn(f"nothing matched backup pattern {pattern}")
            return False
        for path in hits:
            path = os.path.abspath(path)
            if os.path.isdir(path):
                dest = os.path.join(self.workdir, "tree_%d" % len(self._trees))
                shutil.copytree(path, dest)
                self._trees.append((path, dest))
            else:
                self._backup_file(path)
        log(f"backed up {len(hits)} path(s) matching {pattern}")
        return True

    def _backup_file(self, path):
        import shutil
        if any(p == path for p, _ in self._files):
            return
        dest = os.path.join(self.workdir, "file_%d_%s" % (len(self._files),
                                                          os.path.basename(path)))
        shutil.copy2(path, dest)
        self._files.append((path, dest))

    def restore(self):
        import shutil
        for path, backup in self._files:
            try:
                shutil.copy2(backup, path)
                log(f"restored {path}")
            except Exception as ex:
                err(f"COULD NOT RESTORE {path}: {ex} (backup kept at {backup})")
        for path, backup in self._trees:
            try:
                shutil.rmtree(path)
                shutil.copytree(backup, path)
                log(f"restored {path}")
            except Exception as ex:
                err(f"COULD NOT RESTORE {path}: {ex} (backup kept at {backup})")
        self._files, self._trees = [], []


# ── Session ───────────────────────────────────────────────────────────────────

class Session:
    """Everything a scenario is handed: state, input, logs, evidence."""

    def __init__(self, game, conf, evidence_dir, pad_count=0, dry_run=False):
        self.game = game
        self.conf = conf
        self.appid = conf.get("GAME_APPID")
        self.dry_run = dry_run
        self.evidence_dir = evidence_dir
        os.makedirs(evidence_dir, exist_ok=True)

        self.game_dir = conf.get("GAME_DIR") or game_dir(self.appid) or ""
        self.prefix = prefix_dir(self.appid) if self.appid else ""
        conf["GAME_DIR"] = self.game_dir
        conf["GAME_PREFIX"] = self.prefix

        self.logs = logs_mod.LogSet(
            [expand(p, conf) for p in conf.get("E2E_LOG_FILES", [])])
        self.channel = state_mod.build(self._channel_spec())
        self.pads = pads_mod.PadFarm() if not dry_run else None
        self.pad_count = pad_count
        self._evidence = []
        # False once we discover the game was already up: teardown must then
        # leave it alone.
        self.launched = True
        self.reversible = Reversible(os.path.join(evidence_dir, '_backup'))
        raw_slot = (conf.get('E2E_SAVE_SLOT') or '').strip()
        # None means 'the scenario works it out', which beats a number in a
        # conf file that silently points at a slot with no save in it.
        self.save_slot = int(raw_slot) if raw_slot else None
        self.log = log
        self.warn = warn

    def _channel_spec(self):
        c = self.conf
        return {
            "kind": c.get("E2E_STATE_KIND", "none"),
            "url": expand(c.get("E2E_STATE_URL", ""), c) or None,
            "state_path": c.get("E2E_STATE_PATH", "/state"),
            "command_path": c.get("E2E_COMMAND_PATH", "/cmd"),
            "path": expand(c.get("E2E_STATE_FILE", ""), c) or None,
            "addr": c.get("E2E_CDP_ADDR", "localhost:8884"),
            "target": c.get("E2E_CDP_TARGET") or None,
            "state_js": c.get("E2E_CDP_STATE_JS") or None,
        }

    # ── input ────────────────────────────────────────────────────────────
    def add_pads(self, n):
        for _ in range(n):
            self.pads.add()
        log(f"created {len(self.pads)} virtual pad(s): "
            + ", ".join(f"{p.name}->{p.devnode}" for p in self.pads))
        return self.pads

    def pad(self, index):
        return self.pads[index]

    def focus(self):
        """Raise and focus the game window.

        Whether this matters is per-engine and worth knowing for each game.
        evdev gamepads reach a process regardless of focus, but the layers
        between — Steam Input, Wine's XInput backend, and a Unity build with
        `Run In Background` off — may each stop feeding input to an unfocused
        window. When they do, the symptom is indistinguishable from a broken
        mod: devices enumerate, no button ever registers.
        """
        return shot_mod.focus(self.conf.get("E2E_WINDOW_MATCH", ""), log)

    # ── evidence ─────────────────────────────────────────────────────────
    def shot(self, name):
        path = os.path.join(self.evidence_dir, f"{name}.png")
        got = shot_mod.capture(path, self.conf.get("E2E_WINDOW_MATCH"), log)
        if got:
            self._evidence.append(got)
        return got

    def attach(self, path):
        self._evidence.append(path)

    def take_evidence(self):
        out, self._evidence = self._evidence, []
        return out

    def dump_state(self, name):
        """Persist the current state snapshot next to the screenshots."""
        try:
            data = self.channel.state()
        except Exception as ex:
            data = {"__error": str(ex)}
        path = os.path.join(self.evidence_dir, f"{name}.json")
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
        self._evidence.append(path)
        return data

    def close(self):
        if self.pads:
            self.pads.close()


# ── scenario loading ──────────────────────────────────────────────────────────

def load_scenario(name):
    path = os.path.join(HERE, "scenarios", f"{name}.py")
    if not os.path.isfile(path):
        raise FileNotFoundError(
            f"no scenario '{name}' (expected {path}). A game needs a scenario "
            f"module to have anything to assert.")
    spec = importlib.util.spec_from_file_location(f"e2e_scenario_{name}", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


# ── main ──────────────────────────────────────────────────────────────────────

def main(argv=None):
    ap = argparse.ArgumentParser(prog="powos mods e2e",
                                 description="End-to-end test a modded game")
    ap.add_argument("game", help="games.d id, e.g. hollowknight")
    ap.add_argument("--scenario", help="override the scenario module")
    ap.add_argument("--timeout", type=int, default=0,
                    help="seconds to wait for the game to become testable")
    ap.add_argument("--no-launch", action="store_true",
                    help="assume the game is already running")
    ap.add_argument("--keep-running", action="store_true",
                    help="leave the game up afterwards (for iterating)")
    ap.add_argument("--probe", action="store_true",
                    help="report readiness of every prerequisite and exit")
    ap.add_argument("--out", help="verdict JSON path")
    a = ap.parse_args(argv)

    conf_path = find_conf(a.game)
    if not conf_path:
        err(f"no games.d entry for '{a.game}'. Looked in:")
        for d in CONF_DIRS:
            if d:
                err(f"  {d}")
        return 2
    conf = load_conf(conf_path)
    log(f"game: {conf.get('GAME_NAME', a.game)} (appid {conf.get('GAME_APPID')})")
    log(f"conf: {conf_path}")

    scenario_name = a.scenario or conf.get("E2E_SCENARIO") or a.game
    ts = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    state_home = os.environ.get("XDG_STATE_HOME",
                                os.path.expanduser("~/.local/state"))
    evidence_dir = os.path.join(state_home, "powos", "mods", "e2e",
                                f"{a.game}-{ts}")

    session = Session(a.game, conf, evidence_dir,
                      pad_count=int(conf.get("E2E_PADS", 0) or 0))

    if a.probe:
        return probe(session, scenario_name)

    timeout = a.timeout or int(conf.get("E2E_READY_TIMEOUT", 240) or 240)
    results = report_mod.Results(conf.get("GAME_NAME", a.game),
                                 conf.get("GAME_APPID"), evidence_dir)
    rc = 1
    try:
        scenario = load_scenario(scenario_name)
        log(f"scenario: {scenario.__file__}")

        apply_environment(session, conf)
        session.logs.mark()

        if not a.no_launch:
            if not launch(session, conf, timeout):
                results.record("launch", report_mod.ERROR,
                               "the game did not become testable in time")
                print(results.render())
                return 2
        else:
            log("--no-launch: using the running game")

        if hasattr(scenario, "setup"):
            log("running scenario setup…")
            scenario.setup(session)

        report_mod.run_all(session, results, log)
        rc = {"pass": 0, "not-run": 3, "fail": 1, "error": 2}[results.verdict]
    except KeyboardInterrupt:
        warn("interrupted")
        results.note("interrupted by the operator")
        rc = 130
    except Exception as ex:
        err(f"{type(ex).__name__}: {ex}")
        import traceback
        traceback.print_exc()
        results.record("harness", report_mod.ERROR, f"{type(ex).__name__}: {ex}")
        rc = 2
    finally:
        # Order matters: stop the game before restoring its save and
        # config, or a shutdown write puts the test's state back.
        session.close()
        if not a.keep_running and not a.no_launch:
            if getattr(session, "launched", True):
                teardown(conf)
            else:
                warn("leaving the game running — this run did not start it")
        session.reversible.restore()

    print()
    print(results.render())
    out = a.out or os.path.join(evidence_dir, "verdict.json")
    results.save(out)
    log(f"verdict: {out}")
    log(f"evidence: {evidence_dir}")
    return rc


def apply_environment(session, conf):
    """Back up what the run will disturb, then switch on what it needs."""
    for pattern in conf.get("E2E_BACKUP", []) or conf.get("E2E_SAVE_BACKUP", []):
        session.reversible.backup(expand(pattern, conf))
    for entry in conf.get("E2E_CONFIG_SET", []):
        entry = expand(entry, conf)
        # "<path>:<key>=<value>" — the path may contain ':' on no sane system,
        # but the key never does, so split on the last ':' before the '='.
        if ":" not in entry or "=" not in entry:
            warn(f"malformed E2E_CONFIG_SET entry: {entry}")
            continue
        path, kv = entry.rsplit(":", 1)
        section = None
        if kv.startswith("["):
            close = kv.index("]")
            section, kv = kv[1:close], kv[close + 1:]
        key, value = kv.split("=", 1)
        if session.reversible.set_ini(path, key.strip(), value.strip(), section):
            log(f"config: {os.path.basename(path)} "
                f"{'[' + section + '] ' if section else ''}"
                f"{key.strip()} = {value.strip()} (restored afterwards)")


def launch(session, conf, timeout):
    appid = conf.get("GAME_APPID")
    pattern = conf.get("E2E_PROCESS_MATCH") or ""

    running = proc_mod.find(pattern) if pattern else []
    if running:
        # Attaching to someone else's session silently is how a run ends up
        # asserting against a game it did not configure — in this case another
        # developer's, mid-play, with different settings and a different build.
        warn(f"a game matching '{pattern}' is ALREADY RUNNING (pids {running}).")
        warn("Reusing it: this run did NOT apply its own launch environment, "
             "and the settings it needs may not be active. Close the game and "
             "re-run for a clean result.")
        # Whoever started it owns it. Stopping a session this run did not start
        # kills somebody else's game — which this harness did once, to another
        # developer mid-play, and there is no undo for that.
        session.launched = False
    else:
        if not proc_mod.ensure_steam(log=log):
            err("Steam would not start; a Steam game cannot be launched without it")
            return False
        proc_mod.steam_launch(appid, log=log)
        if pattern:
            log(f"waiting for a process matching '{pattern}'…")
            pid = proc_mod.wait_for_process(pattern, timeout=min(timeout, 180))
            if not pid:
                err(f"no process matching '{pattern}' after "
                    f"{min(timeout, 180)}s — did the game start?")
                return False
            log(f"game pid {pid}")

    # Proof of life #1: the loader. Cheap, and it distinguishes "the game is
    # up but the mod did not load" from "nothing started at all".
    marker = conf.get("E2E_LOAD_MARKER")
    if marker:
        log(f"waiting for load marker: {marker!r}")
        hit = session.logs.wait_for(marker, timeout=timeout)
        if hit:
            log(f"load marker seen in {hit[0]}: {hit[1].strip()[:120]}")
        else:
            # Not fatal: block-buffered logs routinely withhold this line long
            # after the event. The state channel is the real gate.
            warn(f"load marker never appeared within {timeout}s — logs are "
                 f"block-buffered, so this may be buffering rather than failure")

    # Proof of life #2: the state channel. This is the real one.
    if session.channel.kind != "none":
        log(f"waiting for the state channel: {session.channel.describe()}")
        if not session.channel.wait_ready(
                timeout, on_wait=lambda left: None):
            err(f"state channel never answered within {timeout}s "
                f"({session.channel.describe()})")
            err("without it, no assertion in this scenario can observe anything")
            return False
        log("state channel is live")

    if (conf.get("E2E_FOCUS_WINDOW", "") or "").lower() in ("1", "true", "yes"):
        time.sleep(2)
        session.focus()
    return True


def teardown(conf):
    pattern = conf.get("E2E_PROCESS_MATCH")
    if not pattern:
        return
    # SIGTERM only. See proc.stop.
    proc_mod.stop(pattern, grace=int(conf.get("E2E_STOP_GRACE", 45) or 45),
                  log=log)


def probe(session, scenario_name):
    """Report every prerequisite, so a failure names itself."""
    ok = True
    print()
    print(f"  game           {session.conf.get('GAME_NAME')} "
          f"(appid {session.appid})")
    print(f"  install        {session.game_dir or RED + 'NOT FOUND' + NC}")
    ok &= bool(session.game_dir)
    print(f"  prefix         {session.prefix}")

    pads_ok, why = pads_mod.probe()
    print(f"  virtual pads   {GREEN + 'ok' + NC if pads_ok else RED + why + NC}")
    ok &= pads_ok

    print(f"  steam          {GREEN + 'running' + NC if proc_mod.steam_running() else YELLOW + 'not running (will be started)' + NC}")

    present = session.logs.present()
    print(f"  logs           {len(present)}/{len(session.logs.files)} present")
    for f in session.logs.files:
        mark = GREEN + "●" + NC if f.exists() else YELLOW + "○" + NC
        print(f"                 {mark} {f.path}")

    live = session.channel.ready()
    print(f"  state channel  {session.channel.describe()} — "
          + (GREEN + "answering" + NC if live
             else DIM + "not answering (expected while the game is closed)" + NC))

    try:
        load_scenario(scenario_name)
        print(f"  scenario       {GREEN}{scenario_name}{NC} "
              f"({len(report_mod.TESTS)} cases)")
    except Exception as ex:
        print(f"  scenario       {RED}{ex}{NC}")
        ok = False

    print(f"  session        {shot_mod.session_kind()}")
    print()
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
