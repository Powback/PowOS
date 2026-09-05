#!/usr/bin/env python3
"""Hollow Knight + HKCouchCoop — end-to-end scenario.

The claim under test is a couch: **two people, two controllers, one screen.**
So the rig sets up exactly that. Pad 1 *is* player one — the pad the game was
already using, which always pauses and never joins. Pad 2 joins as player two.
Pad 3 joins as player three.

That configuration matters more than it looks. Putting player one on the
keyboard instead is easier to arrange, because then every pad is a joiner and
the harness needs no reserved pad — but it never
checks the half that actually breaks: whether player one's own controller still
drives player one once a clone exists. Both directions are asserted here:

    holding right on pad 2 must move player two and NOT player one
    holding right on pad 1 must move player one and NOT player two

A mod that wires a clone to the wrong input handler passes one of those and
fails the other, so a test that only checks one direction is worth very little.

Everything is read from the mod's live state channel — positions, health, and
which controller each Knight is bound to. Nothing here infers behaviour from a
log line or a screenshot, because neither can tell "player two spawned and
moved" from "player two spawned and stood still while player one moved".

The scenario joins players by pressing Start on a pad, the way a person does.
The mod's own join command exists only to tell two different failures apart:
if `/cmd join` spawns a Knight and Start does not, spawning works and the input
path is broken.
"""
import glob
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from report import test, Skip          # noqa: E402

# Pad roles. Index into sess.pads.
P1_PAD = 0          # player one's own controller: always pauses, never joins
P2_PAD = 1          # joins as player two
P3_PAD = 2          # joins as player three

# How far a Knight must travel in a 1.5s hold to count as "moved", and how far
# another Knight may drift and still count as "stayed put". The gap between
# them is deliberate: a spawned clone settles under gravity for a moment, and
# the camera-follow leash nudges stragglers.
MOVED = 1.0
STILL = 0.5

SAVE_DIR = os.path.expanduser(
    "~/.local/share/Steam/steamapps/compatdata/367520/pfx/drive_c/users/"
    "steamuser/AppData/LocalLow/Team Cherry/Hollow Knight")


# ── helpers ───────────────────────────────────────────────────────────────────

def _save_slots():
    """Slots that actually have a save file, lowest first.

    Hollow Knight names slot 0 `user.dat` and slot N `userN.dat`, so the first
    save a player creates is slot 1. Loading slot 0 on a machine whose only
    save is `user1.dat` is accepted by the game, finds no file, and quietly
    returns to the main menu — indistinguishable from the load hanging.
    """
    found = []
    for path in glob.glob(os.path.join(SAVE_DIR, "user*.dat")):
        stem = os.path.basename(path)[len("user"):-len(".dat")]
        if stem == "":
            found.append(0)
        elif stem.isdigit():
            found.append(int(stem))
    return sorted(set(found))


def _player(state, n):
    for p in state.get("players", []):
        if p.get("n") == n:
            return p
    return None


def _x(player):
    pos = (player or {}).get("pos")
    return pos["x"] if pos else None


def _new_devices(sess, state):
    """Devices that appeared after the harness created its pads."""
    baseline = len(getattr(sess, "baseline_devices", []))
    return state.get("devices", [])[baseline:]


def _ensure_unpaused(sess):
    """Leave the pause menu if an earlier case left us in it.

    Start is both the join button and the pause button. A press the mod does
    not turn into a join pauses the game instead, and then every later case
    fails because the game is in a menu — one real defect reported as several.
    """
    st = sess.channel.state()
    if not st.get("paused"):
        return True
    sess.warn("the game is PAUSED (an earlier Start press was not turned into "
              "a join) — un-pausing so this case tests its own subject")
    for _ in range(3):
        sess.pad(P1_PAD).press("START", 0.12)
        ok, _ = sess.channel.wait_for(lambda s: not s.get("paused"), timeout=6)
        if ok:
            _nap(sess, 0.5)
            return True
    return False


def _walk_to_room_middle(sess, pad_index, player_n, timeout=14.0, band=None):
    """Put a Knight in the middle third of the room before measuring it.

    Blind repositioning does not work here. Walking a fixed time away from the
    edge you just crossed can walk you straight over the OPPOSITE edge, and
    then the measuring hold crosses back — which is exactly how this case
    burned all four attempts. Rooms are authored from the world origin, so the
    channel's sceneWidth makes the middle a known destination rather than a
    guess. Aborts the moment the room changes; nothing here is asserted on.
    """
    t0, budget = time.time(), timeout * _pace(sess)
    while time.time() - t0 < budget:
        st = sess.channel.state()
        width = st.get("sceneWidth") or 0
        x = _x(_player(st, player_n))
        if not width or width <= 0 or x is None:
            return False
        scene0 = st.get("scene")
        b = band if band is not None else max(width * 0.1, 2.0)
        lo, hi = width / 2.0 - b, width / 2.0 + b
        if lo <= x <= hi:
            sess.pad(pad_index).neutral()
            return True
        sess.pad(pad_index).stick(1.0 if x < lo else -1.0, 0.0)
        _nap(sess, 0.2)
        if sess.channel.state().get("scene") != scene0:
            sess.pad(pad_index).neutral()
            return False
    sess.pad(pad_index).neutral()
    sess.warn(f"player {player_n} did not reach the middle of the room within "
              f"{timeout}s — it may be walled in or the room may be very wide")
    return False


def _wait_still(sess, timeout=4.0, tol=0.15):
    """Wait until every Knight has stopped moving on its own.

    A measurement is only meaningful from rest. A room transition walks the
    hero into the new room under the game's control, a fresh clone settles
    under gravity, and the leash can snap someone across the screen — all of
    which look exactly like "that Knight is reading someone else's input" if
    the hold starts while they are still in motion. Costs a fraction of a
    second and removes a whole class of false accusation.
    """
    prev, t0 = None, time.time()
    budget = timeout * _pace(sess)
    while time.time() - t0 < budget:
        st = sess.channel.state()
        xs = {p["n"]: _x(_player(st, p["n"])) for p in st.get("players", [])}
        if prev is not None and all(
                a is not None and (b := prev.get(n)) is not None
                and abs(a - b) < tol for n, a in xs.items()):
            return True
        prev = xs
        _nap(sess, 0.25)
    sess.warn(f"the Knights were still drifting after {timeout}s; measuring anyway")
    return False


def _hold_right(sess, pad_index, seconds=1.5, sign=1.0):
    """Hold right on one pad; return {player number: (start_x, end_x, peak_x)}.

    Samples throughout rather than just the endpoints: two samples cannot tell
    "walked right, then was yanked back by the leash" from "never moved", and
    both of those happen in this game.
    """
    st = sess.channel.state()
    numbers = [p["n"] for p in st.get("players", [])]
    tracks = {n: [_x(_player(st, n))] for n in numbers}
    scenes = {st.get("scene")}

    pad = sess.pad(pad_index)
    pad.stick(sign, 0.0)
    t0, budget = time.time(), seconds * _pace(sess)
    while time.time() - t0 < budget:
        _nap(sess, 0.25)
        now = sess.channel.state()
        scenes.add(now.get("scene"))
        for n in numbers:
            tracks[n].append(_x(_player(now, n)))
    pad.neutral()
    _nap(sess, 0.6)

    final = sess.channel.state()
    scenes.add(final.get("scene"))
    out = {}
    for n in numbers:
        tracks[n].append(_x(_player(final, n)))
        xs = [v for v in tracks[n] if v is not None]
        if not xs:
            out[n] = None
            continue
        out[n] = (xs[0], xs[-1], max(xs))
    sess.log(f"pad {pad_index + 1} held right; x tracks: "
             + "; ".join(f"P{n}: " + (", ".join(f"{v:.1f}" for v in tracks[n]
                                                if v is not None))
                         for n in numbers))
    out["_scenes"] = scenes
    return out


