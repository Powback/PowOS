# Stock phone parity + Apple-level QoL: what PowOS is missing (2026-11-25)

The user (11-25), after noticing the lock face has no media controls: "we are missing basic features such as a media
control on the lockscreen if media is playing, what else?", then "think apple level quality of life". This is an audit
only: what stock OxygenOS 15/16 (OnePlus Open, rooted) and One UI (Galaxy S25, non-root) / razr (non-root) offer in
every surface PowOS replaces, and whether PowOS has it. The bar for part B is not "Android has it" but "it feels
effortless".

Read from the code on `main` at 1c2333ff (shell/ui, `targets/android/app/app/src/main/kotlin/dev/omalauncher`, docs) and
the board. No device was checked; "done" means the code path exists, not that it was verified on all three phones.

Status: **done**, **partial**, **missing**, **stock** (not replaced: SystemUI/the OEM still provides it, nothing to do
unless PowOS takes the surface over), **wip** (on the board now).
Impact: daily-use impact for this user (H/M/L). Root: **any** = doable without root; **root** = needs root (or a
signature/privileged permission) for the full version; **nr-gap** = works rooted, broken without root today.

## A. Stock parity

### Lock screen (PowosLockActivity / `LockFace.kt` + `shell/ui/lock.tsx`; Android's keyguard stays underneath)

| feature | status | evidence | impact | root |
|---|---|---|---|---|
| Media controls / now playing | wip | board `lock-screen-media-controls-when-something-is-pla`; lock.tsx has no media | H | any |
| Camera shortcut (swipe/tap to camera) | missing | lock.tsx: time, date, battery, notes, charge only. Double-press power still works (stock) | H | any (`INTENT_ACTION_STILL_IMAGE_CAMERA_SECURE`) |
| Torch shortcut | missing | same; torch exists only in the control center (QuickSettings.kt `flashlight`) | H | any (CameraManager.setTorchMode) |
| Fingerprint / face unlock straight from the face | partial (unverified) | NATIVE-SYSTEM-UI.md "To verify: whether side-fingerprint unlock fires while a show-when-locked app occludes the keyguard". S25/razr have under-display sensors with no on-face target | H | any |
| Notifications (expand, groups) | done | a5c784e0 | - | any |
| Charging status / time to full | done (device check open) | lock.tsx `chargeLine`; board `lock-charging-info` (check SKIPPED: not plugged) | - | any |
| Next alarm on the face | missing | lock.tsx: no alarm; status bar has the alarm icon (083f2fb9) | M | any (AlarmManager.getNextAlarmClock) |
| Weather + next calendar event glance | missing | weather widget on home only (AppWidgets.kt, `d054d110`); nothing on the face | M | any |
| Emergency call | partial | no button on the face; the keyguard's PIN pad (after the swipe) has it | M | any |
| Owner info / lock message | missing | no reference | L | any |
| Ongoing call / incoming call over the face | stock (unverified) | the dialer's show-when-locked activity starts over the face; no PowOS call pill/return-to-call on the face | M | any |
| Alarm/timer ringing over the face | stock (unverified) | Clock's full-screen activity starts over the face | M | any |
| Smart Lock / trust agents | stock | `requestDismissKeyguard` honours a trusted state; the face still asks for the swipe | L | any |
| Lockdown | stock | power menu is SystemUI's | L | any |
| NFC payment while locked | stock | HCE is independent of the face | L | any |
| AOD / ambient display | partial (now playing + fingerprint spot done 11-27, device check queued) | `aod.tsx` + PowosDozeService: time, date, battery, notification icons, a dim now-playing line (title · artist while playing; previous/play/next where the window takes touches - StandBy upright; ShellMedia.whileOff tells track/play changes with the screen off, never the position), an in-display sensor's spot at the sensor (lock.sensor, outline, not drifting; none on a side sensor). Gate AOD1, tools/phone/verify/aod.sh. Left: tap/lift-to-wake choices | M | any |
| Face shows without root | done | LockFace.kt full-screen-intent fallback (razr 11-08) | - | any |

### Notification shade + control center (`shell/ui/shade.tsx`, `notifications.tsx`, `control.tsx`, `QuickSettings.kt`)

