#!/usr/bin/env python3
"""A fake game, so scenario assertions can be proved to fail.

An assertion that has only ever been seen to pass is not evidence of anything.
The cheapest way to know a check works is to break the thing it checks and
watch it go red — but doing that against a real game means shipping a
deliberately broken mod and waiting five minutes per launch, so in practice
nobody does it, and rigs quietly fill up with checks that cannot fail.

This is a state channel with no game behind it: it models just enough of a
co-op session (players, positions, controllers, join/leave) that the real
scenario cases run against it unchanged, plus switches for the specific ways
the feature is known to break.

    python3 mockgame.py            # run every scenario case against every fault

Each fault names the case it must turn red. If a case stays green with its
fault switched on, that case is decoration and the run says so.
"""
from __future__ import annotations

import copy
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import report        # noqa: E402
import state         # noqa: E402


class MockGame(state.Channel):
    """A scriptable co-op session behind the real Channel interface."""
    kind = "mock"

    def __init__(self, **faults):
        # Faults, each named for what it simulates.
        self.no_input = faults.get("no_input", False)
        self.shared_input = faults.get("shared_input", False)
        self.pad_never_joins = faults.get("pad_never_joins", False)
        self.same_device = faults.get("same_device", False)
        self.wrong_mod = faults.get("wrong_mod", False)
        self.no_save = faults.get("no_save", False)
        self.clone_has_no_transform = faults.get("clone_has_no_transform", False)
        self.leave_keeps_device = faults.get("leave_keeps_device", False)
        self.never_leaves = faults.get("never_leaves", False)
        self.moves_left = faults.get("moves_left", False)
        self.pads_share_device = faults.get("pads_share_device", False)
        self.pads_not_enumerated = faults.get("pads_not_enumerated", False)
        # The couch-visible one: player one's own pad works until a clone
        # exists, then stops.
        self.p1_dead_after_join = faults.get("p1_dead_after_join", False)
        self.p1_never_moves = faults.get("p1_never_moves", False)
        # The camera never widens however far the group spreads. This is what
        # HKCouchCoop actually did until v0.7.12: it wrote zoom into
        # cam.orthographicSize, which is inert on Hollow Knight's perspective
        # camera, so AutoZoom was silently a no-op in every released build.
        self.never_zooms = faults.get("never_zooms", False)
        self.never_splits = faults.get("never_splits", False)
        self.never_merges = faults.get("never_merges", False)
        self.max_zoom = 1.6
        self.leash = -1.0
        self._split = False

        self.pad_count = 3
        # Player one is on pad 0, bound from the start.
        self.players = [self._mk(1, 10.0, "guid-pad0")]
        self.commands = []
        self.paused = False
        # Device indices currently held by a player. Tracked by index, not by
        # guid: the game claims one specific device object, so only one of a
        # pad's duplicate entries is ever marked claimed.
        # Player one's pad is his, but it is not "claimed" in the mod's sense
        # (claimed means handed to an extra player).
        self.claimed = set()

    # ── model ─────────────────────────────────────────────────────────────
    def _mk(self, n, x, guid):
        return {"n": n, "isPlayerOne": n == 1,
                "pos": {"x": x, "y": 6.0, "z": 0.0},
                "alive": True, "downed": False,
                "health": 6, "healthBlue": 0, "maxHealth": 6, "soul": 0,
                "device": None if guid is None else "Xbox Controller",
                "deviceGuid": guid, "deviceIndex": -1 if guid is None else n}

    def _devices(self):
        out = []
        if self.pads_not_enumerated:
            return out
        for i in range(self.pad_count * 2):        # duplication, as observed
            pad = i // 2
            guid = f"guid-pad{pad}" if not self.pads_share_device else "guid-shared"
            out.append({"index": i, "name": "Xbox Controller", "guid": guid,
                        "meta": "XInput", "sortOrder": i,
                        "deviceClass": "Controller", "deviceStyle": "Xbox360",
                        "passive": False, "attached": True,
                        "anyButtonPressed": i in self._lit,
                        "claimed": i in self.claimed})
        return out

    _lit = set()

    def ready(self):
        return True

    def wait_for(self, predicate, timeout=30, interval=0.5):
        """Answer immediately.

        The real implementation sleeps between polls because a real game takes
        time to react. A model reacts on the same call that changed it, so
        honouring those timeouts would spend minutes waiting for state that is
        already final — and the whole point of this fixture is being fast
        enough that breaking things is cheap.
        """
        last = self.state()
        return (True, last) if predicate(last) else (False, last)

    def state(self):
        return {
            "ok": True,
            "mod": "NotTheMod" if self.wrong_mod else "HKCouchCoop",
            "version": "0.6.8", "gameVersion": "1.5.12620",
            "time": time.time() % 1000, "frame": 1,
            "scene": None if self.no_save else "Crossroads_47",
            "sceneWidth": 60.0, "sceneHeight": 20.0,
            "gameState": "MAIN_MENU" if self.no_save else "PLAYING",
            "paused": self.paused,
            "inGameplay": not self.no_save,
            "saveLoaded": not self.no_save,
            "playerCount": len(self.players),
            "extraCount": len(self.players) - 1,
            "lastJoinRejection": None,
            "players": copy.deepcopy(self.players),
            "camera": self._camera(),
            "split": self._split_layout(),
            "devices": self._devices(),
        }

    BASE_FOV = 25.431
    BASE_HALF = 12.0
    MARGIN = 0.5

    def _split_layout(self):
        """Two equal side-by-side panes once the group outgrows the view.

        Hysteresis on both edges, like the mod: a single threshold sits exactly
        where a marginal group would tear the screen apart and back together
        every few frames.
        """
        xs = [p["pos"]["x"] for p in self.players
              if p.get("pos") and p["pos"].get("x") is not None]
        spread = (max(xs) - min(xs)) if len(xs) >= 2 else 0.0
        needed = spread / 2.0 + self.MARGIN
        allowed = self.BASE_HALF * self.max_zoom
        m = 0.15
        if self._split:
            self._split = needed > allowed * (1 - m)
            if self.never_merges:
                self._split = True
        else:
            self._split = needed > allowed * (1 + m)
            if self.never_splits:
                self._split = False
        if not self._split or len(xs) < 2:
            return {"active": False, "paneCount": 0, "panes": []}
        return {"active": True, "paneCount": 2, "panes": [
            {"x": 0.0, "y": 0.0, "w": 0.5, "h": 1.0, "knights": []},
            {"x": 0.5, "y": 0.0, "w": 0.5, "h": 1.0, "knights": []},
        ]}

    def _camera(self):
        """A perspective camera that widens as the group spreads, like the
        real one: fieldOfView = settings fov / ZoomFactor, so widening means a
        ZoomFactor below one."""
        xs = [p["pos"]["x"] for p in self.players
              if p.get("pos") and p["pos"].get("x") is not None]
        spread = (max(xs) - min(xs)) if len(xs) >= 2 else 0.0
        # Modelled the way the real one works, at this fake world's scale (a
        # held stick moves a Knight 2 units): widen once the group needs more
        # than the un-zoomed view holds, capped at MaxZoomFactor.
        base_half, margin = self.BASE_HALF, self.MARGIN
        needed = spread / 2.0 + margin
        zoom = 1.0
        if not self.never_zooms and needed > base_half:
            zoom = max(1.0 / self.max_zoom, base_half / needed)
        base_h = base_half
        return {
            "present": True, "orthographic": False, "orthographicSize": 480,
            "neededHalfHeight": needed, "allowedHalfHeight": base_h * 1.6,
            "baseHalfHeight": base_h, "currentHalfHeight": base_h / zoom,
            "fieldOfView": self.BASE_FOV / zoom, "aspect": 1.678,
            "pixelWidth": 1515, "pixelHeight": 903,
            "rect": {"x": 0, "y": 0, "w": 1, "h": 1},
            "tk2dZoomFactor": zoom, "tk2dSettingsFov": self.BASE_FOV,
            "tk2dProjection": "Perspective",
        }

    def command(self, name, **args):
        self.commands.append((name, args))
        if name == "setcfg":
            key = args.get("key")
            if key == "MaxZoomFactor":
                was, self.max_zoom = self.max_zoom, float(args.get("value", 1.6))
                return {"ok": True, "did": "setcfg", "was": was, "now": self.max_zoom}
            if key == "LeashDistance":
                was, self.leash = self.leash, float(args.get("value", -1))
                # A positive leash pulls the extras to player one. Modelled as
                # the snap it is: the real one teleports them, it does not walk
                # them, which is exactly why a test uses it to regroup rather
                # than trying to walk a Knight down off a ledge.
                if self.leash > 0 and self.players and self.players[0].get("pos"):
                    anchor = self.players[0]["pos"]["x"]
                    for p in self.players[1:]:
                        if p.get("pos"):
                            p["pos"]["x"] = anchor + 1.0
                return {"ok": True, "did": "setcfg", "was": was, "now": self.leash}
            return {"ok": True, "did": "setcfg", "was": None}
        before = len(self.players)
        if name == "join":
            self._join(len(self.players) - 1)
        elif name == "leaveall":
            self.players = self.players[:1]
            self.claimed.clear()
        return {"ok": True, "did": name, "playerCountBefore": before,
                "playerCountAfter": len(self.players)}

    def _join(self, pad_index):
        n = len(self.players) + 1
        guid = ("guid-shared" if self.same_device or self.pads_share_device
                else f"guid-pad{pad_index}")
        p = self._mk(n, 12.0 + n, guid)
        p["deviceIndex"] = pad_index
        if self.clone_has_no_transform:
            p["pos"] = None
        self.players.append(p)
        self.claimed.add(pad_index)

    # ── what a pad does to the model ──────────────────────────────────────
    def pad_down(self, pad_index, control):
        if self.no_input:
            return
        # Normally each pad lights its own two duplicate device entries. When
        # the game cannot tell the pads apart, every pad lights the same ones.
        self._lit = {0 if self.pads_share_device else pad_index}

    def pad_up(self, pad_index, control):
        self._lit = set()

    def pad_press(self, pad_index, control):
        self.pad_down(pad_index, control)
        self.pad_up(pad_index, control)
        if control.upper() != "START" or self.no_input:
            return
        held = getattr(self, "_held", 0)
        if held >= 1.2 and len(self.players) > 1:
            if self.never_leaves:
                return
            gone = self.players.pop()
            if not self.leave_keeps_device:
                self.claimed.discard(gone.get("deviceIndex"))
            return
        if pad_index == 0:
            # Player one's reserved pad always pauses; it never joins.
            self.paused = not self.paused
            return
        if self.pad_never_joins:
            self.paused = True
            return
        self._join(pad_index)

    def pad_stick(self, pad_index, x):
        """Pad N drives whichever player is bound to device N."""
        if self.no_input:
            return
        step = -2.0 if self.moves_left else 2.0
        guid = f"guid-pad{pad_index}"
        for p in self.players:
            if p["pos"] is None:
                continue
            drives = p.get("deviceGuid") == guid
            # A clone reading player one's handler: pad 0 moves everyone.
            if self.shared_input and pad_index != 0 and p["n"] == 1:
                drives = True
            if p["n"] == 1:
                if self.p1_never_moves:
                    drives = False
                # Player one goes deaf to his own pad once a clone exists.
                if self.p1_dead_after_join and len(self.players) > 1:
                    drives = False
            if drives:
                p["pos"]["x"] += step * x