def _hold_right_same_room(sess, pad_index, driven_n, seconds=1.5, attempts=4,
                          sign=1.0):
    """Hold right, and insist the whole hold happened in ONE room.

    Rooms are authored at the world origin, so an x in Crossroads_47 and an x
    in Crossroads_19 are not in the same coordinate space. A hold that walks
    into a transition therefore produces a delta that measures nothing — and
    it reads as the most alarming failure this rig has, "the Knight moved and
    was then yanked backwards", which is what a broken leash looks like. One
    run was spent on that.

    Retrying is safe rather than lucky: a transition drops you just inside the
    next room, so the retry starts far from the edge it just crossed. If the
    room still changes every time, the run cannot measure this and says so
    instead of guessing.
    """
    for attempt in range(attempts):
        _wait_playing(sess)
        if attempt:
            # A transition drops you just inside the next room, so walking the
            # SAME way again heads for its far side. Walk to the middle of
            # whichever room we are in now instead, which is a known place
            # rather than a guessed distance.
            _walk_to_room_middle(sess, pad_index, driven_n)
            _nap(sess, 0.4)
        _wait_still(sess)
        tracks = _hold_right(sess, pad_index, seconds, sign=sign)
        scenes = tracks.pop("_scenes", set())
        if len(scenes) <= 1:
            return tracks
        sess.warn(f"the room changed during the hold ({' -> '.join(sorted(s or '?' for s in scenes))}); "
                  f"x is per-room so that measurement is meaningless — backing "
                  f"off the edge and retaking (attempt {min(attempt + 2, attempts)}/{attempts})")
    raise AssertionError(
        "every attempt to measure this walked through a room transition, so "
        "the Knight's movement could not be measured in one coordinate space. "
        "This is the harness failing to find still ground, not the mod.")


def _hold_left_same_room(sess, pad_index, driven_n, seconds=1.5, attempts=4):
    """The same measurement, walking the other way.

    Used only as a second opinion when holding right produced nothing: a
    Knight standing against scenery is indistinguishable from a pad that
    drives nothing if you only ever push one direction.
    """
    return _hold_right_same_room(sess, pad_index, driven_n, seconds, attempts,
                                 sign=-1.0)


def _wait_playing(sess, timeout=20):
    """Block until the game is actually in gameplay.

    Inputs do nothing during a level transition: the mod's join gate wants
    GameState.PLAYING, and vanilla's own pause path wants PLAYING or PAUSED.
    So a Start press sent during EXITING_LEVEL is swallowed by the engine and
    the case that sent it reports the mod ignoring a controller. Nothing is
    weakened by waiting — a press that lands mid-transition tests nothing.
    """
    ok, last = sess.channel.wait_for(
        lambda s: s.get("gameState") == "PLAYING", timeout=timeout)
    if not ok:
        sess.warn(f"still not in gameplay after {timeout}s "
                  f"(gameState {(last or {}).get('gameState')})")
    return ok


def _assert_drives_only(sess, pad_index, driven, others, tracks,
                        direction="RIGHT"):
    """`driven` moved the way it was pushed; every player in `others` stayed put."""
    want = 1 if direction == "RIGHT" else -1
    d = tracks.get(driven)
    assert d is not None, f"player {driven} has no position — it is not on the field"
    start, end, peak = d
    delta = end - start

    assert abs(delta) > MOVED, (
        f"player {driven} moved {delta:+.2f} world units while pad "
        f"{pad_index + 1} held {direction} — that pad is enumerated and bound, "
        f"but its stick is not driving that Knight")
    assert delta * want > 0, (
        f"player {driven} ended {delta:+.2f} from where it started while its "
        f"pad held {direction} (furthest reached x={peak:.1f} from {start:.1f}), so "
        + ("it moved and was then pulled back — leash or a scripted reposition"
           if abs(peak - start) > STILL else "it moved in the wrong direction"))

    for n in others:
        o = tracks.get(n)
        if o is None:
            continue
        drift = abs(o[1] - o[0])
        assert drift < STILL, (
            f"player {n} ALSO moved {drift:.2f} units while only pad "
            f"{pad_index + 1} was held — that Knight is reading an input "
            f"handler that is not its own, which is the exact bug this "
            f"architecture exists to avoid")
    return delta


def _pace(sess):
    """How long a second is worth against whatever is on the other end.

    The waits here are sized for a real game: physics settles, animations play,
    a held stick moves a Knight over time. The fake game prove-mode runs
    against has none of that — it steps when a pad is pushed and answers
    instantly — so every one of those seconds is spent asleep for nothing, once
    per injected fault. That turned a check whose whole value is being cheap
    enough to run before every real launch into a twelve-minute wait, and a
    guard people skip is not a guard.
    """
    return getattr(sess, "time_scale", 1.0)


def _nap(sess, seconds):
    time.sleep(seconds * _pace(sess))


def _cam(state):
    return (state or {}).get("camera") or {}


def _cam_split(state):
    return (state or {}).get("split") or {}


def _pane_brightness(path, panes):
    """Mean brightness inside each pane's own rect.

    The whole-screen average hides the failure that matters: one Knight's pane
    drawing nothing averages out against another's that draws fine, and lands
    near half — right on the whole-screen threshold. Reported rather than
    asserted, because a Knight genuinely standing in an unlit spot is not a
    bug and must not fail a run.
    """
    try:
        from PIL import Image
        import numpy as np
    except Exception:
        return None
    try:
        im = np.asarray(Image.open(path).convert("RGB")).astype(float)
    except Exception:
        return None
    h, w = im.shape[0], im.shape[1]
    out = []
    for p in panes:
        # Viewport y is bottom-up; image rows are top-down.
        x0 = int(round(p["x"] * w)); x1 = int(round((p["x"] + p["w"]) * w))
        y0 = int(round((1.0 - p["y"] - p["h"]) * h)); y1 = int(round((1.0 - p["y"]) * h))
        cell = im[max(y0, 0):min(y1, h), max(x0, 0):min(x1, w)]
        out.append(float(cell.mean()) if cell.size else None)
    return out


def _mean_brightness(path):
    """Average luminance of a screenshot, or None if it cannot be read.

    Exists because every other assertion in this case reads the layout the mod
    decided, and none of them can see a pixel. A run once reported 13/13 with
    the panes drawing nothing at all: the geometry was right, the driver threw
    nothing, and the world was black behind an intact HUD.
    """
    if not path:
        return None
    try:
        from PIL import Image
        import numpy as np
        with Image.open(path) as im:
            return float(np.asarray(im.convert("L"), dtype="float32").mean())
    except Exception:
        return None


def _asked_for_zoom(cam):
    """Did the group need more view than the game's own un-zoomed one?"""
    need, base = cam.get("neededHalfHeight"), cam.get("baseHalfHeight")
    return bool(need and base and need > base * 1.05)


def _got_zoom(cam):
    """Did the camera actually give it?"""
    cur, base = cam.get("currentHalfHeight"), cam.get("baseHalfHeight")
    return bool(cur and base and cur > base * 1.02)


def _spread_apart(sess, seconds=6.0, attempts=3):
    """Drive player one left and player two right at once, in ONE room.

    Returns (widest_fov_seen, starting_fov). Retries on a room change for the
    same reason the movement holds do: a transition repositions everyone, so
    the spread it produced is not the spread the camera was asked to frame.
    """
    for attempt in range(attempts):
        _wait_playing(sess)
        # Start from the middle of the room. Spreading needs runway on BOTH
        # sides, and by this point in a run the Knights have usually been left
        # wherever the previous case stopped them — often against an edge,
        # where walking apart just crosses a transition and measures nothing.
        _walk_to_room_middle(sess, P1_PAD, 1)
        _walk_to_room_middle(sess, P2_PAD, 2)
        _wait_still(sess)
        # Let the post-transition straggler net expire before spreading.
        # For 120 frames after the party is gathered through a door, the mod
        # snaps any Knight more than TEN units from player one back to him —
        # it exists to rescue someone left behind at a doorway. Walking apart
        # inside that window is a tug of war the test cannot win, and it caps
        # the separation at about ten units: exactly the 9.5 that kept landing
        # just under the split threshold and skipping this case.
        _nap(sess, 2.5)
        st = sess.channel.state()
        scene0 = st.get("scene")
        started = _cam(st).get("fieldOfView")
        widest = started or 0.0
        asked = got = False
        peak = {}

        p1, p2 = sess.pad(P1_PAD), sess.pad(P2_PAD)
        p1.stick(-1.0, 0.0)
        p2.stick(1.0, 0.0)
        t0, budget = time.time(), seconds * _pace(sess)
        changed = False
        while time.time() - t0 < budget:
            _nap(sess, 0.2)
            p1.stick(-1.0, 0.0)
            p2.stick(1.0, 0.0)
            now = sess.channel.state()
            if now.get("scene") != scene0:
                changed = True
                break
            cam = _cam(now)
            fov = cam.get("fieldOfView")
            if fov is not None:
                widest = max(widest, fov)
            if _asked_for_zoom(cam):
                asked = True
                if _got_zoom(cam):
                    got = True
                    peak = cam           # the sample the pass actually rests on

            # Stop as soon as they are far enough apart to split, rather than
            # walking for a fixed time. A duration cannot be right for every
            # room: two seconds left them a hair under the threshold and the
            # case skipped, five walked them into a door and it failed for
            # crossing a transition. The condition itself is the thing to wait
            # for, and stopping at it keeps them clear of the edges.
            needed = cam.get("neededHalfHeight") or 0
            allowed = cam.get("allowedHalfHeight") or 0
            if allowed and needed > allowed * 1.2:
                break
        p1.neutral()
        p2.neutral()
        _nap(sess, 0.4)

        if not changed:
            return widest, started, asked, got, peak
        sess.warn(f"the room changed while spreading the group; retaking "
                  f"(attempt {min(attempt + 2, attempts)}/{attempts})")
    raise AssertionError(
        "could not spread the group without crossing a room transition")


