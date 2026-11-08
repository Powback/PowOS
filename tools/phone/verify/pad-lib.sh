# shellcheck shell=sh
# tools/phone/verify/pad-lib.sh (sourced, in the PowOS session as powos or root): a check's input to a game or Steam
# the way the user's own arrives - as the PowOS on-screen controls' gamepad (powos-padd: the app's GamepadOverlay ->
# PadSender -> @powos.padd -> a Steam Deck controller over uhid), never XTEST. xdotool key/click is XTEST through
# Xwayland's EI socket: KWin opens its "Remote Control" (kwin_eis_prompter) prompt for it, which takes the focus,
# minimizes a full-screen game and swallows the keys (11-08 02:02, docs/research/broforce-fps.md). The prompt's
# settings are the owner's (security) - so the checks don't make an XTEST client at all; test/tier1/test-verify-no-xtest.sh.
#   pad_press <key>...   each key pressed and released (PAD_HOLD_S 0.12 s held, PAD_GAP_S 0.4 s apart), in order.
# Keys: pad buttons by powos-padd's names (A B X Y LB RB Back Start Guide LS RS up down left right) or the X key names
# the checks used before: Return/KP_Enter/space -> A, Escape/BackSpace -> B, Up/Down/Left/Right -> the d-pad, Tab -> RB.
# The pad's events are a "Steam Deck Controller" input device on the phone, which idle.sh's touch watcher counts as a
# person: the Mac side marks the run as the tools' own first (self_input_for in window-lock.sh).
# One client at a time on padd: this connection replaces the app's (the overlay reconnects on its next press, the same
# packet resent - PadSender); on close padd releases every button.
pad_press() { python3 - "$@" <<'PY'
import os, socket, struct, sys, time
BITS = {n: i for i, n in enumerate("A B X Y LB RB Back Start Guide LS RS up down left right".split())}
KEYS = {"Return": "A", "KP_Enter": "A", "space": "A", "Escape": "B", "BackSpace": "B", "Up": "up", "Down": "down",
        "Left": "left", "Right": "right", "Tab": "RB"}
PAD2 = struct.Struct("<4sIhhhhBBxx10h")
names = [KEYS.get(k, k) for k in sys.argv[1:]]
bad = [k for k, n in zip(sys.argv[1:], names) if n not in BITS]
if bad:
    sys.exit("pad_press: no pad button for %s" % " ".join(bad))
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    s.connect("\0powos.padd")
except OSError as e:
    sys.exit("pad_press: powos-padd unreachable (%s)" % e)
state = lambda b: PAD2.pack(b"PAD2", b, 0, 0, 0, 0, 0, 0, *([0] * 10))
hold, gap = float(os.environ.get("PAD_HOLD_S", "0.12")), float(os.environ.get("PAD_GAP_S", "0.4"))
for i, n in enumerate(names):
    s.sendall(state(1 << BITS[n])); time.sleep(hold)
    s.sendall(state(0))
    if i + 1 < len(names):
        time.sleep(gap)
time.sleep(0.2)  # the release applied before the close
s.close()
print("pad: " + " ".join(names))
PY
}
