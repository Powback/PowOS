#!/usr/bin/env python3
"""Hollow Knight + HKCouchCoop — end-to-end scenario.

The claim under test is a couch: **two people, two controllers, one screen.**
So the rig sets up exactly that. Pad 1 *is* player one — the pad the game was
already using, which always pauses and never joins. Pad 2 joins as player two.
Pad 3 joins as player three.

That configuration matters more than it looks. Putting player one on the
keyboard instead (`PlayerOnePadIndex=-1`) is easier to arrange, because then
every pad is a joiner and the harness needs no reserved pad — but it never
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
            time.sleep(0.5)
            return True
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

    pad = sess.pad(pad_index)
    pad.stick(1.0, 0.0)
    t0 = time.time()
    while time.time() - t0 < seconds:
        time.sleep(0.25)
        now = sess.channel.state()
        for n in numbers:
            tracks[n].append(_x(_player(now, n)))
    pad.neutral()
    time.sleep(0.6)

    final = sess.channel.state()
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
    return out


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


def _join_with_start(sess, pad_index, expect_count, timeout=25):
    """Press Start on a pad and wait for the roster to grow."""
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

    # Pads before the save loads: the first attached pad becomes player one's
    # (PlayerOnePadIndex=0), so it has to exist before there is a player one.
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
    tracks = _hold_right(sess, P1_PAD)
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
    tracks = _hold_right(sess, P2_PAD)
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
    tracks = _hold_right(sess, P1_PAD)
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
