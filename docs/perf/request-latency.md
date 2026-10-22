# Request -> on-phone latency

The #1 metric (the user, 2026-10-23: "it takes wayyyyyy too long per request still"). Target: a small UI request on
the phone in **under 10 minutes**. Recompute: `tools/agents/latency.py --since 2026-10-22T18:00 --md` (`--json` for
the self-optimize loop).

## Stages

| stage | from -> to | source |
|---|---|---|
| lag | the manager's [high]/[urgent] mail -> the agent prompt that quotes it | ~/.cache/powos-coder-mail.log, subagent transcripts (first prompt or a queued SendMessage) |
| code | agent start -> its first commit that changes the phone (shell/ or the APK), as it landed on origin | git log origin (committer time) matched by subject to the agent's commands |
| ship | that commit -> on the phone | "pushed <file>" lines of push.sh runs (agents' own, the ship service's done logs), ship-apk installs (versionCode) |
| check | on the phone -> PASS of a board task the agent queued | ~/.cache/powos-verify-queue/runner.log + job files |

Open stages (no event yet) count to the time of the run and show as `>N`; medians below are over finished stages.

## Measured 2026-10-22 18:00 -> 2026-10-23 01:10 (65 requests, 49 matched to an agent)

| stage | median, whole evening | agents shipped themselves (18:00-00:28) | the ship service (00:28-01:10) |
|---|---|---|---|
| lag | 0.4 min | 0.6 | 0.4 |
| code | 9.3 min | 8.7 | 20 (big Linux-window and folder slices) |
| ship | 2.5 min | 2.5 (shell ~1.5, APK ~16) | **27-31 min shell**, 12+ min APK (open) |
| check | 73 min (n=2, 7 more open) | 73 | - |
| request -> on phone | 20.6 min | 19.5 | 32.6 |

Biggest stage before the phone: **code** over the evening (9.3 min); **ship** since the ship service started
(shell fixes 27-31 min). Why ship blew up: the service ran ONE ship at a time, and an APK ship takes the runner for
its whole life - 6 min for another ship's lock, the build, a 16 min pre-gate under load (~8 concurrent gates, load
17), then the idle wait. Every shell-only commit queued behind it (the AI page black-flash fix: committed 00:39,
not on the phone at 01:02; wide-home pages: 00:30, still waiting at 01:02).

## Changed (2026-10-23)

- `tools/phone/ship.sh`: the shell part of a tip ships 10 s after the last commit (`SHIP_QUIET_SHELL_S`, was 60),
  and ALSO while an APK ship is out: ship-apk now runs beside the loop in its own checkout
  (.claude/worktrees/ship-runner-apk). A request with Kotlin in it is done once the APK is installed; a shell-only
  commit's note goes out with its shell push.
- `tools/phone/ship-apk.sh`: holds `<ship lock>/phone` from its install to the end; the service's shell pushes take
  the same dir while they push, so a push never lands inside an install's reset + re-push.
- Test: tools/phone/ship-queue-test.sh (2b: a shell fix is pushed while an APK waits; the APK keeps its own note).
- Alongside (another agent, 83ae04b): 2 agent gate slots, the ship's gate never waits.

Expected after: ship for a shell change ~1.5-2.5 min whatever the APK is doing (10 s debounce + gate + push), the
APK path unchanged (~12-16 min plus the idle wait). Request -> on phone for a small UI fix: 0.4 + 9.3 + ~2 = **~12
min** median. The rest of the way under 10 min is the code stage (agent coding + its gate: incremental gates on the
changed pages, warm agents per area).

## Per request