class FakePad:
    def __init__(self, game, index):
        self.game, self.index = game, index
        self.name = f"PowOS E2E Pad {index + 1}"
        self.devnode = f"/dev/input/fake{index}"

    def press(self, control, seconds=0.09):
        self.game._held = seconds
        self.game.pad_press(self.index, control)

    def down(self, control):
        self.game.pad_down(self.index, control)

    def up(self, control):
        self.game.pad_up(self.index, control)

    def stick(self, x, y=0, seconds=None):
        self.game.pad_stick(self.index, x)

    def neutral(self):
        self.game.pad_up(self.index, "ALL")


class FakeSession:
    def __init__(self, game, tmpdir):
        self.channel = game
        self.pads = [FakePad(game, i) for i in range(game.pad_count)]
        self.baseline_devices = []
        self.evidence_dir = tmpdir
        self.save_slot = None
        self.conf = {}
        self.messages = []

    def log(self, m):
        self.messages.append(m)

    warn = log

    def pad(self, i):
        return self.pads[i]

    def add_pads(self, n):
        return self.pads

    def shot(self, name):
        return None

    def dump_state(self, name):
        return self.channel.state()

    def take_evidence(self):
        return []

    def focus(self):
        return True


# ── the proof ─────────────────────────────────────────────────────────────────