def _join_with_start(sess, pad_index, expect_count, timeout=25):
    """Press Start on a pad and wait for the roster to grow."""
    _wait_playing(sess)
    before = sess.channel.state().get("playerCount")
    sess.log(f"pad {pad_index + 1}: pressing START (players now {before})")
    sess.pad(pad_index).press("START", 0.12)
    ok, last = sess.channel.wait_for(
        lambda s: s.get("playerCount") == expect_count, timeout=timeout)
    if not ok and (last or {}).get("paused"):
        _ensure_unpaused(sess)
    return ok, last, before


# ── getting to a testable state ───────────────────────────────────────────────

def setup(sess):
    """Load a save and reach gameplay, with no human touching anything.

    The mod refuses to spawn anyone outside gameplay ("Load a save first" /
    "Can only join during gameplay"). Driving the title menus with a virtual
    pad would work until someone reorders a menu row; asking the mod to call
    the game's own save-slot load does not.
    """
    st = sess.channel.state()
    sess.log(f"mod {st.get('mod')} {st.get('version')} on game {st.get('gameVersion')}")
    sess.log(f"scene={st.get('scene')} gameState={st.get('gameState')}")

    # What was plugged in before we added anything. The device-count delta is
    # how our pads are identified once InControl has renamed them all to
    # "Xbox Controller".
    sess.baseline_devices = list(st.get("devices", []))
    sess.log(f"controllers already attached: "
             f"{[d.get('name') for d in sess.baseline_devices] or 'none'}")

    # Pads before the save loads. The mod has no pad-index setting: it treats
    # whichever device has actually been driving player one as player one's,
    # observed from their own action set. So pad 1 has to exist before there is
    # a player one, and case 5 (player one moves on pad 1, before any join) is
    # what makes the observation happen rather than merely asserting on it.
    sess.add_pads(sess.pad_count or 3)
    sess.log(f"pad roles — 1: player one (reserved), 2: joins as player two, "
             f"3: joins as player three")
    time.sleep(1.5)

    if not st.get("saveLoaded"):
        # The channel is served by the plugin, which exists before GameManager
        # does: it answers during the splash screen, when there is nothing to
        # drive yet.
        sess.log("waiting for the title screen (GameManager to exist)…")
        ok, last = sess.channel.wait_for(
            lambda s: s.get("gameState") not in (None, "None"),
            timeout=120, interval=2.0)
        if not ok:
            raise RuntimeError(f"game never reached a menu; last state: {last}")
        sess.log(f"gameState={last.get('gameState')} scene={last.get('scene')}")

        slots = _save_slots()
        slot = sess.save_slot if sess.save_slot is not None else (
            slots[0] if slots else None)
        if slot is None:
            raise RuntimeError(
                f"no save files in {SAVE_DIR}. This scenario tests co-op inside "
                f"a running game, which needs a save to load. Create one in the "
                f"game once, or point E2E_SAVE_SLOT at an existing slot.")
        sess.log(f"save slots on disk: {slots}; loading slot {slot}…")

        r = sess.channel.command("loadsave", slot=slot)
        sess.log(f"loadsave -> {r}")
        ok, last = sess.channel.wait_for(
            lambda s: s.get("inGameplay") and s.get("saveLoaded"),
            timeout=180, interval=2.0)
        if not ok:
            raise RuntimeError(
                f"never reached gameplay after loading slot {slot} "
                f"(slots with files: {slots}); gameState is "
                f"{(last or {}).get('gameState')}, scene "
                f"{(last or {}).get('scene')}")
    time.sleep(3)
    sess.log(f"in gameplay, scene={sess.channel.state().get('scene')}")
    sess.dump_state("00-setup")


# ── cases ─────────────────────────────────────────────────────────────────────

@test("mod is loaded and answering")
def t_loaded(sess):
    st = sess.channel.state()
    assert st.get("ok") is True, f"state channel did not report ok: {st}"
    assert st.get("mod") == "HKCouchCoop", f"unexpected mod identity: {st.get('mod')}"
    assert st.get("version"), "mod reported no version"
    assert st.get("gameVersion"), "no game version in state"
    return (f"HKCouchCoop {st['version']} live inside Hollow Knight "
            f"{st['gameVersion']}, scene {st.get('scene')}")


@test("a save is loaded and the game is in gameplay")
def t_in_game(sess):
    st = sess.channel.state()
    assert st.get("saveLoaded"), "no HeroController — no save is loaded"
    assert st.get("inGameplay"), f"gameState is {st.get('gameState')}, not PLAYING"
    assert st.get("scene"), "no active scene name"
    p1 = _player(st, 1)
    assert p1 and p1.get("pos"), f"player one has no position: {p1}"
    return (f"scene {st['scene']}, player one at "
            f"x={p1['pos']['x']:.1f} y={p1['pos']['y']:.1f}, "
            f"{p1['health']}/{p1['maxHealth']} masks")


@test("the virtual controllers reached the game")
def t_devices(sess):
    """The most common silent failure: pads the game never enumerated.

    A pad InControl does not list cannot join, cannot move anyone, and produces
    no error anywhere. A uinput device has to survive three hops to get here:
    the kernel, SDL's hotplug scan inside Steam's pressure-vessel container,
    and Wine's XInput layer. Any of them dropping it looks identical from
    outside, so this is checked before anything is blamed on the mod.
    """
    st = sess.channel.state()
    new = _new_devices(sess, st)
    names = [d.get("name") for d in st.get("devices", [])]
    expected = len(sess.pads)
    assert len(new) >= expected, (
        f"created {expected} virtual pads but the game gained {len(new)} "
        f"device(s). InControl sees: {names or '(nothing)'}. The pads exist on "
        f"the host ({[p.devnode for p in sess.pads]}) but did not reach the "
        f"game — look at SDL hotplug inside the Steam runtime container.")
    attached = [d for d in new if d.get("attached")]
    assert len(attached) >= expected, f"pads present but not attached: {new}"
    return (f"{len(new)} pad(s) crossed uinput -> SDL -> Wine into InControl, "
            f"seen as {[d.get('name') for d in new]}")