| asked | ask | agent start | first phone commit | kind | on phone | lag | code | ship | check | to phone |
|---|---|---|---|---|---|---|---|---|---|---|
| 18:01 high | Chat expert, from the user: messages they send while the manager is bu | 18:01 | PowOS AI: messages sent mid-turn show at once - th | apk | 19:18 | 0.2 | 9.7 | 67.6 |  | 77.6 |
| 18:23 high | Widgets expert: merged widgets misaligned on the UNFOLDED home (user c | 18:23 | Wide home: a free column between the two side-by-s | shell | 18:28 | 0.3 | 4 | 1 |  | 5.2 |
| 18:25 high | Design expert: the user finds the control center "really confusing and | 18:25 | control center v3 behind a flag (state.ts ccV3, of | shell | 18:30 | 0.3 | 4.7 | 0 |  | 5 |
| 18:31 high | CC v3 APPROVED, much clearer. Before shipping: (a) "sound & focus" hol | 18:31 | control center v3 on by default (settings > style  | shell | 18:40 | 0.2 | 4.8 | 4.2 |  | 9.1 |
| 18:33 urgent | Perf expert, URGENT: the user says the phone is slow. Right now com.po | - | no agent matched |  | - |  |  |  |  |  |
| 18:34 high | Speed: the user says the agents are too slow to make progress. New rul | 18:35 | control center v3 on by default (settings > style  | shell | 18:40 | 1.6 | 0.3 | 4.2 |  | 6.1 |
| 18:42 high | Good fix. The 4 hung CDP containers on the Mac: those are the agents'  | - | no agent matched |  | - |  |  |  |  |  |
| 19:34 high | User decision: STOP all work on the separate desktop version (the powo | 19:34 | no phone commit |  | - | 0.3 | >336.8 |  |  |  |
| 19:38 urgent | The user is unhappy with time to delivery on ALL tasks. New delivery r | 19:39 | frost v2: no halos - the labels on the wallpaper ( | shell | 19:46 | 1 | 6.2 | 1.2 |  | 8.4 |
| 19:40 urgent | From the user directly: HURRY UP. Every expert ships its next slice no | - | no agent matched |  | - |  |  |  |  |  |
| 19:44 urgent | Widgets expert, REGRESSION from the partial-join fix (d83be90): the us | 19:44 | home's merged tiles touching over part of an edge  | shell | 19:55 | 0.4 | 9 | 1.5 |  | 11 |
| 19:45 high | From the user: we need a VERY STRICT cyclomatic complexity lint on all | 19:46 | Complexity lint, slice 1: TS/TSX in shell/ and app | shell | 21:13 | 0.3 | 8.5 | 79.4 | 72.5 | 88.1 |
| 19:52 high | Widgets expert, a Lights popup correction from the user: the long-pres | 19:53 | home's merged tiles touching over part of an edge  | shell | 19:55 | 0.8 | 0.9 | 1.5 |  | 3.2 |
| 19:53 high | Warm Gradle daemon builder: APPROVED (the user's standing "do whatever | 19:53 | app: no BuildConfig - AGP wrote each build's versi | apk | 21:13 | 0.4 | 65.1 | 15.4 | >237.8 | 80.9 |
| 20:05 urgent | Widgets expert (grid owner; loop in desktop for the wide mapping), URG | 20:12 | home after an app at another size (Broforce in lan | shell | 20:25 | 7.5 | 11.4 | 1.2 |  | 20.1 |
| 20:08 urgent | The user asks why the chat thumbnails (and the agent-mail cards) are s | - | no agent matched |  | - |  |  |  |  |  |
| 20:10 high | The user asks why APK builds take so long and whether we cache. Status | - | no agent matched |  | - |  |  |  |  |  |
| 20:23 urgent | Two things. (1) Native-blur + design experts: the notification/CC pane | - | no agent matched |  | - |  |  |  |  |  |
| 20:37 high | Design expert, the CC v3 fix clarified by the user: the icons must NOT | 20:37 | control center v3: one ordered list - the first pu | shell | 20:42 | 0.2 | 2.4 | 2.1 |  | 4.7 |
| 21:08 urgent | STOP: the kernel flash to boot_b was NOT approved. The user never answ | - | no agent matched |  | - |  |  |  |  |  |
| 21:36 urgent | BLOCKER: every APK ship is refused, because origin tip e9af512 (gate c | 21:36 | no phone commit |  | - | 0.4 | >214.8 |  |  |  |
| 22:17 high | The user says the phone is plugged into the Mac's USB now (task phone- | 23:02 | refreshApps split (list, icons) for the complexity | apk | 23:31 | 45.4 | 12.8 | 16.1 |  | 74.3 |
| 22:19 high | The user says the board is still too full. I closed 7 finished or dupl | - | no agent matched |  | - |  |  |  |  |  |
| 22:22 high | The control center "top row stays put, one ordered list, no categories | 22:22 | no phone commit |  | - | 0.4 | >169.2 |  |  |  |
| 22:23 high | One task (chat area, fresh agent): on the AI page, tasks whose phone c | 22:24 | AI page: test now / test all on queued phone check | shell | 22:47 | 0.8 | 21.1 | 2.5 | >143.8 | 24.4 |
| 22:23 urgent | The user says RUN THE TESTS NOW: they're handing over the phone. Start | 22:24 | AI page: test now / test all on queued phone check | shell | 22:47 | 0.6 | 21.1 | 2.5 | >143.8 | 24.1 |
| 22:26 high | Add to the test-now task (same chat agent): while the verify runner wo | 22:26 | AI page: test now / test all on queued phone check | shell | 22:47 | 0.7 | 18.6 | 2.5 | >143.8 | 21.8 |
| 22:28 high | Three items. (1) Design agent (with the CC top-row task): when the use | - | no agent matched |  | - |  |  |  |  |  |
| 22:37 high | Widgets agent: the fetch widget's logo is broken (/run/powos-app/powos | 22:41 | OWL canvas sized by its node, not its bitmap; fail | shell | 22:53 | 3.7 | 11.4 | 1.2 | 73.1 | 16.4 |
| 22:37 high | The user marked "leave the phone untouched 10 min" as done, so the Bro | - | no agent matched |  | - |  |  |  |  |  |
| 22:56 high | The user tapped "test now" and it says it needs the newer app, so the  | 22:56 | AI page: test now / test all only once the host ha | shell | 22:58 | 0.2 | 1.4 | 1.2 |  | 2.7 |
| 22:56 high | Second time tonight a broken tip blocked every APK. Extend the pre-pus | - | no agent matched |  | - |  |  |  |  |  |
| 22:59 high | Fresh agent on the Sketch app (local.sketch): after rotating, the user | 22:59 | no phone commit |  | - | 0.3 | >131.8 |  |  |  |
| 23:05 high | Chat agent, from the user: the full PowOS AI app (the "open ↗" screen, | 23:06 | AI panels render the AI page's own view: two panes | shell | 23:20 | 1.1 | 11.5 | 2.1 |  | 14.8 |
| 23:07 high | The user says many board items say "working" but are idle. Fix it at t | 23:08 | Board: 'working' only while a live agent holds the | shell | 23:13 | 0.8 | 4.5 | 0.6 |  | 6 |
| 23:10 urgent | REGRESSION on the AI page (/run/powos-app/powos-ai-shared/screen-17927 | 23:14 | ship-apk: gate newer shell before install; push.sh | shell | 23:31 | 4.4 | 6.3 | 10.4 |  | 21.1 |
| 23:17 high | The user says the games freeze/resume test (bf-resume.sh, Steam + Brof | 23:19 | no phone commit |  | - | 2.5 | >112.1 |  |  |  |
| 23:18 high | Correction from the user on the games freeze/resume test: it DID start | 23:19 | no phone commit |  | - | 1.3 | >112.1 |  |  |  |
| 23:20 high | Games agent: the user says Broforce and other games take AGES to launc | 23:20 | no phone commit |  | - | 0.4 | >111 |  |  |  |
| 23:21 high | Two items. (1) AI page: the user has seen progress-above-titles and wa | - | no agent matched |  | - |  |  |  |  |  |
| 23:21 urgent | Games agent, URGENT: the user says "this is stuck" (/run/powos-app/pow | - | no agent matched |  | - |  |  |  |  |  |
| 23:22 urgent | Correction: the user means the TESTING status pill/dialog is stuck, no | 23:22 | verify: pill heartbeat, 30 s stale hide, per-check | apk | 23:31 | 0.7 | 6.7 | 1.9 | >100.1 | 9.3 |
| 23:32 high | Widgets agent: in edit mode on the UNFOLDED home, the search bar and t | 23:33 | Wide home: AI panel window to the foot; device che | shell | 23:51 | 0.2 | 13.7 | 4.9 |  | 18.8 |
| 23:33 high | Widgets agent, two edit-mode items from the user: (1) Confirmed: in ed | 23:52 | Home edit mode: marquee picks tiles, picked tiles  | shell | 00:03 | 19.2 | 8.8 | 1.8 |  | 29.8 |
| 23:41 urgent | The user asks how to resume the phone checks: they're paused, since yo | 23:42 | verify runner: launchd agent, one-runner lock, pau | apk | 00:22 | 0.7 | 23.7 | 16.8 | >48.9 | 41.1 |
| 00:01 high | Don't keep the whole verify runner off because of Broforce: that block | - | no agent matched |  | - |  |  |  |  |  |
| 00:20 urgent | P0, NOBODY IS ON IT: "Search bar widget in edit mode (P0, 3rd report)" | 00:20 | Search widget drives the pull-up launcher; drop it | shell | 01:00 | 0.4 | 12.7 | 26.6 |  | 39.7 |
| 00:24 high | Switcher agent: the user is testing "floating windows live on home pag | 00:25 | Wide home: desktops get pages again, an empty one  | shell | 01:09 | 0.7 | 5.1 | 39.7 |  | 45.5 |
| 00:27 high | Widgets agent (folders/app library). The user: "the worst folder inter | 00:28 | Folders open as a morph from their tile, over a pa | shell | 01:00 | 0.3 | 7.5 | 24.3 |  | 32.1 |
| 00:28 urgent | Search P0 agent: the user tried again and STILL can't move the search  | 00:28 | Search widget drives the pull-up launcher; drop it | shell | 01:00 | 0.2 | 4.8 | 26.6 |  | 31.7 |
| 00:30 high | Switcher agent: Linux apps opened from the launcher (e.g. Dolphin) ope | 00:30 | Linux windows resize live; new windows and dialogs | apk | - | 0.2 | 28.5 | >13 |  |  |
| 00:30 high | Switcher agent: Dolphin now floats on home (good), but the user says i | 00:31 | Linux windows resize live; new windows and dialogs | apk | - | 0.4 | 27.6 | >13 |  |  |
| 00:31 high | Switcher agent, narrowing it down from the user: the main issue is tha | 00:32 | Linux windows resize live; new windows and dialogs | apk | - | 1.4 | 26 | >13 |  |  |
| 00:31 high | Switcher agent, more on the resize: the user says resizing itself feel | 00:32 | Linux windows resize live; new windows and dialogs | apk | - | 0.9 | 26 | >13 |  |  |
| 00:36 high | Fresh chat agent: right after sending a message on the home AI page, t | 00:36 | AI page: no black flash on send - assist's recents | shell | 01:09 | 0.2 | 2.5 | 30.8 | >1.8 | 33.5 |
| 00:37 high | Design agent (shade over-pull), user report with /run/powos-app/powos- | 00:37 | Shade panel edge follows the finger; blur region t | apk | - | 0.3 | 22.1 | >12.1 |  |  |
| 00:39 high | Switcher agent, a Linux windows gap from the user: opening an image fr | 00:40 | Linux windows resize live; new windows and dialogs | apk | - | 0.2 | 18.6 | >13 |  |  |
| 00:40 high | Switcher agent, confirming the diagnosis: in Plasma the user sees 6 Gw | 00:40 | Linux windows resize live; new windows and dialogs | apk | - | 0.2 | 18.1 | >13 |  |  |
| 00:46 urgent | The user says: "ok phone is yours, do whatever". The phone is free NOW | - | no agent matched |  | - |  |  |  |  |  |
| 00:49 high | Switcher agent: the user reports native Linux apps STILL open full scr | 00:50 | Linux windows resize live; new windows and dialogs | apk | - | 1 | 8.2 | >13 |  |  |
| 00:53 high | The user hit the exact search P0 bug again: once search is moved, the  | - | no agent matched |  | - |  |  |  |  |  |
| 00:56 urgent | From the user, verbatim: "it takes wayyyyyy too long per request still | 00:57 | no phone commit |  | - | 0.4 | >14.3 |  |  |  |
| 01:00 urgent | HOME IS BROKEN after APK 29878476 installed: "ui/desktops.ts:15: 'stat | 01:03 | no phone commit |  | - | 3.3 | >8.2 |  |  |  |
| 01:00 urgent | NOT fixed: with overrides = NONE, home, assist and petover all still f | 01:03 | no phone commit |  | - | 2.9 | >8.2 |  |  |  |
| 01:03 urgent | Time box: if home isn't fully back (widgets rendering + search pill) w | 01:04 | no phone commit |  | - | 0.2 | >7.7 |  |  |  |
