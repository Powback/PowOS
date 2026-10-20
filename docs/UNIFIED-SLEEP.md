# Unified sleep

Things nobody is using stop costing CPU and battery, and they wake in milliseconds when somebody uses them again.
One config surface and one status command cover every kind of workload. Containers are covered by
`lib/apps/powos-autosleep` (PHONE-KERNEL-CONTAINERS §13). This page covers everything else.

| kind | who sleeps it | asleep when | wakes on | how |
|---|---|---|---|---|
| app backend (native, sandbox) | `powos-sleepd` (root, system tier) | idle for the manifest's `autosleep.idle` (default 5m): no TCP connection to its listen ports and under 1% CPU (the supervisor's measure) | a connection to its port, `powos sleep wake <id>` | cgroup v2 freezer (pause), plus MADV_PAGEOUT (hibernate), or the supervisor stopping it (stop) |
| GUI app in Plasma | `powos-sleep-gui` (session), frozen by `powos-sleepd` | no window focused for 10 min (`POWOS_SLEEP_GUI_IDLE`) | focus, raise or un-minimize (KWin), any D-Bus message addressed to it, `powos sleep wake` | cgroup v2 freezer |
| Steam (a GUI app with a unit) | the same | out of sight 15 s (unit `steam`: no game, no disk I/O, started over 2 min ago) | its launch paths (`/usr/bin/steam`, `powos-open-task`) before showing it, focus, PowOS back on screen | cgroup v2 freezer, the client's whole tree |
| container | `powos-autosleep` | see §13 there | a connection, `powos containers wake` | freezer or stop |
| SpacetimeDB database | not slept one by one (see below) | - | - | the supervisor's whole-server idle restart |
| shell island (app widget) | the shell (`shell/apps/onscreen.ts`) | off screen | on screen | its own pause; reported to status |

## Config: `lib/apps/powos-sleep-common`

This file is shared with powos-autosleep. It is loaded as a module.

- Manifest key: `"autosleep": {"idle": "5m", "mode": "pause" | "hibernate" | "stop"}`, or `"never"`.
- The never list has three parts:
  - **Words**, matched in names and app ids: `spacetimedb`, `comms`, `agentsd`.
  - **CORE**, exact process names: the session core (KWin, plasmashell, Xwayland, ksmserver, kded, the D-Bus daemons, PipeWire and WirePlumber, portals), the PowOS shell host and supervisor, the sleepers themselves, sshd, tmux and su.
  - **The user's own list**: `powos sleep never <thing>`, stored in `/var/lib/powos/sleep/never.json`.
- The status board: each sleeper publishes `/run/powos-sleep/<provider>.json` with its items and how to wake them (a socket or a command). `powos sleep status|wake|never` reads every provider.

## How each kind works

**App backends.** Each frozen thing gets its own group, `/sys/fs/cgroup/powos/sleep/<key>`. Only processes in the root v2 cgroup are moved there, never anything in Android's `uid_*/pid_*` groups. On thaw they are moved back, so nothing is left behind. The phone's kernel is 5.15, so it has `cgroup.freeze`. SIGKILL still kills a frozen process, so the supervisor's stop never hangs.

Socket activation works without changing the app. powos-sleepd borrows the frozen backend's listening socket (`pidfd_getfd`) and epolls it. A connection queues in the kernel and makes the socket readable. The freezer is then thawed and the app accepts the connection as if nothing had happened.

- **Stop mode**: the supervisor stops the backend (`/run/powos-sleep/stopped/<id>`, then SIGUSR1). powos-sleepd holds the port in the meantime and proxies the connections that arrived while it was starting. See the HACK registry entry.
- **Shell pages**: a page or widget that opens an app connects to it, which is a connection like any other. No bridge hook is needed.

**GUI apps.** A KWin script (`lib/apps/sleep/kwin`) sends each app window's `activeChanged` and `minimizedChanged` events to `powos-sleep-gui` over D-Bus. Nothing polls.

When an app's idle time is up, the watcher checks it:
- PipeWire streams (`pactl` sink-inputs and source-outputs).
- A terminal's foreground job (a non-shell in the terminal's session, or a job in the foreground group).
- 5 s of CPU and I/O: over 20% CPU or 256 KB/s means busy.
- powos-android-tasks' stand-ins (`android-*`), which are skipped.

powos-sleepd then re-checks the never list against the whole process tree and against Android's cgroups, and refuses to freeze the focused app.

While an app is frozen, a D-Bus monitor watches only its bus names (`BecomeMonitor` with `destination=` rules). That catches method calls, the tray's Activate, and a notification's targeted ActionInvoked signal. An app woken by D-Bus but still unfocused sleeps again after 60 s. If the watcher's connection drops, powos-sleepd thaws every GUI app. If powos-sleepd stops or restarts, it thaws everything it froze.

On the phone, focus also needs PowOS on screen. The PowOS app's display daemon pairs one consumer per visible surface (the desktop is surface 0, each window task its own) and logs every connect and disconnect; powos-sleep-gui watches that log with inotify. With no consumer connected (Android's home, another app, Recents, the screen off) no window counts as focused, and the focused app comes back the moment a surface does. Reading the log is a workaround (the HACK registry row for `powos-sleep-gui`); the real fix is the daemon publishing its connected surfaces.