@test("each virtual pad is a distinct device inside the game")
def t_pad_identity(sess):
    """Map host pad -> in-game device by pressing a button and watching.

    Names cannot do this: InControl renames every pad after the profile it
    matched, so they are all "Xbox Controller". Behaviour can. This also
    exposes duplicate devices — Steam Input publishes a twin of each pad, and
    a mod that excludes one twin from player one leaves the other driving him.
    """
    def probe():
        out = {}
        for i, pad in enumerate(sess.pads):
            pad.down("A")
            time.sleep(0.45)
            st = sess.channel.state()
            pad.up("A")
            time.sleep(0.35)
            out[i] = {d["index"] for d in st.get("devices", [])
                      if d.get("anyButtonPressed")}
        return out

    seen = probe()
    for i, pressed in seen.items():
        sess.log(f"pad {i + 1} lights up in-game device index(es) {sorted(pressed)}")

    if not any(seen.values()):
        # Rule out the thing that produces exactly this symptom before blaming
        # the mod: Unity does not poll input while the window is unfocused, so
        # every pad goes dead at once.
        sess.warn("no pad registered — refocusing the game window and retrying")
        focused = sess.focus()
        time.sleep(1.5)
        seen = probe()
        for i, pressed in seen.items():
            sess.log(f"after refocus, pad {i + 1} -> device {sorted(pressed)}")
        assert any(seen.values()), (
            f"holding A on a pad lit up no in-game device, focused or not "
            f"(focus attempt: {focused}). The pads exist on the host and the "
            f"game enumerated them, so the break is between Wine's XInput "
            f"layer and InControl.")
        sess.warn("pads only work with the window focused — a harness "
                  "requirement, not a mod bug")

    for i, pressed in seen.items():
        assert pressed, (
            f"holding A on pad {i + 1} lit up no in-game device, while other "
            f"pads did — that one pad is not reaching the game")

    pairs = list(seen.items())
    for a in range(len(pairs)):
        for b in range(a + 1, len(pairs)):
            (ia, sa), (ib, sb) = pairs[a], pairs[b]
            assert not (sa & sb), (
                f"pads {ia + 1} and {ib + 1} both drive in-game device(s) "
                f"{sorted(sa & sb)} — the game cannot tell the two controllers "
                f"apart, so per-player input is impossible")

    st = sess.channel.state()
    extra = len(st.get("devices", [])) - len(sess.baseline_devices) - len(sess.pads)
    note = ""
    if extra > 0:
        # Do NOT just call these Steam Input twins. That explanation is
        # plausible enough to stop an investigation, and it was wrong once:
        # the extras were dead virtual pads from runs that had been killed
        # while the game kept running, so InControl still held them. Player
        # one's pad then mapped to two device indices and the run reported the
        # mod misrouting controllers — the exact bug the architecture exists to
        # prevent, and a false alarm. Twins come in pairs, so an odd count or a
        # count that is not one per pad is a reason to suspect stale devices.
        twinnish = extra == len(sess.pads)
        note = (f"; NOTE {extra} more in-game device(s) than pads — "
                + ("consistent with Steam Input twins (one per pad)"
                   if twinnish else
                   "NOT a clean twin pattern, so these may be STALE devices "
                   "from an earlier run that was killed while the game kept "
                   "running. Restart the game before trusting any input "
                   "result from this run"))
        if not twinnish:
            sess.warn(note.lstrip("; "))
    return ("; ".join(f"pad {i + 1} -> device {sorted(p)}"
                      for i, p in seen.items()) + note)


@test("player one is driven by his own pad")
def t_p1_baseline(sess):
    """The baseline, before any clone exists.

    Without it, "player one stopped moving after player two joined" cannot be
    distinguished from "player one never moved on this pad at all", and those
    have completely different causes.
    """
    _ensure_unpaused(sess)
    tracks = _hold_right_same_room(sess, P1_PAD, 1)
    delta = _assert_drives_only(sess, P1_PAD, driven=1, others=[], tracks=tracks)
    sess.dump_state("01-p1-baseline")
    return f"player one travelled {delta:+.2f} units on pad 1, before any join"


@test("pressing Start on pad 2 spawns player two")
def t_join_p2(sess):
    _ensure_unpaused(sess)
    ok, last, before = _join_with_start(sess, P2_PAD, 2)
    if not ok:
        # Separate "spawning is broken" from "the pad never got through".
        probe = sess.channel.command("join")
        rejection = (last or {}).get("lastJoinRejection")
        sess.channel.command("leaveall")
        hint = ("the mod's own join command DID spawn a player, so spawning "
                "works and the Start press never reached it"
                if probe.get("playerCountAfter", 0) > probe.get("playerCountBefore", 0)
                else f"the mod's join command also refused: {probe}")
        raise AssertionError(
            f"playerCount stayed at {before} after Start on pad 2 "
            f"(rejection: {rejection!r}, gameState "
            f"{(last or {}).get('gameState')}). {hint}")
    p2 = _player(last, 2)
    assert p2, f"playerCount is 2 but there is no player 2 in {last.get('players')}"
    assert p2.get("pos"), "player two has no position — the clone has no transform"
    assert p2.get("device"), (
        "player two is bound to no controller at all — it spawned but nothing "
        "can drive it")
    p1 = _player(last, 1)
    assert p2.get("deviceGuid") != p1.get("deviceGuid"), (
        "player two was bound to player one's controller")
    sess.shot("02-player-two-joined")
    sess.dump_state("02-player-two-joined")
    return (f"player two on device index {p2.get('deviceIndex')} at "
            f"x={p2['pos']['x']:.1f} y={p2['pos']['y']:.1f}")


@test("player two moves on pad 2, and player one does not")
def t_p2_moves(sess):
    """Half one of the claim: the joiner's pad drives the joiner, only."""
    st = sess.channel.state()
    if st.get("playerCount", 1) < 2:
        raise Skip("player two is not in the session")
    _ensure_unpaused(sess)
    tracks = _hold_right_same_room(sess, P2_PAD, 2)
    try:
        delta = _assert_drives_only(sess, P2_PAD, driven=2, others=[1], tracks=tracks)
        went = "right"
    except AssertionError:
        # RIGHT alone cannot tell "this pad drives nothing" from "this Knight
        # is against a wall". Player two spawns beside player one, wherever
        # that happens to be, so the spot is not chosen and sometimes has
        # scenery immediately to the right — passing runs recorded as little as
        # +1.46 units, which is a case sitting on the edge of the geometry
        # rather than a healthy margin. Ask the same question the other way
        # before calling the pad dead.
        tracks = _hold_left_same_room(sess, P2_PAD, 2)
        delta = _assert_drives_only(sess, P2_PAD, driven=2, others=[1],
                                    tracks=tracks, direction="LEFT")
        went = "left (right was blocked)"
    sess.shot("03-player-two-moved")
    sess.dump_state("03-player-two-moved")
    return (f"player two travelled {delta:+.2f} units {went} on pad 2; "
            f"player one held still")


@test("player one STILL moves on his own pad after player two joined")
def t_p1_after_join(sess):
    """Half two, and the half a one-directional test misses entirely.

    Spawning a clone rebinds input: the joining pad is excluded from player
    one's action set so it cannot drive him or the pause menu. Excluding the
    wrong device — or excluding one Steam Input twin while its partner stays
    bound — leaves player one deaf to his own controller. From the couch that
    is the more obvious bug of the two, because player one was working a
    moment earlier.
    """
    st = sess.channel.state()
    if st.get("playerCount", 1) < 2:
        raise Skip("player two never joined, so nothing was rebound")
    _ensure_unpaused(sess)
    tracks = _hold_right_same_room(sess, P1_PAD, 1)
    try:
        delta = _assert_drives_only(sess, P1_PAD, driven=1, others=[2], tracks=tracks)
    except AssertionError as ex:
        raise AssertionError(
            f"{ex}  Player one moved on this same pad before player two "
            f"joined, so joining is what changed it — look at which device the "
            f"join excluded from player one's action set.")
    sess.dump_state("04-p1-after-join")
    return (f"player one still travelled {delta:+.2f} units on pad 1 with a "
            f"clone on the field; player two held still")


