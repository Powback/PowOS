# PowOS as the phone's native system UI

Goal: when PowOS is the home app, every system screen comes from PowOS too: the switcher and gestures,
the notification shade and quick settings, the lock screen, the screen-off (AOD) display, and the
PowOS desktop. Do it through the slots Android itself provides, not through accessibility overlays or
hooks. This doc says which slots exist on the OnePlus Open, what each one requires, what we can reach
without OnePlus's platform key, and the order to build it in.

Device the findings come from: OnePlus Open CPH2551, OxygenOS `CPH2551_16.0.5.1301(EX01)`, Android 16
(SDK 36), `ro.build.type=user`, bootloader unlocked (`verifiedbootstate=orange`), Magisk 30.7, Zygisk +
Vector (JingMatrix LSPosed fork) with `com.powos.oplushook`. Evidence: `cmd overlay lookup`, `dumpsys`,
and jadx decompiles of the device's `services.jar`, `oplus-services.jar`, `SystemUI.apk`,
`SystemUIPlugin.apk` and `Aod.apk`, plus `aapt2 dump` of `framework-res.apk`. All of that was read-only,
and the pulled files and decompiles stayed in a local tmp directory. Researched 2026-10-19.

## The rule: one UI codebase, hot-reloaded, in every slot

Each system slot PowOS takes (switcher, shade and quick settings, lock screen face, screen-off display, home) is a
thin native host: Kotlin that holds the slot's role, its system window, its input and its permissions - nothing more.
What every one of them shows is the web shell (`shell/`, TypeScript), the same code as the launcher, in a WebView
with the shell's hot reload: an edit (by the user or an AI agent) pushed to the phone shows in every screen at once,
no APK, no reboot. A slot's look or behaviour never lives in Kotlin; if a host needs to draw something, that's a
missing bridge call, not a native view. This is what "native" means here: PowOS owns the screens through the
platform's own slots - not overlays or hooks on top of the stock UI.

## TL;DR

- **The key slot is `config_recentsComponentName`.** The package it names gets every permission with
  the `recents` protection flag, and on this device that list includes `STATUS_BAR_SERVICE`, `STATUS_BAR`,
  `MANAGE_ACTIVITY_TASKS`, `MONITOR_INPUT`, `INTERNAL_SYSTEM_WINDOW`, `READ_FRAME_BUFFER`,
  `BIND_QUICK_SETTINGS_TILE`, `START_TASKS_FROM_RECENTS`, `REMOVE_TASKS`, `SYSTEM_APPLICATION_OVERLAY`,
  `BROADCAST_CLOSE_SYSTEM_DIALOGS` and more, about 24 in all. Android grants them only to a *system*
  package (`KnownPackages.PACKAGE_RECENTS` → `filterOnlySystemPackages`), and no platform signature is
  involved. A systemless `/system/priv-app` install plus one framework RRO gets them. This one step covers
  the switcher and gestures, and gives the shade and quick settings everything they need.
- **Notification shade + QS: keep SystemUI and switch its shade off.** We do not replace it. PowOS, as the
  recents app, calls `IStatusBarService.disable(DISABLE_EXPAND | DISABLE_NOTIFICATION_ALERTS …)`. SystemUI
  then won't pull down or show heads-up notifications. PowOS sees the top-edge swipe through the same
  input monitor Quickstep uses, and draws its shade in a `TYPE_STATUS_BAR_SUB_PANEL` window, which sits
  above SystemUI's status bar and shade. It hosts third-party QS tiles natively (`BIND_QUICK_SETTINGS_TILE`).
  The disable flags are tied to a binder token, so if PowOS dies, SystemUI's shade comes back
  automatically.
- **Screen-off / AOD: `config_dozeComponent` → a PowOS `DreamService`.** The framework only checks that
  the service declares `BIND_DREAM_SERVICE` and holds the current dream token. No signature check. This is
  the lowest-risk slot.
- **Lock screen: a full KeyguardService replacement is not reachable without the platform key.**
  `config_keyguardComponent` is bound without a signature check, but a keyguard has to call
  `keyguardGoingAway` (`CONTROL_KEYGUARD`), `setLockScreenShown` (`DEVICE_POWER`), `checkCredential`
  (`ACCESS_KEYGUARD_SECURE_STORAGE`) and the keyguard biometrics path (`USE_BIOMETRIC_INTERNAL`). All four
  are signature-only on this build. The native option that works: SystemUI stays the security authority
  (bouncer, Gatekeeper/Trusty, biometrics), and PowOS is the lock screen's **face** (clock, notifications,
  media, widgets), drawn as a show-when-locked surface that hands off to SystemUI's bouncer through
  `requestDismissKeyguard`.
- **Ruled out:** replacing SystemUI wholesale (`config_systemUIServiceComponent`: platform shared UID, a
  hundred-plus signature permissions), and SystemUI plugins (`com.android.systemui.permission.PLUGIN` is
  `signature`, and `Build.IS_DEBUGGABLE` is false).
- **First step:** a Magisk module that installs PowOS as a priv-app with its privapp allowlist, with **no
  overlay yet**. Then confirm on the device that the privileged permissions are granted and that boot is
  clean.

## 1. The swappable slots on this device

