# Coordinator mail triage, 2026-11-26

The phone agents' mail to the coordinator (`~/.cache/powos-coordinator-inbox.jsonl`, 47 messages from 11-04 to 11-26,
from `manager` and `shell`) reached the Mac for the first time on 11-26 through coordinator-relay (34503e27). Nobody
had read it. The 4 newest (11-25 17:42 onward: 81f6e43b921c, b07fd8203dce, 446a9de5f75e, 261871a4f79b) were already
handled and are left out. The other 43 are below. Verdicts were checked against main at 90bf141c and the board
(`powos agents task list --all`). Board tasks older than ~11-14 are no longer listed, so their verdicts rest on commits.

Counts (29 manager messages): resolved 21, still open 7 (4 items, 1 new board task; abdf8dfbf64f partly), obsolete 1. Perf recordings: 14 (11 addressed, 3 point at the
new task).

## fps-meter perf recordings (`shell`)

All are "main shell (home)" recordings. The perf work since then: 2d40ba55 (11-06) and 56d61b9d (11-08) removed the
forced layouts from home swipes. f426c138, f248cd53, f23d088c and 7a235951 (11-23) handle overlay measureText, needless
renders (Pill/PillSend/Fragment; `hears~` was a new array every render, not an idle voice subscription), overlay
paints and the re-raster on each finger move. Idle home is now about 0.8 paints/s on the device.

| id | date | p50/p5/min fps, jank | top self-time | verdict |
|---|---|---|---|---|
| de6f30d6fb5e | 11-04 | 120/119/60, 0 | none | clean baseline |
| 58dd02f0e2d5 | 11-06 | 60/30/10, 13 | ontouchend forced reflow, Icon 69 needless | addressed: 2d40ba55, f248cd53 |
| 6c26dcea5abb | 11-06 | 60/24/7, 53 | ontouchend forced reflow, renderoverlay draw | addressed: 2d40ba55, 56d61b9d, f23d088c |
| 51929a2257a1 | 11-07 | 119/20/9, 29 | homeDotsAt 200 ms, checkVisibility, scrolls | addressed: 56d61b9d |
| 460901d0d77b | 11-07 | 60/20/6, 189 | homeDotsAt 1460 ms, overlay draw 620 ms | addressed: 56d61b9d, f23d088c |
| 5e8200972149 | 11-08 | 0.6 s clip, one 406 ms frame | overlay draw, homeDotsAt, measureSurfaces | addressed: 56d61b9d |
| 89cee79096d5 | 11-08 | 120/60/2.5, 56 | scrolls 1900 ms, overlay draw 1120 ms, measureSurfaces 640 ms | addressed: 56d61b9d, f23d088c |
| 7192b9ae69ad | 11-08 | 120/20/2.5, 162 | scrolls 1200 ms, overlay draw 760 ms, homeDotsAt 710 ms | addressed: 56d61b9d (made from this trace) |
| 1415de91d44f | 11-09 | 60/60/2.4, 5 (2 min idle) | rAF 630 ms, Node 127 needless | addressed: f23d088c (idle 0 commits) |
| 4229d5feaec4 | 11-10 | 60/60/20, 9 (2 min idle) | rAF 760 ms, elementFromPoint 240 ms | addressed: f23d088c |
| 828b44d51ca2 | 11-10 | 60/60/2.2, 6 (2 min idle) | 4 not-JS LoAFs of about 400 ms at 53-55 s | likely addressed: f23d088c (not JS, no named culprit) |
| 3f3d4c9ee5a1 | 11-23 | 60/24/1.4, 135 | measureText 1720 ms, gBCR 940 ms, measureSurfaces 430 ms, Pill hears~93 | mostly addressed (f426c138, f248cd53); glass measure is in the open task below |
| 0302ff1b0ce1 | 11-23 23:03 | 120/61/4, 10 | measureSurfaces 660 ms, checkVisibility 360 ms, gBCR 350 ms, 238 ms LoAF | **unaddressed**: home-perf-glass-measure-still-tops-the-swipe-tra |
| 9771acdfae62 | 11-23 23:31 | 120/119/10, 3 | gBCR 990 ms, checkVisibility 830 ms, measureSurfaces 810 ms | **unaddressed (cost, little jank)**: same task |

nativeglass.ts has not changed since 62e6207d (11-10). 56d61b9d only kept the glass measure out of the drag itself.

## Manager reports, nudges and escalations

