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


def _hold_right(sess, pad_index, seconds=1.5):
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
    pad.stick(1.0, 0.0)
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


def _hold_right_same_room(sess, pad_index, driven_n, seconds=1.5, attempts=4):
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
        tracks = _hold_right(sess, pad_index, seconds)
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


def _assert_drives_only(sess, pad_index, driven, others, tracks):
    """`driven` moved right; every player in `others` stayed put."""
    d = tracks.get(driven)
    assert d is not None, f"player {driven} has no position — it is not on the field"
    start, end, peak = d
    delta = end - start

    assert abs(delta) > MOVED, (
        f"player {driven} moved {delta:+.2f} world units while pad "
        f"{pad_index + 1} held RIGHT — that pad is enumerated and bound, but "
        f"its stick is not driving that Knight")
    assert delta > 0, (
        f"player {driven} ended {delta:+.2f} from where it started while its "
        f"pad held RIGHT (furthest reached x={peak:.1f} from {start:.1f}), so "
        + ("it moved and was then pulled back — leash or a scripted reposition"
           if peak > start + STILL else "it moved in the wrong direction"))

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


def _spread_apart(sess, seconds=2.0, attempts=3):
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
        note = (f"; NOTE {extra} more in-game device(s) than pads — Steam Input "
                f"twins")
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
    delta = _assert_drives_only(sess, P2_PAD, driven=2, others=[1], tracks=tracks)
    sess.shot("03-player-two-moved")
    sess.dump_state("03-player-two-moved")
    return f"player two travelled {delta:+.2f} units on pad 2; player one held still"


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
    assert asked, (
        f"the Knights never spread far enough to need more than the base view "
        f"(fieldOfView {started:.2f} -> peak {widest:.2f} deg), so this run "
        f"could not test zoom at all. Harness problem, not a mod verdict")
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
        assert split.get("active"), (
            f"the screen stayed whole (paneCount {split.get('paneCount')}) with "
            f"the Knights {spread:.1f} world units apart: the group needed "
            f"{cam.get('neededHalfHeight')} of view against an allowed "
            f"{cam.get('allowedHalfHeight')} (un-zoomed {cam.get('baseHalfHeight')}). "
            f"Split engages above allowed * (1 + SplitMergeMargin)")

        panes = split.get("panes") or []
        assert len(panes) == 2, (
            f"two Knights should divide the screen two ways, got {len(panes)}")

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
        sess.dump_state("07-split-merged")
        return (f"screen split two ways across {axis} (apart {spread:.1f} by "
                f"{spread_y:.1f}), then merged when they regrouped")
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
        if not _asked_for_zoom(cam3):
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

        # Swing player two's nail a few times; they are standing on player one.
        for _ in range(6):
            sess.pad(P2_PAD).press("X", 0.08)
            _nap(sess, 0.35)
        _nap(sess, 0.5)

        after_state = sess.channel.state()
        after = {p["n"]: p.get("health") for p in after_state.get("players", [])}
        sess.dump_state("09-friendly-fire")

        hurt = [n for n in before
                if before.get(n) is not None and after.get(n) is not None
                and after[n] < before[n]]
        assert hurt, (
            f"nobody lost a mask while player two swung at point-blank range "
            f"with friendly fire on (health before {before}, after {after}). "
            f"A nail drops the hero layer when collecting targets, so this only "
            f"works if the mod deals the hit itself")
        assert 2 not in hurt, (
            f"player two hurt ITSELF swinging ({before.get(2)} -> {after.get(2)}) "
            f"— the attacker must be excluded from its own swing")
        return (f"player two's nail took {before.get(1)} -> {after.get(1)} masks "
                f"off player one")
    finally:
        sess.channel.command("setcfg", key="FriendlyFire", value=str(was_ff).lower())
        sess.channel.command("setcfg", key="LeashDistance", value=str(leash_was))


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