# fault -> the case name it MUST turn red.
FAULTS = [
    ("wrong_mod", "mod is loaded and answering"),
    ("pads_not_enumerated", "the virtual controllers reached the game"),
    ("no_save", "a save is loaded and the game is in gameplay"),
    ("no_input", "each virtual pad is a distinct device inside the game"),
    ("pads_share_device", "each virtual pad is a distinct device inside the game"),
    ("p1_never_moves", "player one is driven by his own pad"),
    ("pad_never_joins", "pressing Start on pad 2 spawns player two"),
    ("clone_has_no_transform", "pressing Start on pad 2 spawns player two"),
    ("shared_input", "player two moves on pad 2, and player one does not"),
    ("moves_left", "player two moves on pad 2, and player one does not"),
    ("p1_dead_after_join",
     "player one STILL moves on his own pad after player two joined"),
    ("never_zooms", "the camera widens when the group spreads"),
    ("never_splits",
     "the screen splits when the Knights spread, and merges when they regroup"),
    ("never_merges",
     "the screen splits when the Knights spread, and merges when they regroup"),
    ("same_device", "a third pad joins as player three"),
    ("never_leaves", "holding Start removes a player"),
    ("leave_keeps_device", "holding Start removes a player"),
]


def run_sequence(game, cases):
    """Run every case in order against one session, as a real run does."""
    import tempfile
    sess = FakeSession(game, tempfile.mkdtemp())
    results = {}
    for case in cases:
        try:
            case["fn"](sess)
            results[case["name"]] = ("pass", "")
        except report.Skip as ex:
            results[case["name"]] = ("skip", str(ex))
        except AssertionError as ex:
            results[case["name"]] = ("fail", str(ex).splitlines()[0][:110])
        except Exception as ex:
            results[case["name"]] = ("error", f"{type(ex).__name__}: {ex}")
    return results


