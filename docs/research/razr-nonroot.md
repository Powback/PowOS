# PowOS on an unrooted phone: the razr fold (2026-11-08)

The Motorola razr fold (XT2651-1, `blanc`, SM8845, Android 16, bootloader locked, **not rooted**) is the non-root
PowOS test device. It's reached over wireless adb inside `powos-vadb` (LAN only, not on the VPN):

```sh
PHONE_SERIAL=192.168.50.203:33919 tools/phone/adb.sh shell ...      # the port changes on reboot/reconnect:
~/Library/Android/sdk/platform-tools/adb mdns services               #   find it, then
docker exec powos-vadb adb connect 192.168.50.203:<port>
PHONE_SERIAL=... tools/phone/shot.sh OUT.png --all                   # works without su now
PHONE_SERIAL=... tools/phone/cdp.sh pages                            # its own forward port, never the OnePlus's 9333
```

`tools/phone/adb.sh` takes the device from `PHONE_SERIAL` (default the OnePlus, `10.13.13.7:5555`); the WireGuard
staleness check runs only for a VPN serial, and each serial has its own state cache. `run-as com.powos.app` works
(debuggable APK): the app's files are readable without root.

## State on the device

- APK `2026.11.08-0214` (versionCode 29901734) = the shipped `android-app-dev/output/powos.apk`; the user installed
  it by hand at 17:46 (package installer). `persist.powos.root` empty, `ro.boot.flash.locked=1`, no `su`.
- Granted to PowOS (all reversible, PowOS's own): notification listener (`MediaListener`), overlay
  (`SYSTEM_ALERT_WINDOW`), `RECORD_AUDIO`, battery-optimisation exemption (`deviceidle whitelist`). POST_NOTIFICATIONS
  the user granted. PowOS is the default home (`cmd role add-role-holder android.app.role.HOME com.powos.app`; the
  previous holder was `com.motorola.launcher3` - set it back with the same command). Not granted: accessibility
  (`KeyInterceptor` is only the physical-keyboard Super key), usage access (the manifest doesn't ask for it).

## What runs

| surface | result | evidence |
|---|---|---|
| Web home (launcher), unfolded 2232x2484 | **works**: weather, sysinfo, search bar, pages; Linux tiles say "needs the PowOS Linux image - Download (996 MB)" | `razr-nonroot/03-shell-unfolded-inner.jpg` |
| Web home on the cover (`cmd device_state state 0`, 1080x2520) | **works**, compact layout | `razr-nonroot/04-shell-folded-cover.jpg` (landscape: the sensor rotation of the phone lying on its side, not PowOS) |
| First-run setup + image download | form works; slim base (995 MB) is the one downloaded; pin matches the published file (`8ab9ba5c...`) | `razr-nonroot/01-install-inner.jpg` |
| Crashes / ANRs | none (logcat 17:46-18:05) | - |

Not reached yet (they need the image, and the user was on the phone): shade / lock / keyboard / assist, terminals,
Linux apps + Steam from the launcher, App API loopback (`libpowosloopback`), app islands.

## Gaps (with evidence)

1. **Image download dies when the screen goes off / the app is backgrounded, with no resume.** Failed at 751 of
   995 MB: `Install failed: Software caused connection abort` (read over CDP from the install page). The error was on a
   hidden page: every Home / PowOS-icon press made another `InstallActivity` (4 install pages at once in
   `cdp.sh pages`), each a fresh form; Install on a second one would have started a second download over the first.
   User's words (11-08): "the launcher keeps restartong the install when resized or when backgrounded or locked".
   Owned by the install-survives agent (foreground service + resumable state) - not touched here.
2. **Home on a fresh unrooted install was the setup form, not the launcher** - FIXED here. `HomeDesktop` (engine
   alias) was enabled by default and `HomeShell` disabled; `HomeScreen.apply` (which picks the launcher in "auto") runs
   only from `SessionService`, which waits for the image. Log: `START u0 {act=MAIN cat=[HOME] cmp=com.powos.app/andro.marchy.HomeDesktop}`
   then `START u0 {cmp=com.powos.app/andro.marchy.InstallActivity} with LAUNCH_MULTIPLE` (17:56:09); `pm enable ...HomeShell`
   as shell is refused on a user build. `tools/emu/emu.sh` enabled HomeShell by hand for the same reason.
3. **Android app web windows tried a `su` display helper** - FIXED here (web windows are on only with root; apps open
   as ordinary Android tasks without it). `window-log.txt`: `display helper not started: java.io.IOException: Cannot run program "su": error=2`.
4. **Switcher has no task thumbnails without root** (`getTaskSnapshot()` needs `READ_FRAME_BUFFER`, signature-only),
   and every request logged two full stack traces - the log spam FIXED here (one line, then skipped); thumbnails stay
   a gap (MediaProjection or the app's own last-frame cache would be the non-root path).
   `Permission Denial: getTaskSnapshot() from pid=5193, uid=10504 requires android.permission.READ_FRAME_BUFFER`.
5. **Performance widget needs the Linux image** although its numbers can come from Android APIs (nonroot-parity row 8)
   - `03-shell-unfolded-inner.jpg` "performance - needs the PowOS Linux image".
6. **Linux tiles say "Download (996 MB)" while the download runs** - no link to the install's state. Same screenshot.
7. **Lock face blocked at screen-off**: `START u0 {cmp=com.powos.app/dev.omalauncher.shell.PowosLockActivity} ... (BAL_BLOCK) result code=102`
   (17:48:13) - a background activity start, refused without root/privileged start rights. Lock needs a foreground
   path (full-screen intent notification or the home task) on unrooted phones.
8. **Setup page is still Andromarchy-branded** ("ANDROMARCHY", "Omarchy (Arch Linux + Hyprland) on Android"):
   `01-install-inner.jpg`, `02-home-inner.jpg`.
9. **Image URL is LAN-only** (`http://android.pow/apk/...`): fine here, but a customer's phone can't download it -
   the sellable non-root build needs a public URL.
10. `ShellBridge.display()` threw on the application context (`system.display failed ... Tried to obtain display from
    a Context not associated with one`) when asked before the activity - FIXED here (default display).

## Fixes in agent/razr-nonroot

- `tools/phone/adb.sh`: `PHONE_SERIAL` (default the OnePlus); WireGuard check only for VPN serials; per-serial cache.
- `tools/phone/shot.sh`: `su` only where the phone has it.
- `tools/phone/cdp.sh`: a second phone forwards on its own port (9340-9389), never re-pointing the OnePlus's 9333.
- Manifests: `HomeShell` is the default home alias, `HomeDesktop` off until `HomeScreen.apply` picks it.
- `WebWindows.on`: requires `RootMode.enabled()`.
- `Tasks`: stops asking for snapshots after the first `READ_FRAME_BUFFER` refusal.
- `ShellBridge.display()`: default display when there's no activity.