Values are the effective ones (`cmd overlay lookup android android:<res>`, 2026-10-19).

| Slot (framework resource) | Value on the Open | Who reads it | What a replacement needs | Without the platform key? |
|---|---|---|---|---|
| `string/config_recentsComponentName` | `com.android.launcher/com.android.quickstep.RecentsActivity` (OnePlus launcher, `/system_ext/priv-app/OplusLauncher`, platform-signed, shared UID `oppo.uid.launcher`) | ATMS `RecentTasks.loadRecentsComponent` (sets `mRecentsUid`, so `isCallerRecents`); PermissionManager (`recents` protection flag); SystemUI `LauncherProxyService` (binds `android.intent.action.QUICKSTEP_SERVICE` in that package) | A **system** package (priv-app or app) holding a `TouchInteractionService` with action `QUICKSTEP_SERVICE`, protected by `android:permission="android.permission.STATUS_BAR_SERVICE"`. It implements `ILauncherProxy` and receives `ISystemUiProxy` plus the WM Shell interfaces in `onInitialize` | **Yes.** `PermissionManagerServiceImpl` line ~2540: `if (!allowed && bp.isRecents() && knownPackages(17).contains(pkg)) allowed = true;` with `KnownPackages[17] = filterOnlySystemPackages(mRecentsPackage)` |
| `string/config_dozeComponent` | `com.android.systemui/com.android.systemui.doze.DozeService` (`mDozeConfig.ambientDisplayComponent()`). OnePlus's AOD runs inside it: SystemUI's `AODPluginManager` loads `com.oplus.aodimpl.AodManager` from `com.oplus.aod` (`/product/app/Aod`) through a foreign package context | `DreamManagerService.getDozeComponent` → `validateDream` | A `DreamService` declared with `android:permission="android.permission.BIND_DREAM_SERVICE"` that calls `setDozeScreenState` and `startDozing()`. `startDozingInternal` only checks that `mCurrentDream.token == token && canDoze` | **Yes.** No signature or privileged check. A partition RRO is still needed to change the value |
| `string/config_dreamsDefaultComponent` | `com.android.deskclock/com.android.deskclock.Screensaver`; `config_dreamsSupported=true`, but `mDreamsEnabledSetting=false` | DreamManager (screensaver while charging or docked) | A `DreamService` with `BIND_DREAM_SERVICE` | **Yes, no root needed:** dreams are user-selectable (`screensaver_components`). Only the *default* needs an RRO |
| `string/config_keyguardComponent` | `com.android.systemui/com.android.systemui.keyguard.KeyguardService` | `KeyguardServiceDelegate.bindService` (plain `bindServiceAsUser` as SYSTEM, no signature check); `biometrics/Utils.isKeyguard()`; `IPackageManagerBase` (`ensureSystemPackageName`) | `IKeyguardService`, and it must *call* `ATMS.keyguardGoingAway` (`CONTROL_KEYGUARD`: **signature**), `setLockScreenShown` (`DEVICE_POWER`: **signature\|role**), `LockSettingsService.checkCredential` (`ACCESS_KEYGUARD_SECURE_STORAGE`: **signature\|setup**) or `verifyCredential` (`SET_AND_VERIFY_LOCKSCREEN_CREDENTIALS`: **signature**), and fingerprint/face for keyguard (`USE_BIOMETRIC_INTERNAL`: **signature**) | **No.** The framework would bind us, but we could never unlock the device. See section 3 |
| `string/config_systemUIServiceComponent`, `config_systemUi` | `com.android.systemui/.SystemUIService`, `com.android.systemui` (`/system_ext/priv-app/SystemUI`, shared UID `android.uid.systemui`, platform-signed) | SystemServer starts it; many services trust the `config_systemUi` package | Everything SystemUI does (list in section 3), with signature permissions | **No** |
| Status bar / shade: `IStatusBarService.registerStatusBar(IStatusBar)` | SystemUI's `CommandQueue` | `StatusBarManagerService`: `enforceStatusBarService()`, then `this.mBar = bar;`. **One slot; the last caller wins** | `STATUS_BAR_SERVICE` (`signature\|recents`) | Reachable as the recents app, **but it is a takeover, not a coexistence**: registering would steal the channel SystemUI uses for nav bar, biometric prompt, global actions, IME switcher and more. Don't register. Use `disable()` (section 3) |
| Window singletons: `TYPE_STATUS_BAR` (2000), `TYPE_NAVIGATION_BAR` (2019), `TYPE_NOTIFICATION_SHADE` (2040) | SystemUI's windows | `DisplayPolicy.validateAddingWindowLw` returns `ADD_MULTIPLE_SINGLETON` (-7) while SystemUI's window is alive | `STATUS_BAR_SERVICE` | Taken. The non-singleton system types **2017 `TYPE_STATUS_BAR_SUB_PANEL`**, 2024, 2033 and **2041 `TYPE_STATUS_BAR_ADDITIONAL`** only need `STATUS_BAR_SERVICE`, so they are ours as the recents app |
| QS tiles | SystemUI QS host | `TileService` binding requires the binder to hold `BIND_QUICK_SETTINGS_TILE` | `signature\|recents` | **Yes, as the recents app**: PowOS can bind every app's `TileService` itself |
| Screenshot: `config_screenshotServiceComponent` | `com.android.systemui/.screenshot.TakeScreenshotService` | `ScreenshotHelper` | Captures need `READ_FRAME_BUFFER` (recents) | Possible later. Low value, keep SystemUI's |
| Volume dialog, power menu (GlobalActions), biometric prompt, IME switcher, USB/permission dialogs, media output, nav bar, back gesture (`EdgeBackGestureHandler`) | SystemUI | Plugin interfaces (volume, global actions) need the PLUGIN permission; the rest are internal to SystemUI | n/a | **Keep SystemUI's.** Style through public settings only |
| SystemUI plugins (`PluginManagerImpl`) | `com.oplus.systemui.plugins` (`/system_ext/app/SystemUIPlugin`, platform-signed) | `PluginsModule`: enabled only `if Build.IS_DEBUGGABLE` (false on `user`) or the package is in `config_pluginAllowlist`; it must also hold `com.android.systemui.permission.PLUGIN`, `protectionLevel=signature` (SystemUI manifest) | Platform signature | **No** |
| `config_secondaryHomePackage` | `com.android.launcher` | Home on secondary displays | Same as home | Not needed on the Open (cover and inner screens are never both active) |

