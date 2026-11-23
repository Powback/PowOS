#!/usr/bin/env python3
"""game-resize.sh G3 (letterbox / pillarbox) on REAL screencaps of earlier runs: tools/phone/verify/bars.py + the
script's own boxed(). fixtures/game-bars/<name>.<W>x<H>.grey.xz = the saved PNG as 8-bit grey, xz, every value >= 16
stored as 255 (bars.py only tells 0 from > 0, so the verdicts are the PNG's; it keeps the fixtures ~600 KB in all).
Sources (~/.cache/powos-verify/...):
  NOT bars (the old row-average bars() said so):
    besiege-stars-folded-landscape-1119   game-resize-346010-2026-11-19_0017/folded-landscape  old letterbox-47/66
    besiege-stars-folded-landscape-1111   game-resize-346010-2026-11-11_0315/folded-landscape  old letterbox-47/64
      Besiege's menu = navy space with stars to the top edge; same false FAIL 11-18 22:00, 23:43, 23:57
    broforce-dark-art-folded-landscape-1107  bf-resize-2026-11-07_0046/folded-landscape  old pillarbox-238/164: an
      oversized window (G1 failed that step) - Broforce's own dark art on the left, another window's strip right
  full screen: besiege-full-unfolded-1119, besiege-full-folded-portrait-1119 (same 00:17 run, each step full screen)
  REAL bars, the old bars() found them too:
    besiege-letterbox-unfolded-1110            game-resize-346010-2026-11-10_0740/unfolded  old letterbox-420/473
    besiege-letterbox-folded-landscape-1110    game-resize-346010-2026-11-10_1113/folded-landscape  old 193/235
    besiege-letterbox-unfolded-landscape-1111  game-resize-346010-2026-11-11_0211/unfolded-landscape  old 442/478
    broforce-pillarbox-folded-landscape-1107   bf-resize-274190-2026-11-07_0439/folded-landscape  old 756/753 (the
      screen-edge handle is lit 4-11 px in from the right edge)
  REAL bars the old one MISSED (its ffmpeg area "average" of a 2268-2484 px row is not the row's average):
    besiege-box-unfolded-1118          game-resize-346010-2026-11-18_2332/unfolded  (a box: both pairs of bars)
    pedro-pillarbox-unfolded-1118      game-resize-557340-2026-11-18_2317/unfolded
    broforce-letterbox-folded-portrait-1107  bf-resize-274190-2026-11-07_0439/folded-portrait (status bar + fps HUD
      over the top bar: 0.278 of the row lit)
  wholly black: besiege-black-unfolded-landscape-1110 (game-resize-346010-2026-11-10_1113): top = the full height,
    game-resize.sh's G3-black-frame.
"""
import glob
import importlib.util
import lzma
import os
import re
import subprocess
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
VER = os.path.normpath(os.path.join(HERE, "..", "..", "tools", "phone", "verify"))
FIX = os.path.join(HERE, "fixtures", "game-bars")
spec = importlib.util.spec_from_file_location("bars", os.path.join(VER, "bars.py"))
bars = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bars)

# boxed() exactly as game-resize.sh has it (the verdict, not a copy of it).
with open(os.path.join(VER, "game-resize.sh")) as f:
    _src = f.read()
BOXED = re.search(r"^boxed\(\) \{.*?\n  function pair.*?\}'; \}\n", _src, re.S | re.M).group(0)


def frame(name):
    (path,) = glob.glob(os.path.join(FIX, name + ".*.grey.xz"))
    w, h = (int(v) for v in path.split(".")[-3].split("x"))
    with open(path, "rb") as f:
        raw = lzma.decompress(f.read())
    assert len(raw) == w * h, path
    return w, h, raw


def verdict(name):
    w, h, raw = frame(name)
    e = bars.edges(w, h, raw)
    line = "top=%(top)d bottom=%(bottom)d left=%(left)d right=%(right)d" % e
    out = subprocess.run(["bash", "-c", BOXED + 'boxed "$1" "$2"', "-", line, f"{w}x{h}"], capture_output=True,
                         text=True, check=True).stdout.strip()
    return e, out, (w, h)


NOT_BARS = ["besiege-stars-folded-landscape-1119", "besiege-stars-folded-landscape-1111",
            "broforce-dark-art-folded-landscape-1107", "besiege-full-unfolded-1119", "besiege-full-folded-portrait-1119"]
BARS = {  # name: the verdict's kind
    "besiege-letterbox-unfolded-1110": "letterbox", "besiege-letterbox-folded-landscape-1110": "letterbox",
    "besiege-letterbox-unfolded-landscape-1111": "letterbox", "broforce-pillarbox-folded-landscape-1107": "pillarbox",
    "besiege-box-unfolded-1118": "letterbox", "pedro-pillarbox-unfolded-1118": "pillarbox",
    "broforce-letterbox-folded-portrait-1107": "letterbox",
}


class GameBars(unittest.TestCase):
    def test_fixtures_all_used(self):
        names = {os.path.basename(p).split(".")[0] for p in glob.glob(os.path.join(FIX, "*.grey.xz"))}
        self.assertEqual(names, set(NOT_BARS) | set(BARS) | {"besiege-black-unfolded-landscape-1110"})

    def test_dark_art_is_not_a_bar(self):
        for n in NOT_BARS:
            e, out, _ = verdict(n)
            self.assertEqual(out, "", f"{n}: {e} -> {out}")

    def test_every_real_bar_found(self):
        for n, kind in BARS.items():
            e, out, _ = verdict(n)
            self.assertTrue(out.startswith(kind + "-"), f"{n}: {e} -> {out!r}, want {kind}")

    def test_real_bars_are_symmetric(self):
        # A centred smaller picture: both bars within a few px of each other once only pure black counts (the old
        # average read 420/514, 193/235 - a game's near-black art running on into the bar).
        for n in ["besiege-letterbox-unfolded-1110", "besiege-letterbox-folded-landscape-1110",
                  "besiege-letterbox-unfolded-landscape-1111", "besiege-box-unfolded-1118"]:
            e, _, _ = verdict(n)
            self.assertLessEqual(abs(e["top"] - e["bottom"]), 2, f"{n}: {e}")
        e, _, _ = verdict("broforce-pillarbox-folded-landscape-1107")
        self.assertLessEqual(abs(e["left"] - e["right"]), 2, e)  # handle bridged on the right

    def test_black_frame_is_full_side(self):
        e, _, (w, h) = verdict("besiege-black-unfolded-landscape-1110")
        self.assertEqual(e["top"], h)

    def test_a_lit_line_inside_a_bar_ends_it(self):
        # Only the screen-edge handle is bridged: a lit line deeper in the bar (a game's own) stops the count.
        w, h, raw = frame("besiege-letterbox-folded-landscape-1110")
        raw = bytearray(raw)
        raw[100 * w:101 * w] = b"\xff" * w
        self.assertEqual(bars.edges(w, h, bytes(raw))["top"], 100)


if __name__ == "__main__":
    unittest.main()