| id | date | gist | verdict | evidence |
|---|---|---|---|---|
| 55f0dcad68da | 11-04 | Broforce flicker = `tu_override_uncached_as_cache_coherent`; pad slide-between-buttons | resolved | 590eb52d, 26184115 (override comes from FEX and has no effect, so it is not the cause); board broforce-flicker stale, user 11-14 "flicker fixed"; pad: b6980d5b, 73df319d |
| faac64c97b4f | 11-04 | search-bar push briefly stalled window geometry; wants an AI-page bar screenshot | obsolete | watchdog recovered it; search bar reworked in 6906cb48 (11-23) |
| b960fa79d0cc | 11-04 | rotate after a reduced-width game wedges the layout | resolved | bff6e53b (kwin 0069), f78ff490 (0074), fca413b9 (0076): a game keeps full screen through rotate/fold |
| cde4cc929036 | 11-06 | forced reflow in touchend; idle voice subscription | resolved | 2d40ba55, 56d61b9d; `hears` was an unstable array, fixed in f248cd53 |
| d285612e2aaf | 11-06 | escalation: home-swipe stutter, status board re-render per touchend | resolved | 2d40ba55, f248cd53; board home-perf-renderoverlay-drawflash-measuretext-wi done (device check passed) |
| a993b4703123 | 11-07 | terminal not PowTerm-grade (1st rejection) | still open (user-parked) | board native-terminals-rebuilt-on-powterm-s-code-fit-w, backlog: parked by the user 11-14, backlog 11-25 |
| 935443bca376 | 11-07 | Linux dropdown/override-redirect popups invisible | resolved | 5bfdbb42 (kwin 0062), 2869693b ww-popups check |
| d6e57b14b00a | 11-07 | named home-swipe culprits (homeDotsAt, nativeglass, scrolls, pick, overlay draw) | resolved, except glass | 56d61b9d; glass measure is back on top in 11-23 traces, so it is in the new task home-perf-glass-measure-still-tops-the-swipe-tra |
| 182d137e75a7 | 11-08 | desktop E2E round 249: close/minimise broken | resolved | 352bf07a (RZ7 resize zone ate the bar and close); desktop back to 43/43 at rounds 253/254/259 (per msg 33a72517bd69) |
| 0c828505c6b6 | 11-08 | report: no KWin prompts to deny; adb Mac-key heal (please land it); Steam save dialog blocked | resolved / obsolete | heal landed in b9c708b4; the prompts and Steam dialog had already expired |
| 9f42bd02250b | 11-08 | terminal 2nd rejection: no scrollback/touch-scroll | still open (user-parked) | same task as a993b4703123 |
| 11679960b979 | 11-08 | USB-debugging dialog storm; verify-runner must back off | resolved | b9c708b4 (back off on unauthorized), 1ebae955 test |
| c0faff895c84 | 11-08 | Dolphin opens no window (exists in KWin, no ww-linux layer) | resolved | 518d4dd6 (launch moves a Linux task into a web window), ccf90055 |
| 32750cf9e097 | 11-08 | Linux window trapped inside Plasma | resolved | ccf90055 "Linux launches never route into the Plasma desktop" |
| bd4eb36bd415 | 11-08 | terminal 3rd rejection: user says port PowTerm source | still open (user-parked) | same task; the user parked it 11-14, after this message |
| 76a7c83a0775 | 11-08 | borderless game has no title bar | resolved | 64b955b1 kwin 0068 (every game window keeps PowOS's bar) |
| 11f93343fff7 | 11-08 | Steam game grouped under Steam's window, not its own | resolved | fca413b9 (a game's own full-screen task), webwindows `l:steam_app_<appid>` key, e0d99950 game-own-pipes check |
| 731371d39bc1 | 11-08 | urgent: home-swipe task reopened, 2d40ba55 missed the hot lines | resolved | 56d61b9d (from the 18:27 trace); later f248cd53/f23d088c/7a235951; board perf task done on device |
| 741d27244bc2 | 11-08 | urgent: every Linux app opens in Plasma | resolved | ccf90055 (all launch paths) |
| b149af34ca20 | 11-09 | terminal 4th rejection: double scroll layer | still open (user-parked) | same task |
| eb2bbe5d473b | 11-09 | no-root razr: Plasma stuck, display consumer late/drops | still open (fix not checked) | board debug-no-root-phone-plasma-stuck-loading-galaxy (stale): fix 67dfaf0a9+eef4679ab, check nonroot-desktop.sh 0cb8eabf, no pass recorded |
| 7df4c4226f15 | 11-10 | E2E app-pair entity 4 fails | resolved | 33edee2e (22:02 11-09, after the failing round 1109-2146), db66fa03 |
| abdf8dfbf64f | 11-10 | window-bench 13/32: slow open, never live, rotate 7-9x over | resolved in part, rest open | 4cd89682 cold-open, 8186a4fe display pool, 44804a4f never-live, bff6e53b rotate; the rest is under the native-windows umbrella task (waiting) |
| 5af0aa46b7a9 | 11-11 | E2E: camera ring missing for com.oplus.camera | resolved | a5ee59b1 (CameraManager lights the ring, tap opens CC); camera-ring-hugs-the-hole done |
| 33a72517bd69 | 11-14 | E2E desktop: no dock cell for Calculator | resolved | 2f175fab (unpinned Calculator setup) |
| 655c19cb5b0a | 11-23 | keyboard resizes the window, not its content | still open | board keyboard-resizes-the-window-but-not-the-content (queued, restaffed 11-26) |
| 7de7fdbf992a | 11-23 | right side-dock; send to stop; keyboard; which branch? | resolved except keyboard | side-dock-on-the-right-... done; 75dbc8b0 send/stop; keyboard is the task above; branch question obsolete (main only) |
| d019c6c5e70d | 11-23 | nested-scroll ownership (3 reports) | resolved | 7e77c96e, 3662fc40; the three board tasks are done |
| caaa6c7efcbc | 11-23 | urgent: page-switch perf never fixed; asks for branch + bar.tsx lock | resolved | f426c138, f248cd53, f23d088c, 7a235951; board home-perf-renderoverlay-drawflash-measuretext-wi done |

### Still open

- Terminal at PowTerm parity: a993b4703123, 9f42bd02250b, bd4eb36bd415, b149af34ca20. Existing task
  native-terminals-rebuilt-on-powterm-s-code-fit-w, parked by the user (11-14, 11-25). No new task.
- No-root razr Plasma stuck: eb2bbe5d473b. Existing task debug-no-root-phone-plasma-stuck-loading-galaxy is stale; it
  needs nonroot-desktop.sh run on the razr.
- Keyboard: window content does not reflow: 655c19cb5b0a, 7de7fdbf992a. Existing task
  keyboard-resizes-the-window-but-not-the-content.
- Home glass measure: 0302ff1b0ce1, 9771acdfae62, 3f3d4c9ee5a1, d6e57b14b00a. **New** task
  home-perf-glass-measure-still-tops-the-swipe-tra.
- Window-bench budgets (abdf8dfbf64f) fall under the native-windows umbrella task.