**Apps with a unit: Steam's instant resume.** A unit manifest with `"windowClass"` gives that app's windows its own rule (`powos-sleep-gui`'s docstring has the keys). `units/phone/steam.json`:

| key | Steam's | what it does |
|---|---|---|
| `autosleep.idle` | `15s` | out of sight for 15 s (unfocused, minimized, closed to the tray, PowOS off screen), then 5 s sampled, then frozen |
| `processes[].pidfile` | `~/.steam/steam.pid` | the app is the client's whole tree: its windows belong to `steamwebhelper`, but the freeze takes `steam` and every helper at once, and it stays tracked with no window (tray) |
| `sleepBusy.cmdline` | `SteamLaunch` | a game running (Steam's `reaper SteamLaunch AppId=...`) keeps Steam awake; the game's own windows are never frozen (games are a later phase) |
| `sleepBusy.io` | `disk` | busy = disk reads+writes over 256 KB/s (downloads, updates, installs); not `rchar/wchar`, which counts CEF's IPC |
| `sleepBusy.cpu` | `false` | its idle CPU (~20% of a core, the webhelper) is what freezing saves, so it doesn't keep it awake |
| `sleepBusy.startGrace` | `2m` | never frozen in its first 2 min: updating, logging in, and handing over the game it was started for |

Thawing comes before showing, on every way in:
- `/usr/bin/steam` (the games widget, the launcher's Exec, `steam steam://...`): a Steam whose `/proc/<pid>/cgroup` says `powos/sleep` is woken first with `dbus-send ... dev.powos.Sleep.Gui.Wake string:steam` (`powos sleep wake <pid>` as the fallback), then the launch goes to the running Steam instead of waiting on a frozen one.
- `powos-open-task` (an app tapped in the PowOS app's launcher): the existing window's process is woken before KWin exports it as a task.
- Focus (the taskbar, a task brought back from Recents, PowOS coming back on screen) thaws it as for any GUI app.
- `powos sleep wake steam` thaws through powos-sleepd, which names the app to the watcher in its next reply (`"woken"`), so the watcher counts it as awake and lets it sleep again when idle.

**SpacetimeDB.** Unloading single databases is not possible in 2.12, so it is skipped:
- Databases load lazily (`get_or_launch_module_host`).
- The only unload path, `HostController::exit_module_host`, is internal. Standalone calls it only when a replica is deleted, and no HTTP route reaches it.

So per-database unloading would need a server patch: an idle reaper using the per-database `spacetime_worker_connected_clients` gauge. It would also have to keep databases that have scheduled reducers. With the three idle patches already in `targets/android/pkgs/spacetimedb`, a loaded idle database costs about 0 CPU and wakeups, so the gain would be memory only.

What exists today:
- The supervisor restarts the whole server when nobody has been connected for 5 min and RSS is over 60 MB (about 150 ms).
- `powos sleep status` lists each loaded database and its clients from `/v1/metrics`.

**Shell islands.** `shell/apps/sleepreport.ts` writes the islands' on-screen state to the shell's store (`shell-data/sleep.json`). It is debounced and written only when something changes. powos-sleepd reads that file for status.

## Limits and footprint

There are no new packages. Everything uses what the rootfs already has: python-dbus, gi, pactl, and KWin's scripting.

| unit | runs as | started by | limits (memcg / cpu quota / pids) | idle cost (measured) |
|---|---|---|---|---|
| powos-sleepd | root, system tier mount ns | `rooted/powos-start.sh` | 48 MB / 50% / 16 | 0 ms CPU per 30 s; a 10 s tick reading the supervisor's status file only while a sleepable service is awake |
| powos-sleep-gui (+ the KWin script) | powos, the session | `powos-rooted-session` | 64 MB / 50% / 16 (put there by powos-sleepd) | 0 ms CPU per 30 s, no timers while no window is waiting |

The limit groups are `/dev/memcg/powos/<unit>`, `/dev/cpuctl/powos/<unit>` and `/sys/fs/cgroup/powos/<unit>`, the same layout powos-container uses. The CPU cap is a ceiling for a runaway, not a budget. At 10%, a 50 ms `/proc` scan took 700 ms. The unit manifests are in `/etc/powos/units.d/powos-sleepd.json` and `/etc/powos/units.d/powos-sleep-gui.json`, and both say how to remove the unit.

## Measured on the OnePlus Open (2026-10-20)

| kind | freeze | thaw | the first use after sleeping |
|---|---|---|---|
| app backend, pause | 105-185 ms (one `/proc` scan) | 0.5-0.6 ms | an HTTP request: 5.5-8.8 ms, against 2-6 ms awake |
| app backend, hibernate | +MADV_PAGEOUT: RSS 23 → 12 MB (11 MB to zram) | 0.5 ms | 36 ms (page faults back) |
| app backend, stop | the supervisor's stop | start + proxy | 187 ms (python http.server cold start) |
| GUI app (kwrite, foot) | 104-200 ms | 1.0 ms; 3.1-3.2 ms with the watcher's request (focus or D-Bus) | a D-Bus call to frozen kwrite: 46 ms including qdbus's own startup |

Idle savings, measured over 30 s awake and then 30 s asleep:
- The test backend (python http.server, which polls twice a second) went from 1 wakeup/s and 10 ms CPU to 0 and 0.
- kwrite and foot were already at 0 wakeups and 0 ms idle, so freezing them saves nothing. That is the honest result for well-behaved apps.
- The gain is in apps that poll while hidden, such as browsers, Electron apps and Steam's webhelper under FEX.
- On this phone, the session's real idle costs were plasmashell (3.6% of a core, screen off, but it is session core), a terminal's fzf (a foreground job, so exempt), and powos-android-tasks' 2 s adb poll (never list). Those belong to their own fixes, not to sleep.