Related facts:

- **`framework-res.apk` declares no `<overlayable>` at all** (`aapt2 dump overlayable` is empty). A
  *preinstalled* overlay (on a system partition) may therefore override any framework resource,
  `config_*` included. A `/data` overlay can't target `android`. Magisk's systemless mount of
  `/system/product/overlay/…` counts as preinstalled. `config_overlayConfigSignaturePackage` is unset, so
  no signature-based overlay policy applies.
- **The `recents` permission set** (decoded from `framework-res` with the AOSP flag values, `recents`
  being `0x2000000`): `ACCESS_SHORTCUTS, ALLOW_SLIPPERY_TOUCHES, BIND_QUICK_SETTINGS_TILE,
  BROADCAST_CLOSE_SYSTEM_DIALOGS, CONTROL_REMOTE_APP_TRANSITION_ANIMATIONS, GET_PEOPLE_TILE_PREVIEW,
  GET_TOP_ACTIVITY_INFO, INTERNAL_SYSTEM_WINDOW, MANAGE_ACCESSIBILITY, MANAGE_ACTIVITY_TASKS, MONITOR_INPUT,
  READ_FRAME_BUFFER, READ_PEOPLE_DATA, REMOVE_TASKS, ROTATE_SURFACE_FLINGER, SET_CLIP_SOURCE,
  SET_ORIENTATION, SET_UNRESTRICTED_GESTURE_EXCLUSION, START_TASKS_FROM_RECENTS, STATUS_BAR,
  STATUS_BAR_SERVICE, STOP_APP_SWITCHES, SYSTEM_APPLICATION_OVERLAY, WAKEUP_SURFACE_FLINGER`. The
  launcher's `TouchInteractionService` is itself guarded by `STATUS_BAR_SERVICE` (`dumpsys package
  com.android.launcher`).
- **OnePlus kept AOSP's AIDL transaction codes** for `ILauncherProxy` (descriptor
  `com.android.systemui.shared.recents.ILauncherProxy`, renamed from `IOverviewProxy` in A16) and
  `ISystemUiProxy`, and appended its own at 151+. For example, ILauncherProxy has `onOverviewToggle=7`,
  `onInitialize=13`, `onSystemUiStateChanged=17`, `disable=20`, `onUnbind=36`, plus OnePlus's
  `getPreAppIcon=151` … `startCircleToSearchOnRecentsAnimRealFinish=159`. ISystemUiProxy has
  `startScreenPinning=2`, `onStatusBarTouchEvent=10`, `expandNotificationPanel=30`, `takeScreenshot=52`,
  `toggleNotificationPanel=51`, `toggleQuickSettingsPanel=57`, plus OnePlus's `onGetAppIcon=151` …
  `onLauncherUnlockAnimationEnd=159`. AOSP android16 Launcher3 AIDL therefore lines up. We can ignore
  OnePlus's extra one-way calls on our side, and we avoid calling theirs.
- `ro.control_privapp_permissions=enforce`. A priv-app that requests a `signature|privileged` permission
  missing from a privapp-permissions XML makes system_server throw at boot (`IllegalStateException:
  Signature|privileged permissions not in privapp-permissions allowlist`, `PermissionManagerServiceImpl`
  ~3360). That is a **bootloop**. This is the riskiest single detail in the plan (section 4).
- OnePlus coupling to its launcher package that we would lose as the recents app: `oplus-services` sends
  and expects broadcasts such as `com.android.launcher.action.RECENTS_VISIBLE`, `GESTURE_TARGET_HOME`,
  `TOGGLE_BAR_CHANGE`, `recent_lock_limit_num`, and the super-power-save launcher. Most of OnePlus's
  big-screen features live in the launcher: the taskbar, swipe-to-split and floating window
  (`OplusBaseSwipeUpHandler` trigger panel), and Open Canvas gestures. Our `oplus-hook` exists to keep
  those working. **Becoming the recents provider means PowOS owns the taskbar and the split/float
  gestures**, which the system side (`MANAGE_ACTIVITY_TASKS`, WM Shell `ISplitScreen`) permits.

## 2. Making com.powos.app privileged without rebuilding the ROM

A Magisk module, `powos-system` (systemless, so nothing in the real partitions changes):

```
powos-system/
  module.prop
  system/priv-app/PowOS/PowOS.apk                  # same package + same signing key as the /data install
  system/etc/permissions/privapp-permissions-com.powos.app.xml
  system/product/overlay/PowOSConfig/PowOSConfig.apk   # RRO targeting "android", added in phase 2+, not phase 1
  post-fs-data.sh   # boot watchdog (section 4)
  service.sh