@test("the camera widens when the group spreads")
def t_camera_widens(sess):
    """The camera must actually zoom out — on the real render parameter.

    Hollow Knight's world camera is PERSPECTIVE: tk2dCamera drives it as
    fieldOfView / ZoomFactor and calls ResetProjectionMatrix, so
    cam.orthographicSize is an inert leftover. The mod wrote its zoom there
    until v0.7.12, which meant AutoZoom did nothing in every released build —
    and, because that inert 480 dwarfed every real distance, the screen
    leash's "the camera cannot frame this" test was never true either. Both
    features were dead and nothing said so.

    So this asserts on fieldOfView, the number the renderer actually uses.
    """
    st = sess.channel.state()
    if st.get("playerCount", 1) < 2:
        raise Skip("needs two Knights to have a group to frame")
    cam = st.get("camera") or {}
    if not cam.get("present"):
        raise Skip("the state channel is not reporting a camera")

    assert cam.get("orthographic") is False, (
        "this test assumes the perspective camera Hollow Knight actually uses; "
        f"the channel reports orthographic={cam.get('orthographic')}")

    _ensure_unpaused(sess)
    widest, started, asked, got, peak = _spread_apart(sess)
    assert started is not None and widest is not None, (
        "the state channel reported no fieldOfView, so zoom cannot be measured")

    # Self-calibrating: the camera is only obliged to widen once the group
    # actually needs more view than the game's own. Without this, a hold that
    # simply did not separate the Knights far enough reads exactly like a
    # camera refusing to zoom, and those have opposite meanings.
    # A run that could not create the condition has not found a bug, and
    # reporting it as one buries real failures in noise. Note this is a SKIP
    # only for "never spread far enough" — the camera refusing to widen when
    # the group DID need it stays a hard failure below.
    if not asked:
        raise Skip(
            f"the Knights never spread far enough to need more than the base "
            f"view (fieldOfView {started:.2f} -> peak {widest:.2f} deg). The "
            f"room they start in is too cramped to separate that far; the "
            f"split-screen case reaches a real spread later and exercises the "
            f"same framing math")
    assert got, (
        f"the group needed more view than the base and the camera refused to "
        f"widen: fieldOfView peaked at {widest:.2f} deg against an un-zoomed "
        f"{cam.get('tk2dSettingsFov')} deg. On this camera zoom is "
        f"fieldOfView / ZoomFactor — a zoom written to orthographicSize is "
        f"silently discarded")

    sess.dump_state("05-camera-widened")
    return (f"at widest spread the group needed {peak.get('neededHalfHeight', 0):.1f} "
            f"world units of view against an un-zoomed "
            f"{peak.get('baseHalfHeight', 0):.1f}, and the camera gave "
            f"{peak.get('currentHalfHeight', 0):.1f} "
            f"(fieldOfView {started:.1f} -> {widest:.1f} deg)")


@test("the screen splits when the Knights spread, and merges when they regroup")
def t_split_screen(sess):
    """Dynamic split-screen: one pane per Knight, along the axis they parted on.

    The threshold is deliberately moved for this case. Split engages only once
    the group needs more view than the camera may give, which at the shipped
    MaxZoomFactor is roughly forty world units of separation — further than two
    Knights can walk apart without leaving the room, so the case would test
    room transitions instead of split-screen. Dropping the zoom ceiling to 1.0
    makes the same code path reachable indoors. The threshold moves; the logic
    under test does not.
    """
    st = sess.channel.state()
    if st.get("playerCount", 1) < 2:
        raise Skip("needs two Knights to have anything to split between")
    if st.get("split") is None:
        raise Skip("this build does not report a split layout")

    _ensure_unpaused(sess)
    # How bright the world is with ONE whole view, to measure the split
    # against. An absolute floor would misjudge a genuinely dark room.
    whole_shot = sess.shot("07-before-split")
    whole_light = _mean_brightness(whole_shot)

    r = sess.channel.command("setcfg", key="MaxZoomFactor", value="1.0")
    assert r.get("ok"), f"could not lower the zoom ceiling for this case: {r}"
    restore = r.get("was", 1.6)
    try:
        _spread_apart(sess)
        st = sess.channel.state()
        sess.dump_state("07-split-attempt")
        # Pixels, not just geometry. Everything else here reads the layout the
        # mod decided; only a screenshot shows whether the panes actually drew.
        shot_path = sess.shot("07-split-attempt")
        split, cam = _cam_split(st), _cam(st)
        xs = [p["pos"]["x"] for p in st.get("players", [])
              if p.get("pos") and p["pos"].get("x") is not None]
        spread = (max(xs) - min(xs)) if len(xs) > 1 else 0.0
        assert not split.get("abandoned"), (
            "the split-screen driver threw on three consecutive frames and stood "
            "itself down — see the BepInEx log. It releases the camera when it "
            "does that, so the view is whole rather than black, but the feature "
            "is off")
        # Not splitting when the group never outgrew the view is the correct
        # behaviour, not a bug — the same distinction the zoom case draws. How
        # far two Knights can actually separate depends on the room they happen
        # to be standing in, and reporting "the screen refused to split" for a
        # run that never asked it to buries real failures in noise.
        needed = cam.get("neededHalfHeight") or 0
        allowed = cam.get("allowedHalfHeight") or 0
        if not split.get("active") and needed <= allowed * 1.15:
            raise Skip(
                f"the Knights only reached {spread:.1f} units apart, needing "
                f"{needed} of view against an allowed {allowed} — under the "
                f"threshold, so no split was ever asked for. The room did not "
                f"give them space to separate; this is the harness failing to "
                f"set up the case, not the mod refusing to split")

        assert split.get("active"), (
            f"the group needed {needed} of view against an allowed {allowed} "
            f"(un-zoomed {cam.get('baseHalfHeight')}) with the Knights "
            f"{spread:.1f} units apart — past the threshold, and the screen "
            f"still stayed whole (paneCount {split.get('paneCount')})")

        panes = split.get("panes") or []
        assert len(panes) == 2, (
            f"two Knights should divide the screen two ways, got {len(panes)}")

        # In rotating mode the screen is cut into regions, not rectangles, so
        # the pane rects describe nothing drawn. The mod says which it is.
        if split.get("paneRectsApply") is False:
            sess.log("rotating split active — pane rectangles do not apply, "
                     "skipping the geometry assertions")
            return (f"screen split {len(panes)} ways with a rotating divider")
        widths = sorted(round(p["w"], 3) for p in panes)
        heights = sorted(round(p["h"], 3) for p in panes)
        assert widths[0] == widths[-1] and heights[0] == heights[-1], (
            f"panes must be identical in size — DarknessCameraEffect resizes "
            f"its RenderTexture whenever the camera's pixel dimensions change, "
            f"so uneven panes thrash a RenderTexture every frame. Got widths "
            f"{widths}, heights {heights}")

        # The panes must actually draw. This is the only assertion here that
        # looks at the screen rather than at what the mod says it decided.
        split_light = _mean_brightness(shot_path)
        if whole_light is not None and split_light is not None:
            assert split_light >= whole_light * 0.5, (
                f"the screen is split but the panes are not drawing: the world "
                f"averages {split_light:.1f} brightness while split against "
                f"{whole_light:.1f} whole. The layout can be perfect and the "
                f"view still black — a manual Camera.Render() that never "
                f"reaches the screen leaves the HUD intact and the world gone")

        # While they are still apart, prove the OTHER way of reaching the
        # screen works too. SplitRotate ships off, and its own description
        # calls the plain split "the verified one" — but off-and-untested is a
        # worse answer than off-and-known-to-work, and it is the riskier path:
        # pane cameras render into textures and a compositor paints the regions
        # itself, so a mistake there is a black screen. Checked here rather
        # than in a case of its own because recreating this separation later,
        # with the party already clustered, does not reliably reach the
        # threshold — a standalone case simply skipped every time.
        rotate_problem = None
        rot = sess.channel.command("setcfg", key="SplitRotate", value="true")
        rot_was = rot.get("was", False)
        try:
            _nap(sess, 0.6)
            rst = sess.channel.state()
            rsplit = rst.get("split") or {}
            if rsplit.get("rotating") is True:
                rshot = sess.shot("13-rotating-split")
                rlight = _mean_brightness(rshot)
                # Recorded, NOT asserted here. Throwing mid-case skipped the
                # merge below and left the party spread and the screen split
                # for every case that followed — friendly fire and the death
                # case then failed as collateral, which reads as three broken
                # features instead of one. The verdict is raised at the end,
                # once this case has put the game back.
                if whole_light and rlight is not None and rlight < whole_light * 0.4:
                    rotate_problem = (
                        f"the rotating compositor engaged and the world went "
                        f"dark: {rlight:.1f} against {whole_light:.1f} whole. "
                        f"It paints the screen from render textures, so a "
                        f"mistake there is a black screen, not a wrong-looking "
                        f"one")
                sess.log(f"rotating split drew {rsplit.get('paneCount')} region(s) "
                         f"at {rlight:.1f} brightness "
                         f"(normal {rsplit.get('rotateNormalX')}, "
                         f"{rsplit.get('rotateNormalY')})")
            else:
                sess.warn("SplitRotate was switched on but the compositor did "
                          "not take it (it stands down when its shader is "
                          "missing), so the rotating path is still unverified")
        finally:
            sess.channel.command("setcfg", key="SplitRotate",
                                 value=str(bool(rot_was)).lower())

        # The cut must follow the axis they ACTUALLY parted on, which is not
        # necessarily the one they were driven along: Hollow Knight's terrain
        # routinely leaves one Knight far above the other, and a run that
        # assumed "they walked left and right, so the split is vertical" called
        # a correct horizontal split a bug.
        ys = [p["pos"]["y"] for p in st.get("players", [])
              if p.get("pos") and p["pos"].get("y") is not None]
        spread_y = (max(ys) - min(ys)) if len(ys) > 1 else 0.0
        side_by_side = spread >= spread_y
        axis = "x" if side_by_side else "y"
        if side_by_side:
            assert widths[0] < heights[0], (
                f"the Knights are further apart along x ({spread:.1f}) than y "
                f"({spread_y:.1f}), so the screen should be cut into side-by-side "
                f"panes (narrow and tall); got {widths[0]:.2f} wide by "
                f"{heights[0]:.2f} high")
        else:
            assert widths[0] > heights[0], (
                f"the Knights are further apart along y ({spread_y:.1f}) than x "
                f"({spread:.1f}), so the screen should be cut into stacked panes "
                f"(wide and short); got {widths[0]:.2f} wide by "
                f"{heights[0]:.2f} high")

        # And it must come back together. Regroup with a short fixed leash
        # rather than by walking: walking cannot close a VERTICAL gap, and
        # Hollow Knight's platforms routinely leave one Knight tens of units
        # above another — a run reached this point with the Knights 43 units
        # apart in y, which no amount of walking left and right would fix. The
        # fixed-distance leash is shipped behaviour, it pulls the extras to
        # player one wherever they are, and it is independent of terrain.
        # Put the zoom ceiling back to what a player actually runs before
        # testing the merge. It was only lowered to make the split reachable
        # indoors; leaving it down makes "regrouped" mean almost touching,
        # because needed half-height has a floor of ZoomMargin and the whole
        # window between "needs more view" and "does not" collapses to about a
        # world unit. Splitting is tested under a reachable threshold, merging
        # under the shipped one.
        sess.channel.command("setcfg", key="MaxZoomFactor", value=str(restore))
        r2 = sess.channel.command("setcfg", key="LeashDistance", value="5")
        assert r2.get("ok"), f"could not set a regrouping leash: {r2}"
        leash_was = r2.get("was", -1)
        try:
            _wait_still(sess)
            ok, last = sess.channel.wait_for(
                lambda s: not (_cam_split(s).get("active")), timeout=10)
        finally:
            sess.channel.command("setcfg", key="LeashDistance", value=str(leash_was))
        lc = _cam(last)
        assert ok, (
            f"the Knights regrouped and the screen stayed split "
            f"(paneCount {_cam_split(last).get('paneCount')}) — a split that "
            f"cannot merge is worse than no split at all. The group needed "
            f"{lc.get('neededHalfHeight')} of view against an allowed "
            f"{lc.get('allowedHalfHeight')}; merge happens below "
            f"allowed * (1 - SplitMergeMargin)")
        # Asserted again now that it works. It painted black until the
        # triangle fan's winding was fixed (back-face culling silently
        # discarded the fill), and this check is what caught that — so it goes
        # back to failing rather than warning, or the next regression in this
        # path is a warning nobody reads.
        assert rotate_problem is None, rotate_problem

        sess.dump_state("07-split-merged")

        # Say what each pane actually drew. A dark pane here is not failed on —
        # a Knight can legitimately stand somewhere unlit — but it is the
        # difference between "split works" and "split works and both players
        # can see", and without it a half-black screen passes silently.
        lit = _pane_brightness(shot_path, [p["viewport"] if "viewport" in p else p
                                           for p in panes])
        lit_note = ""
        if lit:
            lit_note = " panes lit " + ", ".join(
                "?" if v is None else f"{v:.1f}" for v in lit)
            if any(v is not None and v < 1.0 for v in lit):
                lit_note += " (a pane drew almost nothing — check that Knight "
                lit_note += "is somewhere with scenery)"
        return (f"screen split two ways across {axis} (apart {spread:.1f} by "
                f"{spread_y:.1f}), then merged when they regrouped.{lit_note}")
    finally:
        sess.channel.command("setcfg", key="MaxZoomFactor", value=str(restore))