def main():
    import importlib.util
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "scenarios", "hollowknight.py")
    report.reset()
    spec = importlib.util.spec_from_file_location("mock_scenario", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    cases = list(report.TESTS)
    names = {c["name"] for c in cases}

    problems = []

    print("── healthy game: every case must pass ─────────────────────────")
    healthy = run_sequence(MockGame(), cases)
    for name, (status, detail) in healthy.items():
        print(f"  {status.upper():5} {name}" + (f"  {detail}" if status != "pass" else ""))
        if status != "pass":
            problems.append(f"{name} does not pass against a healthy game ({detail})")

    print()
    print("── each fault must turn its case red ──────────────────────────")
    for fault, target in FAULTS:
        if target not in names:
            problems.append(f"no case named {target!r} for fault {fault!r}")
            continue
        results = run_sequence(MockGame(**{fault: True}), cases)
        status, detail = results[target]
        ok = status == "fail"
        print(f"  {'OK  ' if ok else 'MISS'}  {fault:24} -> {target}")
        if detail:
            print(f"         {detail}")
        if not ok:
            problems.append(
                f"fault {fault!r} left {target!r} {status.upper()} — that check "
                f"cannot detect the thing it claims to")

    print()
    if problems:
        for p in problems:
            print("PROBLEM: " + p)
        print(f"{len(problems)} problem(s)")
        return 1
    print("every case passes when healthy and fails when broken")
    return 0


if __name__ == "__main__":
    sys.exit(main())