```

- **How the permissions get granted.** `privileged` permissions are granted at boot to
  `pkgSetting.isPrivileged()` packages listed in the allowlist XML (`<privapp-permissions
  package="com.powos.app"><permission name="android.permission.STATUS_BAR"/>…`). It must sit on the
  **same partition** as the APK (`/system/etc/permissions` for `/system/priv-app`). `recents`
  permissions are granted to whichever system package `config_recentsComponentName` names. That value is
  read at boot, so changing it means a reboot. Permissions that are both `privileged` and `recents`
  (`STATUS_BAR`, `START_TASKS_FROM_RECENTS`, `CONTROL_REMOTE_APP_TRANSITION_ANIMATIONS`,
  `STOP_APP_SWITCHES`, `BROADCAST_CLOSE_SYSTEM_DIALOGS`) go through the allowlist check first, so they
  **must be in the XML** or boot fails. Rule: list every `signature|privileged` permission the manifest
  requests. A build-time check should diff the manifest against the XML and fail the build.
- **The dev loop stays normal.** With the base APK in `/system/priv-app`, a regular `adb install -r` or a
  PowApps update lands in `/data` as an *update of a system app*. It keeps `isPrivileged()`, and
  `checkPrivilegedPermissionAllowlist` returns true for `isUpdatedSystemApp()`. The catch: a
  *newly added* privileged permission is only granted if the `/system` copy already requested it
  (`shouldGrantPrivilegedPermissionIfWasGranted`). So refresh the module's APK whenever the permission set
  changes. Ship it through the android-app-dev pipeline (`make build PROJECT=`), not a renamed artifact.
- **Signing must match.** If the `/system` copy and the existing `/data` install are signed differently,
  PackageManager drops the `/data` package *and its data* at boot (the Linux session, settings). Before
  the first install, check that the module's APK carries the same cert as the installed app
  (`dumpsys package com.powos.app | grep signatures`). Today's install is `DEBUGGABLE`; the module must
  use the same build key.
- **Out of reach without the platform key (signature-only):** `CONTROL_KEYGUARD`,
  `ACCESS_KEYGUARD_SECURE_STORAGE`, `SET_AND_VERIFY_LOCKSCREEN_CREDENTIALS`, `USE_BIOMETRIC_INTERNAL`,
  `DEVICE_POWER`, `INJECT_EVENTS`, `MANAGE_NOTIFICATIONS`, `REGISTER_WINDOW_MANAGER_LISTENERS`,
  `CONTROL_DISPLAY_BRIGHTNESS`, `BIND_DREAM_SERVICE`, `BIND_NOTIFICATION_LISTENER_SERVICE` (only the
  binder side, which we never need), the SystemUI PLUGIN permission, and the platform and SystemUI shared
  UIDs. Consequences: no own keyguard, no plugins in SystemUI, no driving the display or power state
  directly. Brightness and power go through public or `WRITE_SECURE_SETTINGS` paths.
- **Hidden APIs.** Priv-apps are *not* exempt; only platform-signed apps are. `IStatusBarService`,
  `IActivityTaskManager.getTaskSnapshot`, the WM Shell interfaces and `InputManager.monitorGestureInput`
  are all `@hide`. Two options: the Apache-2.0 `org.lsposed.hiddenapibypass` library (what Lawnchair
  ships), or `settings put global hidden_api_policy 1` (global and coarse, a fallback). Bypassing hidden
  APIs is a HACK by the repo's rule and must be marked as one. The real fix is calling them from a
  platform-signed process, which we can't have.

## 3. Per screen: recommended architecture

### Switcher and gestures: become the recents provider (Quickstep model)

PowOS already is HOME. Make it `config_recentsComponentName` too, pointing at its own recents activity,
which can be the home activity: AOSP's "home is recents" mode, not `FallbackRecents`. SystemUI then binds
PowOS's `TouchInteractionService`. What PowOS must implement:

1. `TouchInteractionService` (`QUICKSTEP_SERVICE`, guarded by `STATUS_BAR_SERVICE`), returning an
   `ILauncherProxy` binder. `onInitialize(Bundle)` hands over `ISystemUiProxy` plus WM Shell's
   `IRecentTasks`, `IShellTransitions`, `ISplitScreen`, `IPip`, `IBackAnimation` and the rest.
2. An input monitor (`monitorGestureInput`, `MONITOR_INPUT`) over the nav-bar region from
   `onActiveNavBarRegionChanges`. It recognises swipe-up (home), swipe-up-hold (switcher) and
   swipe-sideways (quick switch), then calls `pilferPointers()`. The back gesture stays in SystemUI.
3. The recents transition: `IRecentTasks.startRecentsTransition(…, IRecentsAnimationRunner)`, which
   gives the app leashes to animate. Then finish to home, finish to an app, or cancel.
4. The task list and thumbnails: `getRecentTasks` (`MANAGE_ACTIVITY_TASKS`) and `getTaskSnapshot`
   (`READ_FRAME_BUFFER`), drawn by the existing web shell's switcher.
5. The taskbar on the inner screen (`TYPE_NAVIGATION_BAR_PANEL`, 2024) and split/float through
   `ISplitScreen` and freeform. This replaces what `oplus-hook` patches into OnePlus's launcher today.

Base it on AOSP `android16-release` Launcher3's `quickstep/` (Apache-2.0) as a reference and for the
AIDL. Write a slim Kotlin implementation, not a Launcher3 fork: Quickstep alone is around 100k lines and
tied to Launcher's own UI. Effort: about 3-5 weeks for gestures, home, the switcher and quick switch with
decent animations, plus 2-3 weeks for the taskbar and split/float on the inner screen.

**Fallback while building it:** if the recents package doesn't resolve `QUICKSTEP_SERVICE`, SystemUI's
`LauncherProxyService.mIsEnabled` is false. Then swipe-home and recents do nothing. Stage this slot with
3-button navigation (`com.android.internal.systemui.navbar.threebutton` exists, disabled) and disable the
overlay to get OnePlus's launcher back.

### Notification shade + quick settings: option (b), keep SystemUI and disable its shade

| Option | Verdict |
|---|---|
| (a) Replace SystemUI | **No.** SystemUI is also the nav bar and back gesture, volume, power menu, biometric prompt, screenshots, the keyguard, AOD, IME switcher, USB, media output, permission and screen-recording dialogs, the WM Shell host, and OnePlus's fingerprint animation and flexible-window chrome. It runs as `android.uid.systemui` with signature permissions we can't get. A crash there is a crash of the phone's UI with no fallback |
| (b) Keep SystemUI, disable its shade, host our own | **Recommended.** It uses only documented system mechanisms (the `disable` flags kiosk and setup-wizard flows use, the input-monitor path Quickstep uses, and system window types), all granted through the recents slot |
| (c) SystemUI plugins | **Blocked.** The PLUGIN permission is `signature` and `IS_DEBUGGABLE=false` |
| (d) Vector/LSPosed module inside SystemUI hosting PowOS views | Works today: Vector is installed and `oplus-hook` uses it. But it is a hook, breaks on every SystemUI update, and the user rejected it. Only for gaps (b) can't close, each marked HACK |

The design for (b):

- **Suppress SystemUI's shade.** `IStatusBarService.disable(DISABLE_EXPAND | DISABLE_NOTIFICATION_ALERTS
  [| DISABLE_NOTIFICATION_ICONS | DISABLE_CLOCK | DISABLE_SYSTEM_INFO when PowOS draws the bar],
  token, "com.powos.app")` and `disable2(DISABLE2_QUICK_SETTINGS | DISABLE2_NOTIFICATION_SHADE)`, with
  `STATUS_BAR`. The flags are keyed by a binder token, so StatusBarManagerService drops them when PowOS's
  process dies. That is a built-in fail-safe, because SystemUI's shade comes back on its own. Apply them
  only while unlocked to start with, and keep SystemUI's keyguard shade until the lock-screen phase.
- **Gesture.** The same input monitor as the switcher watches the top edge. A swipe down opens PowOS's
  shade (left or right half → notifications or QS, mirroring OnePlus's split
  `OplusSeparateNotificationAndQSEx`).
- **Window.** `TYPE_STATUS_BAR_SUB_PANEL` (2017, `STATUS_BAR_SERVICE`) layers above the status bar and
  SystemUI's shade window. The status-bar row itself can be a `TYPE_STATUS_BAR_ADDITIONAL` (2041) strip.
  SystemUI's own `TYPE_STATUS_BAR` keeps owning the insets.
- **Content.** The existing `shell/ui/notifications.tsx` with the `NotificationListenerService` data:
  actions, inline reply, snooze, dismiss. Report clicks and clears through
  `IStatusBarService.onNotificationClick` and `onNotificationClear` (`STATUS_BAR_SERVICE`) so ranking and
  stats stay correct. Launch content intents with `START_ACTIVITIES_FROM_BACKGROUND` (privileged,
  allowlisted). PowOS draws heads-up notifications itself.
- **QS.** PowOS binds third-party `TileService`s (`BIND_QUICK_SETTINGS_TILE`, recents). Wi-Fi, BT,
  airplane, DND, rotation, flashlight and the rest go through public or `WRITE_SECURE_SETTINGS` APIs.
  Brightness uses the `SCREEN_BRIGHTNESS` setting (`CONTROL_DISPLAY_BRIGHTNESS` is signature).
- **Leave to SystemUI:** volume, power menu, biometric prompt, screenshots, IME switcher.
- **Requests from third parties** to open the shade (`StatusBarManager.expandNotificationsPanel`) go to
  SystemUI and are dropped while `DISABLE_EXPAND` is set. That is acceptable. Do not register an
  `IStatusBar` to catch them.

Effort: about 2-3 weeks on top of the recents slot, since the web UI already exists.

### Lock screen: PowOS is the face, SystemUI keeps the lock

Replacing `config_keyguardComponent` would get bound, but the replacement could never unlock, verify a
PIN, or use the fingerprint sensor (section 1). Getting those signature permissions would need a hook
inside system_server, a Vector module scoped to `android`. That is high risk (system_server crash =
bootloop) and hands the device's security to our code. **Don't.** Gatekeeper/Trusty, the bouncer, lockout
policy and biometrics must stay the system's.

Native design:

- A PowOS lock activity (`setShowWhenLocked(true)`, `setTurnScreenOn`) started on `SCREEN_OFF` and
  keyguard-showing (`SUBSCRIBE_TO_KEYGUARD_LOCKED_STATE`, privileged). It shows the clock, notifications
  (respecting the "hide sensitive content" settings), media and widgets, all rendered by the shell.
- Unlock is `KeyguardManager.requestDismissKeyguard(activity, callback)` (public API). SystemUI's bouncer
  takes the PIN, Gatekeeper verifies it, and the trust and biometric state stay SystemUI's.
- **To verify:** whether side-fingerprint unlock fires while a show-when-locked app occludes the keyguard.
  SystemUI's `KeyguardUpdateMonitor` listens while occluded only in some states. If it doesn't, the
  fingerprint touch calls `requestDismissKeyguard`, and the bouncer appears with the fingerprint armed.
- Later, with `DISABLE_*` flags while locked, SystemUI's keyguard clock and notifications can be hidden so
  only the bouncer shows.

Effort: about 1-2 weeks. Security note: the lock face must never offer actions (reply, open, toggles)
that bypass `requestDismissKeyguard`.

### Screen off / AOD: PowOS as the doze component

- A `PowosDozeService extends DreamService`: `setDozeScreenState(Display.STATE_DOZE[_SUSPEND])`,
  `startDozing()`, low-power rendering (black background, minimal redraws, no WebView in the doze path at
  first; a native view). An RRO sets `config_dozeComponent` to it.
- Loses OnePlus's AOD styles and settings (`com.oplus.aod` runs inside SystemUI's DozeService) and
  SystemUI's doze state (pulsing, the "dozing" keyguard look). The keyguard behind still works, and the
  dream occludes it.
- **To verify:** that the panel actually enters its low-power AOD mode on standard `STATE_DOZE` without
  OnePlus's `AodManager`, and that pick-up and tap wake still come through.
- The screensaver (`config_dreamsDefaultComponent`) needs no root: ship a PowOS `DreamService` and select
  it.

Effort: about 1 week. Risk: the lowest of all slots, since a broken doze dream only means no AOD.

### PowOS desktop

It stays what it is: an app and the rooted Linux session shown on Android. As the recents app, PowOS can
list, launch and arrange Android tasks itself (`MANAGE_ACTIVITY_TASKS`, `START_TASKS_FROM_RECENTS`,
freeform and split through WM Shell). That replaces the split-pick plumbing through OnePlus's launcher
(`powos.split_pick`, `run/split-pick`). The desktop becomes one "mode" of the same home and recents
provider: phone home on the cover screen, desktop on the inner screen. `oplus-hook` retires once PowOS
owns recents.

## priv_app and sockets (found on the phone, 2026-10-19)

Phase 0 (PowOS as a priv-app) broke the rooted PowOS session. As `priv_app` the app's data is `privapp_data_file`,
and this phone's policy gives `priv_app` no `sock_file` permissions there (nor anywhere: only `untrusted_app_all`
may create sockets in its data). The display daemon (`libandromarchy`, run by SessionService) binds
`files/run/andromarchy/display_daemon.sock`; it couldn't (`bind: Address already in use` on the stale socket it could
neither remove nor replace), KWin's anland backend then had no display, and the session ended - terminal tiles, PowOS
apps, folding went with it. Adding an SELinux rule is off the table (never weaken SELinux), so the module was rolled
back to overlays only (`build-module.sh` without `--priv-app`), and the app is an ordinary app again.

Before priv-app comes back, the session's sockets must not be files in the app's data: abstract-namespace Unix
sockets for the daemon and termux-va (the session shares the network namespace), or sockets the root session owns
that the app connects to. Slots that need no privilege don't wait for it: the doze component (below) went live with an
overlay-only module (since reverted: it felt laggy; its overlay is kept in `system-module/overlays-disabled/`, which
the module build doesn't ship).

**Fixed by design (2026-10-19)**, no policy change. In rooted mode the app binds and connects to no socket file:

| Socket | Listens | Connects | Address |
|---|---|---|---|
| Display daemon | `libandromarchy` (the app's domain) | KWin's Anland backend (Magisk's domain, as powos), the app's display and control channel | `@powos.display` (SessionService.DISPLAY_SOCKET), passed to the session as `<display socket>` |
| Gamepad | `powos-padd` (root) | the app (PadSender) | `@powos.padd` (PadHub.PADD_SOCKET = powos-padd's SOCK) |
| termux-va | `libtermuxva` started by the root session (powos-session.sh), not by the app | Mesa's termuxva driver | `<run dir>/termux-va.sock`, a file root makes: Mesa's client only connects to paths (and checks the endpoint's inode) |

The phone's policy allows all of it: `priv_app` (and `untrusted_app_*`) may bind, listen, accept and `connectto` its
own `unix_stream_socket`; Magisk's domain is permissive, so KWin may `connectto` the app's socket; and Magisk's rules
let every app domain `connectto` a Magisk-domain socket (padd). An abstract name has no file permissions and any
process may take it first, so each end checks the other's uid (`SO_PEERCRED`: the app's uid or root;
`socket_utils.c`, KWin patch 0015, SessionService.trustedPeer, powos-padd's `trusted()`). A daemon of a killed app
process still holds its name: SessionService ends such leftovers before starting the daemon, which also retries its
bind for a few seconds. The no-root engine keeps its socket files (the app is `untrusted_app` there, and its Linux
side knows only paths).

Still path sockets in the app, outside the rooted session: Omalauncher's own Wayland server (its proot Linux, not
installed with rooted PowOS) and Andromarchy's "connect with root" setting (the fd helper's bridge socket in the
cache dir, off by default). Both would fail as a priv-app if used.

Verified on the phone 2026-10-19 with `build-module.sh --priv-app` (no overlays): PowOS `SYSTEM`/`PRIVILEGED`, the
app in `priv_app` with `privapp_data_file` data; the session came up (daemon on `@powos.display`, KWin's producer
connected, padd on `@powos.padd`), terminals (`powos-run.sh`) and a VA-API H.264 encode through termux-va worked. As an
ordinary app the same build also showed the desktop.

**Overlays must be static.** On Android 16 the system server only takes immutable framework overlays (zygote builds
their idmaps); a mutable overlay reached apps (`cmd overlay lookup` showed it) but DreamManagerService kept the stock
doze component. With `isStatic="true"` it switched. OnePlus also gates the doze component on its
`oplus.software.display.aod_support` feature (AmbientDisplayConfiguration.ambientDisplayComponent), which this phone has.

## Recents slot and shade: built (2026-10-19), not yet tried on the phone

What's in the tree, all live only with the module built `--priv-app --slot recents` (the overlay sits in
`system-module/overlays-disabled/recents/` until it's verified; then it moves to `overlays/`):

- `system/PowosRecentsService.kt`: the `QUICKSTEP_SERVICE` (guarded by `STATUS_BAR_SERVICE`) returning
  `ILauncherProxy` (`src/main/aidl`, AOSP's interface with this device's ids, only the calls PowOS takes; the rest,
  OnePlus's 151+ included, are dropped one-way calls). `onOverviewToggle` → the switcher; `onInitialize` keeps the
  `ISystemUiProxy` binder and starts the shade; `onSystemUiStateChanged` feeds it; `onUnbind` answers its
  `IRemoteCallback` by hand.
- The switcher: `shell/SwitcherActivity.kt` (the `config_recentsComponentName` activity) borrowing a warm page
  (`system/Switcher.kt`, mode=switcher, `shell/ui/switcher.tsx`). `system/Tasks.kt`: `getRecentTasks` (all tasks: the
  caller is recents), `getTaskSnapshot` (served at `/_task/<id>`), `startActivityFromRecents`, `removeTask`.
- The shade: `system/ShadeHost.kt`. Flags on the process's StatusBarManager token (`DISABLE_EXPAND`,
  `DISABLE2_NOTIFICATION_SHADE | _QUICK_SETTINGS`), lifted while SystemUI reports the keyguard (`SYSUI_STATE` bit 6) and
  lent back while its own panel is asked for (the panel's "quick settings" button). A `TYPE_STATUS_BAR_ADDITIONAL`
  strip over the status bar takes the pull (HACK: it also takes taps there; the real fix is the input monitor below);
  the page is in a `TYPE_STATUS_BAR_SUB_PANEL` window kept warm and hidden on `shade.closed`.
- Allowlist: `STATUS_BAR`, `START_TASKS_FROM_RECENTS` (both privileged as well as recents). The rest
  (`STATUS_BAR_SERVICE`, `READ_FRAME_BUFFER`, `REMOVE_TASKS`, `INTERNAL_SYSTEM_WINDOW`) come with the role.
- Hidden calls via `org.lsposed.hiddenapibypass`, exempting only the classes used (`system/HiddenApi.kt`).

Only **3-button navigation** works with it. With the overlay on and gesture navigation selected, SystemUI routes the
swipes to PowOS, which doesn't handle them yet: home and recents gestures do nothing. Gesture navigation still needs:

1. An input monitor (`InputManager.monitorGestureInput`, `MONITOR_INPUT`) over the region `onActiveNavBarRegionChanges`
   gives, with `pilferPointers` once a swipe is recognised (an `InputEventReceiver` subclass: compile-time stubs).
2. The recents transition: WM Shell's `IRecentTasks.startRecentsTransition` (its binder is in `onInitialize`'s bundle)
   with an `IRecentsAnimationRunner`, the leashes animated to home, to the switcher or to the next task (quick switch).
3. `ISystemUiProxy` calls for what SystemUI expects of the gesture provider (`onBackEvent`, `onStatusBarTouchEvent`,
   `notifySwipeToRecentFinished` on this phone).
4. The same monitor replaces the shade's strip (the pull seen without taking the status bar's taps).

## 4. Safety

| Step | What can go wrong | Bootloop? | Recovery |
|---|---|---|---|
| priv-app + allowlist | A missing allowlist entry, with `enforce`, makes system_server throw at boot | **Yes** | See below |
| priv-app, signature mismatch | The `/data` install and its data are wiped | No | Restore from backup. Prevent it by checking certs first |
| framework RRO (`config_recentsComponentName`) | No `QUICKSTEP_SERVICE`, so home and recents gestures are dead; OnePlus's taskbar and split are gone | No (boots, nav degraded) | `cmd overlay disable com.powos.config.recents` + reboot; 3-button nav meanwhile |
| RRO `config_dozeComponent` | No AOD, or a stuck-black doze | No | `cmd overlay disable …` + reboot; the power button still wakes |
| shade `disable` flags | A PowOS bug leaves no shade at all | No | The flags die with PowOS's process (force-stop restores SystemUI's shade); `cmd statusbar` too |
| lock face | A show-when-locked surface that leaks content or blocks the bouncer | No | Force-stop PowOS; the keyguard is untouched |

Recovery ladder for a bootloop:

1. adbd comes up early in most bootloops: `adb wait-for-device shell su -c 'touch
   /data/adb/modules/powos-system/disable'`, then reboot. Or `magisk --remove-modules`.
