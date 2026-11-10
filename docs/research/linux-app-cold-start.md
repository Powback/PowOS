# Linux app cold start as its own task (11-10)

The user, 11-10: "what about idk opening dolphin from cold start". Opening a Linux app (Dolphin) from Android when its
process isn't running was too slow: switcher-launch 11-10 showed the bare PowosWindowActivity (the launch window) at
04:37:45 and Dolphin's own task at 04:38:04, about 19 s.

## The path

tap -> PowOS app (Runtime.openApp -> LaunchWindows placeholder task at once) -> `su -c` RootedGuest.rootCommand ->
`/data/powos/powos-run.sh` (nsenter, setpriv, `env -i`, `bash -lc`) -> `powos-open-task` (Python, PySide6, a KWin
script lists the windows) -> `bash -c exec dolphin` -> Dolphin's first window -> KWin exports it as a task (patch 0019,
"opened as a task") -> the show script -> the task's buffer live in KWin ("window task N live") -> PowosWindowActivity.

## Stages (phone clock)

| stage | before (11-10 04:37) | measured how | expected after |
|---|---|---|---|
| tap -> launch window (placeholder) | at once | logcat 04:37:45 | at once |
| `su` + powos-run.sh (nsenter, `bash -l`) | ~470 ms | `date +%s%N` around `su -c "sh powos-run.sh true"` (includes ~70 ms of `bash -l`, 41 ms of it flatpak.sh's `flatpak --installations`) | same |
| powos-open-task: Python + PySide6 QtCore/QtDBus import | ~290 ms | `python3 -c 'from PySide6...'` in the session | same |
| KWin report script -> Listed -> exec | not logged before | new `powos-open-task: timing` line (qt/listed/exec/window/shown ms) | <100 ms (to be measured) |
| Dolphin exec -> first window, warm KDE caches | ~1.2 s | window-bench p1 11-10 05:3x: open-live dolphin 1207 ms, kate 1246 ms, konsole 1310 ms (desktop web-window path, cold process) | same |
| **Dolphin: in-process ksycoca6 rebuild** | **most of the ~19 s** | `~/.cache/ksycoca6_en-CH_TkfJ5yMbB4tQBJbuicaJZZlzxhA=` written 04:38:04, the second Dolphin's window came | **0: kded6's cache, rebuilt in the background** |
| KWin export -> show -> live | not logged before | `linux-cold-open.sh` (task/live stamps) | to be measured |
| **tap -> first frame** | **~19 s** | | **~2 s (budget 2000 ms)** |

## Cause: two KDE service caches, one never kept fresh

KDE names its service cache (ksycoca) after the data dirs: `ksycoca6_<lang>_<base64 sha1 of XDG_DATA_HOME:XDG_DATA_DIRS>`.
Two environments start KDE programs on the phone:

- the session (kwin, plasmashell, kded6): `XDG_DATA_DIRS=/run/powos-app/share:<flatpak>:/usr/local/share:/usr/share`
  (powos-session.sh) -> `ksycoca6_en-CH_NL8X9dpcrGAynKwoM4zIOVT+6dM=`;
- every app the PowOS app opens (drawer, home, search, shortcuts), through powos-run.sh: `env -i` drops the variable
  and `bash -l`'s flatpak.sh sets `<flatpak>:/usr/local/share:/usr/share` -> `ksycoca6_en-CH_TkfJ5yMbB4tQBJbuicaJZZlzxhA=`.
  (Both hashes computed from those strings and matched to the files on the phone.)

kded6 watches its own cache's dirs and rebuilds it in the background (`/usr/share/applications` changed 04:16:58,
kded6's cache written 04:17:01). Nothing keeps the second cache fresh, so the first app opened from Android after any
change to an applications dir (a package update, a deploy, an app install: several a day) finds it stale and runs
kbuildsycoca in-process, before its first window: on 11-10 that was Dolphin at 04:37:45, the cache written at 04:38:04.
Old variants of the same kind sit in `~/.cache` (ten ksycoca6 files, mostly 10-22).

Ruled out: kded6, baloo, kactivitymanagerd, xdg-desktop-portal and the bus are all up from the session start (04:01);
no fixed sleep in powos-open-task's start path (its 500 ms polls are for the failure path and a KWin not yet up);
`bash -l` costs ~70 ms.

## Fixed

1. `targets/android/rooted/powos-run.sh` passes the session's `XDG_DATA_DIRS` (plasmashell's environment, with the
   other KDE session variables), so apps opened from the PowOS app use kded6's cache. flatpak.sh leaves the value as
   is (it only adds dirs not already in it). Generic: every Linux app, terminal and command started through powos-run.sh.
   powos-apps-export reads XDG_DATA_DIRS too; the added `/run/powos-app/share` holds only android-*.desktop, which it
   already skips. Ships with `rooted.sh deploy` (powos-deploy.sh installs it), no APK or KWin build.
2. `powos-open-task` prints one `powos-open-task: timing python=<ms> qt=.. listed=.. exec=.. window=.. shown=..` line
   (stderr, ms since its main(); python = interpreter start) when the task is shown; RootedGuest relays it to logcat.

## The check

`tools/phone/verify/linux-cold-open.sh` (+ `linux-cold-open-phone.sh`): each of dolphin, kate, konsole not already
running is opened the drawer's way (powos-run.sh -> powos-open-task), stamped on the phone: launch -> exec (from
/proc/<pid>/stat), -> KWin's task, -> first frame live on the host, -> the helper's "task". `bench.tsv` rows
`cold-exec|cold-task|cold-status|cold-live`, budget on cold-live 2000 ms, and a NOTE when the launch rebuilt a ksycoca6
cache. It skips the placeholder tap itself (it is shown at once, logcat) and so measures launch call -> first frame.

    tools/phone/verify/queue.sh add --close linux-apps-opened-as-their-own-task-e-g-dolphin tools/phone/verify/linux-cold-open.sh

## Still open

- 11-10 06:19 after deploy: kate cold-task 299 ms, cold-live 560 ms (PASS, budget 2000), open call "task" at 1554 ms - about 1 s after the first frame: the helper's show-script D-Bus round trip, the user already sees the window. cold-exec was wrong (wall clock vs boot clock), fixed. Dolphin and Konsole were skipped as already running; the check now closes its own leftovers (marker of pid+starttime) and measures them cold.
  0.3 s Python, ~1.2 s Dolphin). If over 2000 ms, the next cut is the Python helper's start (PySide6 import) on the
  launch path: start Dolphin before the KWin script lists the windows when the app has no process.
- The ten stale `ksycoca6_*` files in `~/.cache` are left alone (no cleanup without an OK).