| feature | status | evidence | impact | root |
|---|---|---|---|---|
| Tile toggles (Wi-Fi, BT, data, airplane, location, dark mode, NFC, battery saver), screenshot, lock tile | done (11-25, `control-center-toggles-work-without-root`; device check pending) | shell/TilePaths.kt picks per tile: root su (rooted), else the app's own call (Wi-Fi/BT legacy APIs, dark mode, DND, rotation), accessibility global actions (screenshot, lock), lock admin, else Android's panel/page; missing grant = toast + the grant page. Optimistic flip, rolled back after 5 s if the state didn't follow | - | any |
| Brightness + volume sliders, ringer | done | QuickSettings.kt `brightness`, `volume`, `ringer` | - | any |
| Third-party tiles | done | TileHost.kt | - | any |
| Media card + output switcher | done | ShellMedia.kt ("the phone's output picker"), control.tsx | - | any |
| Notification reply + actions, clear all | done | notifications.tsx (RemoteInput, actions, clear all) | - | any |
| Notification snooze | missing | no `snooze` in shade/notifications | M | any (NotificationListenerService.snoozeNotification) |
| Notification history | missing | none | L | any |
| Silent / priority sections, conversation priority | partial | conversations grouped first (grouped()), no silent section | L | any |
| Screen record | done (11-27, device-check pending) | no OnePlus recorder app (S25, razr): own recorder, system/ScreenRecord.kt - audio sheet (none/device/mic/both, remembered), Android's consent per recording, mediaProjection FGS, H.264 + AAC (AudioPlaybackCapture + mic mixed) to Movies/*.mp4, Stop in the notification + the tile (on while recording), "saved" notification opens/shares it; OnePlus keeps `com.oplus.screenrecorder`. Check: tools/phone/verify/screen-record-nonroot.sh (razr, consent reached) | M | any (MediaProjection) |
| Device controls | partial | opens SystemUI's ControlsActivity | L | any |
| Volume panel (hardware keys) | stock | SystemUI's dialog (NATIVE-SYSTEM-UI.md "Leave to SystemUI") | - | - |
| Power menu | stock | same | - | - |
| Shade/CC redesign | wip | board `shade-streamlined-...` (S1-S10) | - | - |

### Home + launcher (`apps.tsx`, `drawer.tsx`, `editsheet.tsx`, `screens.tsx`, `AndroidApps.kt`)

