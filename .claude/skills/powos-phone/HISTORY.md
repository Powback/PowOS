# powos-phone history

Older/fuller hand-off text, moved out of SKILL.md per friction f169 (hand-off logs bloat the skills).
SKILL.md keeps only a trimmed (<=200 word) version of each "Latest hand-off"; the full original is here.

## powos-verify hand-off, full text (SKILL.md keeps a trimmed version)

## Latest hand-off (2026-10-24, board task more-phone-checks-run-on-the-emulator-lane)

Classified all 95 directly-queued verify checks for the emulator lane (`# lanes:` header per check,
`--dev auto`, `--android-only`), pushed as commit 4ec76979. Confirmed on re-test:
- `resize-probe.sh --apps calc` - **PASS** (clean proof).
- `window-scroll.sh --android-only` - **FAIL**: `[chrome fresh] down near the top edge: shade=true ...
  home took the scroll`. Open question, not yet investigated: is Chrome's window taking that swipe
  differently on the emulator (rendering/layout) than Calculator does, or a real touch-routing bug that
  also exists on the phone? Needs a look before trusting this lane for Chrome scroll checks.
- `e2e-desktop.sh --part 2 --of 3` and `--part 1 --of 3 --android-only` - both **FAIL**, but NOT from
  Linux: `no dock cell for Calculator/Chrome (none)`. New root cause - the emulator's PowOS home dock
  isn't provisioned with Calculator/Chrome pinned the way the phone's is. Invalidates the earlier "proven"
  claim for e2e-desktop's Android-only parts; `tools/emu/emu.sh`'s create/testwin step likely needs to pin
  them, or these parts need another way to open the apps on the emulator (drawer/search).
- `float-desktops.sh` and `panel-lift.sh` - re-fixed once (device_state retry / logcat time-mark) but
  **STILL FAIL** on re-test with the SAME messages ("the inner screen didn't come on" / "no home over the
  windows line from PanelLift"). The fix didn't hold - friction f81 reopened (x2). Root cause not
  confirmed: check the raw `dumpsys device_state` output format on the emulator, and whether the
  `logcat -t` mark's date format is actually accepted there.
- `window-max.sh calc --round emuf1` and `window-rec.sh --app calc --two --android-only --pages-only` -
  still pending as of this note.

Friction logged: f79-f82 (first pass, some later reopened), f130/f131 (duplicate CLAUDE.md/skill-listing
context overhead), f134 (no lane metadata existed), f138 (land.sh missing in a freshly-created worktree),
f81 reopened, f142 (new: dock cells missing on the emulator). Don't re-close the board task or call the
emulator lane "proven" for window-scroll/e2e-desktop/float-desktops/panel-lift until these are resolved;
resize-probe.sh is the one solid proof so far.