2. Android safe mode (hold volume-down during boot). Magisk boots with all modules disabled.
3. A watchdog in the module: `post-fs-data.sh` counts boots that didn't reach `sys.boot_completed`
   (`service.sh` clears the counter). After 2 failed boots it touches `disable` and reboots. This is the
   module's own self-heal, independent of adb.
4. Last resort: fastboot-boot a stock or Magisk-patched `init_boot` without modules, or flash stock
   `init_boot` (bootloader is unlocked).

Staging rules:

- One slot per reboot, one overlay APK per slot (`com.powos.config.recents`, `com.powos.config.doze`), so
  each can be disabled alone.
- Overlays are **non-static**, and therefore mutable: a partition overlay without `isStatic` starts
  disabled and is turned on with `cmd overlay enable`, so `cmd overlay disable` + reboot is the per-slot
  rollback without touching the module. Stock components are never removed. They remain the values
  underneath the overlay.
- Before each phase, save a `dumpsys package com.powos.app` and `cmd overlay list` snapshot, and keep the
  OnePlus launcher installed and enabled.

## 5. Phased plan

| Phase | What | Effort | Done when |
|---|---|---|---|
| 0 | **Module skeleton, no overlay.** `powos-system` Magisk module built by the PowOS pipeline: priv-app APK (same key), allowlist generated from the manifest by a build check, boot watchdog. | 2-3 days | PowOS shows `PRIVILEGED` and its privileged permissions granted; clean boot; uninstall restores the user app |
| 1 | **AOD.** `PowosDozeService`, RRO `config_dozeComponent`. | ~1 week | Screen-off shows PowOS's AOD; disabling the overlay restores OnePlus's |
| 2 | **Recents provider.** `TouchInteractionService`, input monitor, recents transition, switcher in the shell; RRO `config_recentsComponentName`. Retire `oplus-hook`. | 3-5 weeks | Swipe home/switcher/quick-switch work on both screens; recents permissions granted |
| 3 | **Taskbar + split/float** on the inner screen. | 2-3 weeks | Feature parity with what `oplus-hook` restores today |
| 4 | **Shade + QS.** `disable` flags, top-edge gesture, sub-panel window, own heads-up notifications, third-party tiles. | 2-3 weeks | SystemUI's shade never appears unlocked; PowOS's does |
| 5 | **Lock face.** Show-when-locked PowOS lock, `requestDismissKeyguard`, fingerprint check, then SystemUI keyguard chrome hidden via disable flags. | 1-2 weeks | Lock screen is PowOS's; PIN and fingerprint are still the system's |
| 6 | **Desktop integration.** Desktop as a mode of the same provider; task management without the launcher. | 1-2 weeks | Split-pick and task control without OnePlus's launcher |

**Concrete first step (phase 0):** add `targets/android/system-module/` with a builder that wraps the
current release APK into `system/priv-app/PowOS/PowOS.apk` and generates
`privapp-permissions-com.powos.app.xml` from the merged manifest. The builder fails if any
`signature|privileged` permission is missing. Also add the boot-count watchdog. Then, after the user
approves installing it on the phone, flash it through Magisk, reboot once, and check the grants with
`dumpsys package com.powos.app` before any overlay exists.

Open questions to settle with a device test (each is a "to verify" above): fingerprint unlock under a
show-when-locked occluder; whether the panel enters its AOD mode without OnePlus's `AodManager`; whether
`hiddenapibypass` holds on this ART build; whether OxygenOS's Settings resets a non-OnePlus recents
provider (OnePlus's own `OverviewComponentObserver` logic lives in its launcher, which we'd no longer run).