@test("a third pad joins as player three")
def t_join_p3(sess):
    st = sess.channel.state()
    if st.get("playerCount", 1) < 2:
        raise Skip("player two never joined, so there is nothing to add to")
    if len(sess.pads) < 3:
        raise Skip("fewer than three virtual pads were created")

    _ensure_unpaused(sess)
    ok, last, before = _join_with_start(sess, P3_PAD, 3)
    assert ok, (
        f"playerCount stayed at {before} after Start on pad 3 "
        f"(rejection: {(last or {}).get('lastJoinRejection')!r}, gameState "
        f"{(last or {}).get('gameState')}). A Start press that pauses instead "
        f"of joining means the mod did not recognise pad 3 as a spare.")
    p2, p3 = _player(last, 2), _player(last, 3)
    assert p3 and p3.get("deviceGuid"), f"no player three device: {p3}"
    # Compare GUIDs, not names — every pad is called "Xbox Controller", so a
    # name comparison reports a collision that is not there.
    assert p3["deviceGuid"] != p2["deviceGuid"], (
        f"players two and three are bound to the SAME controller "
        f"(guid {p3['deviceGuid']}, index {p3.get('deviceIndex')}) — "
        f"one pad is driving two Knights")
    sess.shot("05-three-players")
    sess.dump_state("05-three-players")
    return (f"player three on device index {p3.get('deviceIndex')}, player two "
            f"on index {p2.get('deviceIndex')}")


@test("three Knights divide the screen three ways")
def t_split_three(sess):
    """The pane count follows the roster, not just the two-player case.

    Two panes are halves; three are equal strips. Nothing about the two-Knight
    case exercises that, and "up to four panes" was a deliberate design choice
    rather than a side effect, so it gets its own coverage.
    """
    st = sess.channel.state()
    if st.get("playerCount", 1) < 3:
        raise Skip("needs three Knights")
    if st.get("split") is None:
        raise Skip("this build does not report a split layout")

    _ensure_unpaused(sess)
    r = sess.channel.command("setcfg", key="MaxZoomFactor", value="1.0")
    assert r.get("ok"), f"could not lower the zoom ceiling for this case: {r}"
    restore = r.get("was", 1.6)
    try:
        # Player one one way, player three the other, player two left where it
        # stands — three distinct positions along the axis, which is what a
        # three-way split needs to be meaningful.
        _wait_playing(sess)
        # Centre ALL three first. The previous case regroups everyone onto
        # player one with a leash, which leaves the whole party wherever that
        # put them — last run, jammed against the left wall, where walking
        # further left does nothing and the span never reaches the threshold.
        for pad, n in ((P1_PAD, 1), (P2_PAD, 2), (P3_PAD, 3)):
            _walk_to_room_middle(sess, pad, n)
        _wait_still(sess)

        p1, p3 = sess.pad(P1_PAD), sess.pad(P3_PAD)
        t0, budget = time.time(), 2.5 * _pace(sess)
        while time.time() - t0 < budget:
            p1.stick(-1.0, 0.0)
            p3.stick(1.0, 0.0)
            _nap(sess, 0.2)
        p1.neutral()
        p3.neutral()
        _nap(sess, 0.5)

        st3 = sess.channel.state()
        split, cam3 = _cam_split(st3), _cam(st3)
        sess.dump_state("08-split-three")
        sess.shot("08-split-three")

        # Could this run create the condition at all? Three Knights have to be
        # driven to three separate places, and Hollow Knight's terrain does not
        # cooperate with choreography — walls, ledges and drops stop a Knight
        # wherever they please, and a run reached here with all three inside
        # ten world units. A group that still fits in one view is a group the
        # mod is RIGHT not to split for, so that is reported as a setup that
        # did not happen rather than as a mod failure.
        # A skip here is only honest when the group genuinely fitted in one
        # view. If it DID outgrow the view and the screen still did not split,
        # that is the failure this case exists for — prove-mode caught this
        # skipping under its own never_splits fault, which makes a case
        # decoration rather than a check.
        if not _asked_for_zoom(cam3) and not split.get("active"):
            raise Skip(
                f"the three Knights could not be driven far enough apart in this "
                f"room to outgrow one view (needed {cam3.get('neededHalfHeight')} "
                f"against an un-zoomed {cam3.get('baseHalfHeight')}), so the "
                f"three-way split was never asked for")

        assert split.get("active"), (
            f"three Knights spread past what one view can hold and the screen "
            f"stayed whole (paneCount {split.get('paneCount')}): needed "
            f"{cam3.get('neededHalfHeight')} of view against an allowed "
            f"{cam3.get('allowedHalfHeight')}")
        panes = split.get("panes") or []
        assert len(panes) == 3, (
            f"three Knights should divide the screen three ways, got {len(panes)}")

        # In rotating mode the screen is cut into regions, not rectangles, so
        # the pane rects describe nothing drawn. The mod says which it is.
        if split.get("paneRectsApply") is False:
            sess.log("rotating split active — pane rectangles do not apply, "
                     "skipping the geometry assertions")
            return (f"screen split {len(panes)} ways with a rotating divider")
        widths = sorted(round(p["w"], 3) for p in panes)
        heights = sorted(round(p["h"], 3) for p in panes)
        assert widths[0] == widths[-1] and heights[0] == heights[-1], (
            f"panes must be identical in size; got widths {widths}, heights {heights}")

        held = sorted(len(p.get("knights") or []) for p in panes)
        assert held == [1, 1, 1], (
            f"each pane should hold exactly one Knight, got {held} — a pane with "
            f"none renders empty and a pane with two defeats the split")
        return f"three equal panes, one Knight each ({widths[0]:.2f} x {heights[0]:.2f})"
    finally:
        sess.channel.command("setcfg", key="MaxZoomFactor", value=str(restore))