| feature | status | evidence | impact | root |
|---|---|---|---|---|
| App shortcuts on long-press (Android's static/dynamic/pinned) | done (11-26) | apps.tsx `ShortcutRows` at the menu's top (max 4, stock order, icons, placeholder rows while read) via `apps.shortcuts`/`apps.startShortcut` (shell/AppShortcuts.kt, `LauncherApps.getShortcuts`/`startShortcut`); drag-out to home not done | H | any (default launcher) |
| Notification dots on Android app icons | missing | badge.ts: `host.badge` from PowOS apps only; Android apps' notifications never mark their icon | M | any (listener already granted) |
| App info, uninstall | done | apps.tsx `app info`, `uninstall` | - | any |
| Work / clone profile apps | done | AndroidApps.kt `work`, `clone` | - | any |
| Hidden apps | missing | no hide in the drawer menu | L | any |
| Wallpaper picker | done | screens.tsx wallpaper / live wallpaper | - | any |
| Widget picker + stacks | done / wip | editsheet.tsx AppWidgetPick; board `home-stack-widgets-...` | - | any |
| Suggested / recent apps | done | drawer.tsx Suggested | - | any |

### System

| feature | status | evidence | impact | root |
|---|---|---|---|---|
| Back gesture / navigation | stock | SystemUI EdgeBackGestureHandler kept | - | - |
| Recents switcher | done | PowosRecentsService, switcher.tsx, recents.tsx | - | root for recents component; non-root path in nonroot-parity |
| Split screen | wip | board `switcher-drag-dock-open-canvas` | - | - |
| Picture-in-picture | done | webwindows.tsx PP1 (Android PiP honoured), 7a53eb85 | - | any |
| Timers / stopwatch visible outside the Clock app | partial | only as notifications in the shade | M | any |
| Battery saver | done | tile `cmd power set-mode` (root); no root: battery saver settings page (TilePaths) | - | any |
| DND toggle | done | tile `dnd` | - | any |
| DND schedules / modes | stock | long-press opens ZEN_MODE_SETTINGS | L | - |
| Digital Wellbeing | stock | Settings app; nothing in PowOS | L | - |
| Accessibility shortcuts | stock | - | L | - |
| Keyboard + switching | done | PowOS keyboard (DefaultKeyboard.kt); IME picker is SystemUI's | - | - |
| Clipboard history | partial | ClipHistory.kt: the terminal's paste picker (6b5358d6); no system clipboard panel in the keyboard/shade | M | any |
| Share sheet | stock | Android chooser; PowOS app targets (PowosAiActivity SEND) | L | - |
| Assistant | done | PowosVoiceInteractionService | - | any |

## B. Apple-level quality of life

| feature | status | evidence | impact | root | how the fleet could do it better |
|---|---|---|---|---|---|
| Live Activities / island around the camera ring | partial | v1 (11-27): a black pill hugging the camera hole (ui/chrome.tsx LiveIsland, system/LiveActivities.kt) from ongoing notifications - playing media, call, timer/stopwatch (chronometer), progress, Android 16 promoted live updates; tap opens the app, long-press widens with the title, "+N" for more; the recording colour becomes its edge. Not yet: an expanded card below the strip, controls (pause, stop timer), no-camera screens | H | any (ongoing notifications + Android 16 promoted "live updates" from the listener) | agent/AI task progress, ship/build progress and the .58 job from the board, beside timers, calls, media, navigation and deliveries |
| Universal clipboard | missing | ClipHistory.kt is local; Plasma bridge clipboard is phone<->its own Linux only | H | any | realm-relayed (account sync 4018c5d7), E2E with the account key, to every signed-in device incl. Plasma on .58 |
| Send to my device (AirDrop-style) | missing | nothing in the share sheet targets a device; Devices tab (93fabd14) lists them | H | any | a share-sheet target per signed-in device; files via `/mnt/nas/cdn` for big ones, direct LAN otherwise |
| Handoff (continue the app/page elsewhere) | partial | remote windows from .58 (waypipe, board `remote-linux-window-...`), PowStream windows blocked; no "continue this tab/page" | M | any | URLs/app routes (`openApp(id, from, route)`) handed off through the realm; web windows already carry their URL |
| Unlock with another device | partial | 82f5711c: phone unlocks the desktop (owner only); no watch/phone-unlocks-phone | M | any | glasses/watch presence (GlassesPresenceService) as a trust signal |
| Call/SMS relay to desktop | missing | KDE Connect on .58 unpaired (device-ecosystem.md L14) | M | any | notifications + reply to the desktop shell through the realm, reusing the shade's RemoteInput |
| Sidecar / second screen | partial | remote windows research (native-window-remoting.md); no phone-as-display | L | root for virtual display input | - |
| Focus modes (per-context home + notification filter, auto by time/place/app) | partial | 11-27: modes (DND, Sleep, Work, Gaming) with app allow-lists, control-center focus tile (tap on/off, hold picks), Settings > focus (shell/ui/focus.ts); DND through the listener, held ones out of shade/lock/banners; allowed apps banner through DND (notifications.focus) but stay silent (no per-app DND bypass without the user marking them priority). Not yet: per-context home, schedules, people allow-lists | M | any (listener filters; DND via NotificationManager policy access) | one Focus syncs to every device (account sync) |
| Notification summary / digest | partial | "What needs me" app (App API history providers, blocked); 11-27: a focus mode's held notifications on one digest card (by app, Show / Clear), kept after the mode ends; not yet: digest at set times, LLM summary | M | any | the local LLM summarises the shade, delivered at chosen times |
| Spotlight-grade search | partial | search providers: apps, settings, android-settings, app-api (LAUNCHER-SEARCH.md); no contacts, files, messages, web, calculator/units, actions on results | H | any | files on the NAS/.58 and agents' results from the same bar |
| Shortcuts / automation | partial (device check queued) | 11-27: Settings > automations - user-built "when X, do Y" run by the app (automations/Automations.kt: exact alarms, framework proximity alerts, receivers; re-armed at boot), no root. Triggers: time + weekdays, arriving/leaving a saved place, an app opened from PowOS, charger in/out, a Bluetooth device connecting/going; optional days + time window. Actions: notify, open app/URL, Wi-Fi/BT/DND on/off, a focus mode, any App API action (consumer `automation`; the runtime still refuses writes outside chat). Not yet: desktop runner (powos-shell), app-opened from outside PowOS (recents/notifications), App API action arguments in the editor | M | any | triggers from any fleet device (arrive home -> lights, desktop wake) |
| Live Text / Visual Look Up | partial | v1 2026-11-27: share "Copy text" + "Scan text" tile (camera still), selectable words, copy/share/search/translate, tappable phone/link/email/address; ML Kit on device + PowScan PaddleOCR-VL (docs/research/live-text.md); no live viewfinder yet | M | any | OCR on gpu-195 (PaddleOCR-VL, as PowScan) or on device |
| Text selection loupe, drag & drop between apps | stock / partial | WebView/Android give the loupe; drag & drop only inside PowOS (webwindows, aiboard), not between Android web windows | L | any | - |
| Haptics everywhere | partial | haptics.ts `tick` used in 21 of 75 shell/ui components | M | any | - |
| 120 fps, interruptible physics gestures | partial | spring.ts, gesture.ts follow-the-finger; perf work ongoing (board home-perf) | M | any | - |
| Undo (shake / 3-finger) | partial | undo on some removals (grid, stacks, switcher); no system-wide undo | L | any | - |
| Back Tap | missing | none | L | any (accelerometer) | - |
| StandBy (charging + landscape: clock/widgets) | done (device check queued) | PowosDozeService as the "when charging" screensaver shows shell/ui/standby.tsx: big clock + two scroll-snap stacks (lock glance: alarm/event/weather/date; now playing/charge), red night look from the light sensor, tap ends the dream; upright = aod. Gate SBY1, tools/phone/verify/standby.sh. Picking PowOS as the screensaver is the user's (Settings > Display > Screen saver; no root can set it) | M | any | next: the Open's inner screen as a home dashboard (Lights, agents, calendar) as more stack cards |
| Interactive widgets | done | PowOS islands are live Preact (island.tsx); Android widgets bound | - | any | - |
| Lock screen customization (clock, depth effect, widgets) | partial | 11-27: clock font/weight/colour (shared with AOD/StandBy), lock backdrop apart from home (tint/darker/theme/black - no separate lock picture yet), glance items + now playing on/off, both corners choosable (torch/camera/focus/recorder/any app); face long press once biometric-unlocked, or Settings > lock screen (lockstyle.ts, lockedit.tsx); local, no account sync for shell prefs. No depth effect | M | any | - |
| Find My devices (locate, ring, lock, wipe) | partial | Devices: lock/sleep/screen on/off, ring until stopped + locate (FindMy.kt, 11-27, docs/DEVICES.md), no wipe; ecosystem task parked (streamline) | M | any (ring, location); wipe needs device owner | small scope: ring + last location from the realm, lock via PowosLockAdmin |
| Password / passkey autofill (Keychain) | partial | PowPass (its own repo) is the vault + AutofillService + passkey provider; PowOS settings tile "passwords" picks it (docs/research/autofill.md) | M | any | PowPass Android app must reach the HTTPS server first |
| Wallet / passes | stock | Google Wallet tile | L | - | - |
| Battery health + charging limit | missing | charge.ts shows time to full only | L | root for the limit | - |
| Screen Time insights | partial | AppUsage.kt counts launches (Suggested); no time-per-app view | L | any (UsageStats) | across all devices |

## Ranked gaps (parity + QoL merged; wip items excluded)

1. ~~Control-center toggles do nothing without root (S25, razr)~~ - done 11-25 (TilePaths.kt), device check pending.
2. Lock face: camera + torch shortcuts - any, H.
3. Fingerprint unlock straight from the face (verify on all three; UDFPS target on S25/razr) - any, H.
4. Long-press Android app shortcuts in the app menu - any, H.
5. Live activities around the camera ring (timers, calls, media, agent progress) - any, H.
6. Universal clipboard across signed-in devices - any, H.
7. Send to my device from the share sheet - any, H.
8. Spotlight-grade search (contacts, files, web, calculator, actions) - any, H.
9. Lock face glance: next alarm, weather, next calendar event - any, M.
10. Notification dots on Android app icons - any, M.
11. Focus modes + notification digest - any, M. First version landed 11-27 (focus.ts; check tools/phone/verify/focus-modes.sh).
12. Password/passkey autofill via PowAuth - any, M.
13. ~~Find My: ring + locate (small scope)~~ - landed 11-27 (FindMy.kt), phone check find-my.sh queued.
14. ~~StandBy on charge + landscape~~ - done 11-27 (standby.tsx, PowosDozeService), device check pending.
15. Notification snooze - any, M.
16. Screen record on S25/razr (MediaProjection, own recorder) - any, M.
17. AOD: now playing + fingerprint target - any, M. (done 11-27: AOD1; tap/lift-to-wake left)
18. Haptics audit across the shell - any, M.
19. Handoff (continue page/app on another device) - any, M.
20. Lock face customization - any, M.
21. ~~Automation (user triggers + App API actions)~~ - v1 landed 11-27, device check queued (tools/phone/verify/automations.sh).
22. Live Text in images and the camera - any, M.

Board tasks were added for 1-22 (project "Shade & lock", "Home & launcher" or "Apps").