@test("friendly fire lets one Knight hurt another")
def t_friendly_fire(sess):
    """Off by default, and structurally impossible without the mod's help.

    A nail's DamageEnemies drops layer 9 — the hero layer — when collecting
    targets, and the damage it would deal goes through HitTaker to an
    IHitResponder, which heroes do not have. Two independent reasons a swing
    passes through a teammate, so this asserts a hit actually lands rather than
    that a toggle exists.
    """
    st = sess.channel.state()
    if st.get("playerCount", 1) < 2:
        raise Skip("needs a teammate to hit")
    _ensure_unpaused(sess)

    r = sess.channel.command("setcfg", key="FriendlyFire", value="true")
    assert r.get("ok"), f"could not enable friendly fire: {r}"
    was_ff = r.get("was", False)
    # Stand them together, deterministically. Walking two Knights into nail
    # range is choreography this terrain does not cooperate with; a short fixed
    # leash puts the extras on player one wherever they are.
    r2 = sess.channel.command("setcfg", key="LeashDistance", value="4")
    leash_was = r2.get("was", -1)
    try:
        _wait_playing(sess)
        _wait_still(sess)
        before = {p["n"]: p.get("health") for p in sess.channel.state().get("players", [])}

        # Only the CLONE swings. A clone hurting the vanilla hero is the case
        # worth proving: player one's own swing is ordinary game code and would
        # pass this test without the mod's damage path being exercised at all.
        #
        # Both pads were swung for one run, deliberately, to tell "the attack
        # button is not binding" from "a clone cannot attack" — it was the
        # binding (see pads.py). That diagnostic has served its purpose and is
        # removed: leaving it in would let player one's hit satisfy the
        # mask-loss assertion and hide a clone that cannot land one.
        for _ in range(6):
            sess.pad(P2_PAD).press("X", 0.08)
            _nap(sess, 0.25)
        _nap(sess, 0.5)

        after_state = sess.channel.state()
        after = {p["n"]: p.get("health") for p in after_state.get("players", [])}
        sess.dump_state("09-friendly-fire")

        # Assert on the mod's own hit counter, NOT merely on health dropping.
        # A run passed this case with swings:0 hits:0 — nothing had swung and
        # nothing had been struck, but an ENEMY had damaged someone, and "a
        # mask was lost" cannot tell those apart. Enemies now target the
        # nearest Knight rather than fixating on player one, so that
        # confusion is routine rather than unlucky.
        ff = (after_state.get("friendlyFire") or {})
        assert ff.get("swings", 0) > 0, (
            f"no nail swing was registered at all ({ff}) — the attack input "
            f"never reached the game, so friendly fire was not exercised. "
            f"Hollow Knight binds attack to Action3, physical X, which on an "
            f"Xbox-360-identifying pad is evdev BTN_NORTH (0x133) — NOT "
            f"BTN_WEST, whatever the positional naming suggests. Compare "
            f"rawAction3 against rawAnyButton: a face button arriving while "
            f"rawAction3 stays 0 means the mapping is wrong, not the mod")
        assert ff.get("hits", 0) > 0, (
            f"player two swung {ff.get('swings')} time(s) at point-blank range "
            f"and landed no friendly-fire hit ({ff}). overlaps={ff.get('overlaps')} "
            f"says whether the blade was ever measured as touching them")

        # Assert on the mod's OWN measurement of a mask coming off, taken
        # across its TakeDamage call. Comparing health before and after the
        # whole sequence cannot tell our damage from an enemy's, and an enemy
        # hit satisfying it is how this passed while friendly fire dealt
        # nothing at all: hits counted 3 while every Knight stayed at 6.
        assert ff.get("landed", 0) > 0, (
            f"the mod dealt {ff.get('hits')} friendly-fire hit(s) and not one "
            f"took a mask off ({ff.get('refused')} refused). "
            f"HeroController.TakeDamage declines silently — invulnerability "
            f"frames from an earlier hit, damage mode, recoil — so a hit "
            f"counter alone does not mean damage. Health before {before}, "
            f"after {after}")

        hurt = [n for n in before
                if before.get(n) is not None and after.get(n) is not None
                and after[n] < before[n]]
        # Either direction counts, so do not demand a specific victim.
        # Self-damage would mean the attacker is not excluded from its own
        # swing, which is a different bug from not landing at all.
        assert ff.get("hits", 0) > 0, "no friendly-fire hit recorded"
        # Name whoever actually lost the mask. Hardcoding player one read
        # "took 6 -> 6 masks off player one" on a passing run, which describes
        # no damage at all and sent a diagnosis off after the wrong half.
        victim = hurt[0] if hurt else "?"
        return (f"player two's nail landed {ff.get('landed')} of "
                f"{ff.get('hits')} hit(s) ({ff.get('refused')} refused by "
                f"invulnerability); player {victim} went "
                f"{before.get(victim)} -> {after.get(victim)} masks")
    finally:
        sess.channel.command("setcfg", key="FriendlyFire", value=str(was_ff).lower())
        sess.channel.command("setcfg", key="LeashDistance", value=str(leash_was))


@test("the party arrives together after a room change")
def t_transition_together(sess):
    """The bug a player hit and this rig kept walking straight past.

    Extras take no part in a transition: GameManager calls LeaveScene and
    EnterScene on hero_ctrl, which is player one and nobody else. So an extra
    keeps the coordinates it held in the PREVIOUS room, and the party arrives
    spread between whatever entrances those coordinates land near — reported
    from play as "one spawned at top and the other on bottom".

    Earlier runs crossed rooms constantly and never checked this, because the
    movement cases treat a transition as something to retry around rather than
    something to assert on.
    """
    st = sess.channel.state()
    if st.get("playerCount", 1) < 2:
        raise Skip("needs two Knights to arrive together or apart")
    _ensure_unpaused(sess)
    _wait_playing(sess)

    before_scene = st.get("scene")
    gathers_before = st.get("gathers", 0)

    # Walk player one at a wall until the room changes. Either direction will
    # do; whichever edge is nearer wins.
    width = st.get("sceneWidth") or 0
    x = _x(_player(st, 1)) or 0
    direction = 1.0 if (width and x < width / 2.0) else -1.0
    pad = sess.pad(P1_PAD)
    changed = None
    # Try the nearer edge first, then the other one. Heading for the closer
    # side is a good guess and not a reliable one: a room's nearer edge may
    # have no door at all, or terrain in the way, and this case then skipped
    # depending only on where the previous case happened to leave the party.
    # Walking the other way costs nothing when the first attempt works.
    for way in (direction, -direction):
        t0 = time.time()
        # Each direction gets its own full budget rather than half of the old
        # one. Splitting 25s into two 14s halves made the near edge cheaper to
        # give up on than it used to be, so a door that was previously reached
        # in ~20s now times out and the case skips "in either direction" —
        # trading one skip for another.
        while time.time() - t0 < 24 * _pace(sess):
            pad.stick(way, 0.0)
            _nap(sess, 0.25)
            now = sess.channel.state()
            if now.get("scene") and now.get("scene") != before_scene:
                changed = now.get("scene")
                break
        pad.neutral()
        if changed:
            break
        sess.log(f"no transition {'right' if way > 0 else 'left'} of "
                 f"{before_scene}; trying the other way")
    if not changed:
        raise Skip(f"could not reach a room transition from {before_scene} "
                   f"in either direction, so nothing was tested")

    # Let the arrival settle: vanilla walks player one in for a few frames
    # after it reports him in position, and the mod collects the party across
    # that window.
    _wait_playing(sess)
    _nap(sess, 2.0)
    _wait_still(sess)

    after = sess.channel.state()
    sess.dump_state("10-after-transition")
    sess.shot("10-after-transition")
    xs, ys = [], []
    for p in after.get("players", []):
        if p.get("pos"):
            xs.append(p["pos"]["x"])
            ys.append(p["pos"]["y"])
    assert len(xs) >= 2, "lost a Knight across the transition"

    spread = max(max(xs) - min(xs), max(ys) - min(ys))
    gathers = after.get("gathers", 0)
    gate = after.get("entryGate")
    sess.log(f"arrived in {changed} via gate {gate!r}; "
             f"x {min(xs):.1f}..{max(xs):.1f}, y {min(ys):.1f}..{max(ys):.1f}")
    assert spread < 20.0, (
        f"the party arrived {spread:.1f} world units apart in {changed} "
        f"(x {min(xs):.1f}..{max(xs):.1f}, y {min(ys):.1f}..{max(ys):.1f}). "
        f"Extras take no part in a transition, so without being collected they "
        f"keep the previous room's coordinates. Entry gate {gate!r}, gathers "
        f"logged: {gathers - gathers_before}")
    return (f"{before_scene} -> {changed}, party within {spread:.1f} units "
            f"({gathers - gathers_before} Knight(s) collected)")


@test("each Knight has its own health pool")
def t_separate_health(sess):
    st = sess.channel.state()
    if st.get("playerCount", 1) < 2:
        raise Skip("no extra players in the session")
    pools = [(p["n"], p.get("health"), p.get("maxHealth"))
             for p in st.get("players", [])]
    for n, hp, mx in pools:
        assert hp is not None and hp >= 0, f"player {n} has no health value ({hp})"
        assert mx and mx > 0, f"player {n} has no max health ({mx})"
    return "; ".join(f"P{n} {hp}/{mx}" for n, hp, mx in pools)


@test("the multiplayer entry sits with the other options, above Back")
def t_menu_placement(sess):
    """Where the entry is drawn, not merely that it exists.

    Reported from play as the option being "in a weird spot": it was placed one
    step below the LOWEST button in Options, and Options ends with Back — so it
    hung underneath Back, detached from the group it belongs to, and the
    controller ran Game Options -> ... -> Back -> Multiplayer.

    This is the one part of the mod invisible from the state channel, so the
    mod reports the order it built and this checks it. Opening the screen
    through the channel rather than driving the title menus blind keeps the
    case about the entry instead of about menu navigation.
    """
    _ensure_unpaused(sess)
    sess.channel.command("options")
    ok, st = sess.channel.wait_for(
        lambda s: (s.get("menu") or {}).get("entryIndex", -1) >= 0, timeout=15)
    menu = (st or {}).get("menu") or {}
    names = [e.get("name") for e in menu.get("order", [])]

    assert menu.get("built"), (
        f"the multiplayer screen was never built, so Options has no entry "
        f"(order {names}). Everything falls back to the config file")
    ours = menu.get("entryIndex", -1)
    back = menu.get("backIndex", -1)
    assert ours >= 0, f"no HKCC_ entry in the Options list (order {names})"

    sess.shot("11-options-menu")
    if back < 0:
        # Not an assertion, but not a quiet pass either: this is the branch
        # that placed the entry by fallback, which is the placement that was
        # reported as wrong in the first place.
        sess.warn(f"no Back/Apply entry recognised in Options, so the entry "
                  f"was positioned by fallback and its placement is NOT "
                  f"verified (order {names})")
        return f"multiplayer entry present at index {ours} of {len(names)}, placement unverified"

    assert ours < back, (
        f"the multiplayer entry is BELOW Back (entry at {ours}, Back at "
        f"{back}, order {names}) — it hangs off the bottom of the menu "
        f"instead of sitting with the options it belongs to")
    sess.shot("11-options-menu")
    return (f"multiplayer entry at index {ours}, Back at {back} "
            f"({' | '.join(n or '?' for n in names)})")


@test("a fallen player leaves a shade instead of ending the run")
def t_shade_on_death(sess):
    """The run survives one player dying, and the shade is the way back.

    Player one is the case that matters. He is the save file and the singleton
    the camera follows, so the old behaviour was to despawn everyone and run
    the vanilla game-over — one player's mistake ended the other's run. He now
    goes down like anyone else, hidden in place rather than destroyed, with a
    shade a teammate beats to bring him back.
    """
    _ensure_unpaused(sess)
    st = sess.channel.state()
    if st.get("playerCount", 1) < 2:
        raise Skip("needs a teammate — a solo death is a real death")
    if not (st.get("config") or {}).get("independentHealth", True):
        raise Skip("shared health pool: a death IS the team's death")

    before_scene = st.get("scene")
    sess.channel.command("kill", n=1)
    ok, last = sess.channel.wait_for(
        lambda s: s.get("playerOneDowned") is True, timeout=20)

    assert ok, (
        f"player one died and did not go down: playerOneDowned stayed "
        f"{(last or {}).get('playerOneDowned')}. Either the death ran vanilla "
        f"(which ends the session) or the down path refused — it needs "
        f"IndependentHealth and ShadeRevive on, and someone else standing")

    # The run must still be the same run: a vanilla game-over reloads the scene
    # and drops the party, which is exactly what this replaces.
    assert last.get("scene") == before_scene, (
        f"the scene changed from {before_scene} to {last.get('scene')} — that "
        f"is the vanilla death respawn, so the run ended rather than the life")
    assert last.get("playerCount", 0) >= 2, (
        f"playerCount fell to {last.get('playerCount')} — the teammates were "
        f"despawned, which is the game-over path this case exists to avoid")

    sess.shot("12-player-one-downed")
    sess.dump_state("12-player-one-downed")
    return (f"player one is down in {last.get('scene')} with "
            f"{last.get('playerCount')} player(s) still in the session")


@test("holding Start removes a player")
def t_leave(sess):
    _ensure_unpaused(sess)
    st = sess.channel.state()
    before = st.get("playerCount", 1)
    if before < 2:
        raise Skip("nobody to remove")

    sess.log("holding START on pad 2 for 2.0s…")
    sess.pad(P2_PAD).press("START", 2.0)
    ok, last = sess.channel.wait_for(
        lambda s: s.get("playerCount") < before, timeout=20)
    assert ok, (
        f"playerCount stayed at {before} after a 2s Start hold on pad 2 "
        f"(LeaveHoldSeconds defaults to 1.2; gameState is "
        f"{(last or {}).get('gameState')})")
    after = last.get("playerCount")
    claimed = [d for d in last.get("devices", []) if d.get("claimed")]
    assert len(claimed) == after - 1, (
        f"{after - 1} extra player(s) but {len(claimed)} pad(s) still claimed — "
        f"a leaving player did not release its controller")
    sess.dump_state("06-after-leave")
    return f"players {before} -> {after}, controller released"


def teardown(sess):
    """Put the session back so a re-run starts clean."""
    try:
        sess.channel.command("leaveall")
    except Exception:
        pass
