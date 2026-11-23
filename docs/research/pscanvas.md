# OxygenOS Open Canvas (com.oplus.pscanvas): how it captures launches, and what opts out (2026-11-23)

The ask: decompile OxygenOS's "Open Canvas" / pocket studio split view (`com.oplus.pscanvas`) on the rooted OnePlus
Open, read-only (nothing disabled or removed). Explain how a launch gets captured into the canvas, the
`CanvasCalculateLayoutRect` rules, how it took home's task and Chrome off their displays, and which settings or flags
opt an app or the system out. Then say whether PowOS's canvas HACKs can be replaced by a supported opt-out.

**Sources.** jadx 1.5.1 output of the phone's `oplus-framework.jar`, `oplus-services.jar`, `services.jar` and
`SystemUI.apk`. These are the copies pulled on 2026-10-23 for the caption work (`~/.cache/powos-caption/`); the
`com.oplus.pscanvas` APK section is at the end. Decompiled on .58 (`podman`, `nomad.slice`, image
`localhost/powjob/jadx:1.5.1`). The binaries and jadx trees are in `~powos/research/pscanvas/2026-11-23/` on .58, not
in git (see "Where the files are"). Each claim below names the class and method it comes from, so it can be checked
against the next OTA.

## TL;DR

- Two paths take a launch into the canvas. Both run in system_server, before the activity starts:
  `ActivityStarter.startActivityInner` → `ActivityStarterExtImpl.interceptStartForSplitScreenMode` →
  `OplusSplitScreenManagerService.needInterceptStartForSplitScreen`.
  1. **Launch-adjacent.** Any start with `FLAG_ACTIVITY_LAUNCH_ADJACENT | FLAG_ACTIVITY_NEW_TASK` is always turned into
     a canvas. The canvas holds **the caller's task** and the new app. When the caller is PowOS's home activity,
     **home's task becomes half of the canvas**.
  2. **"Pick a second app" (minimized pocket studio).** The app handle's split item
     (`FullscreenTaskOperations.moveTaskToSplitScreen` → `toggleSplitScreen(4)`) shrinks the app and sets
     `setMinimizedPocketStudio(true)`. From then on the next app start from anywhere joins it
     (`OplusFlexibleWindowMinimizedManagerHelper.needInterceptActivityForMinimized` → `enterSplitForMinimized`). This
     state only ends on its own when the stock launcher package **`com.android.launcher`** starts (a hard-coded
     string). Going home to PowOS doesn't end it, so the next dock tap joins the canvas. This matches the 10-31 02:49
     incident: Chrome's handle-menu split item, then Settings from the dock.
- **No supported opt-out exists for an app.** I found no `Settings.Global/Secure/System` switch. The real switches are:
  - the system feature `oplus.software.pocketstudio.support`
  - the `/system_ext/oplus/sys_wms_split_app_ps.xml` blacklist, or its RUS copy in `/data/oplus/os/config/`
  - a framework-res package array, the launch-adjacent exemption list `mSpecialPkgList`
  - the WM-Shell-only `Task.setLaunchAdjacentDisabled`

  Each one is either global, root-and-partition-write, or reserved to the task organizer.
- **What an app can reach:** per-launch keys in the ActivityOptions extra bundle `"androidx.activity.extra"`, using the
  public `startActivity(intent, bundle)`, plus two state reads that need no permission:
  `FlexibleWindowManager.isMinimizedPocketStudio(0)` and `isInPocketStudio(0)`. None of the extras says "never put
  this launch in a canvas". The **explicit fullscreen windowing mode that `Tasks.fullScreenOptions` sends is read by no
  canvas path I could find**: every windowing-mode check on these paths compares against 100 (OnePlus zoom).
- Recommendation (details below): keep all four HACKs, and correct the `Tasks.kt:252` reason. Add the one change that
  helps: **read `isMinimizedPocketStudio(0)` before a home/dock launch**. If it is set, the user asked OxygenOS for a
  split, so either let it pair (and drop home's recovery) or route the second app into PowOS's own WM Shell split.
  Measure first with the logcat tags listed under "Check on the phone".

## 1. The pieces

| piece | where | role |
|---|---|---|
| `com.oplus.pscanvas` | system app (APK section below) | The canvas UI. Its container activity hosts 2 or 3 "embedded" tasks, and its control bar sits between them. Launched by the intent `oplus.intent.action.pocket.studio.canvas`. |
| `FlexibleWindowManager` | `oplus-framework.jar`, `com.oplus.flexiblewindow` | Client API. `startPocketStudio(ctx, intents, taskIds, userIds, opts, canvasExtra)` builds `Intent(ACTION_POCKET_STUDIO).setPackage("com.oplus.pscanvas")`, adds category DEFAULT and flags `0x18000000` (NEW_TASK + MULTIPLE_TASK) plus Oplus flag `16384`, and passes the extras `androidx.flexible.intentList`, `KEY_CANVAS_TASK_ID_LIST`, `KEY_CANVAS_USER_ID_LIST`, focus index and orientation. `isSupportPocketStudio(ctx)` = feature `oplus.software.pocketstudio.support` (on a flip phone also aspect > 16:9). The gate `shouldSkipStartPocketStudio` needs `com.oplus.permission.safe.WINDOW`. |
| `CanvasCalculateLayoutRect` (+ `Phone`/`Tablet`/`DefaultCanvasCalculateLayoutRectPolicy`) | `oplus-framework.jar` | Pure geometry: the rect of each of the 2-3 tasks (section 4). It decides nothing about capture. |
| `OplusSplitScreenManagerService` | `oplus-services.jar` | `needInterceptStartForSplitScreen` (the hook) and `startPsForAdjacent` / `startOrRelpaceSplitWithAdjacentLocked` / `splitScreenForApplication`. |
| `FlexibleWindowManagerService`, `OplusFlexibleWindowMinimizedManagerHelper`, `FlexibleAppInnerSplitScreenAnimationMgr`, `FlexibleTaskController` | `oplus-services.jar` | Canvas and flexible-window state: the minimized "pick" state, the app-inner split that builds a canvas from a task plus an intent, and across-task capture inside a canvas. |
| `OplusSplitScreenAppReader` | `oplus-services.jar` | The per-package policy: `/system_ext/oplus/sys_wms_split_app_ps.xml` (or `sys_wms_split_app.xml`), overridden by RUS `/data/oplus/os/config/sys_wms_split_app.xml` when that file's version is newer and enabled. `dumpsys` cmd `reload_xml`. |
| SystemUI | `SystemUI.apk` | The handle menu's split item: `com.android.wm.shell.fullscreen.FullscreenTaskOperations.moveTaskToSplitScreen` → `OplusStatusBarManager.toggleSplitScreen(4)`. `com.oplus.splitscreen.SplitToggleHelper` skips its own (AOSP-style) toggle when `isSupportPocketStudio`, so on this phone the canvas replaces WM Shell split for that item. |

Words used below. Launch scenario (the `androidx.activity.LaunchScenario` int in the ActivityOptions extra bundle,
mirrored on the task as `getLaunchScenario()`): 0 = normal, **1 = flexible (floating) task, 2 = embedded in a canvas**.
This is the "VRI scenario=2" seen on home's task on 10-31. Windowing mode 100 = OnePlus zoom (floating window).

## 2. How a launch gets captured

All of it hangs off one hook in AOSP's `ActivityStarter.startActivityInner`. It runs after the reused task is found and
before the start is committed:

```
interceptStartForSplitScreenMode(intent, request, sourceRecord, startActivity, options, reusedTask, newTask)
  -> OplusPanoramaWorkBranchController.hookStartActivity(...)
  -> IOplusSplitScreenManager.needInterceptStartForSplitScreen(...)      // true = the start is swallowed
       logged as OplusAppInterceptLogger "startActivityInner" "interceptStartForSplitScreenMode."
```

`needInterceptStartForSplitScreen`, with pocket studio supported (it is, on the Open):

1. **Launch-adjacent.** Condition: `(flags & 0x1000) && (flags & 0x10000000)`.
   - If `sourceRecord.getTask().isLaunchAdjacentDisabled()`, the flag is removed and the start goes on normally.
   - If the target package is in `mSpecialPkgList` (framework resource array `0x0c070055`, read by
     `getSpecialPkgList`), the start is not captured ("don't start PS").
   - Otherwise `startPsForAdjacent(intent, sourceRecord)` runs. It strips ADJACENT, adds MULTIPLE_TASK, adds the extras
     `androidx.flexible.adjacent=true` and `androidx.activity.NewTaskChangeCallingUidFlag`, wraps the result in a
     PendingIntent, and posts it with the **source task id**.
   - `startOrRelpaceSplitWithAdjacentLocked` then disables launch-adjacent on the source task for 1 s and calls
     `splitScreenForApplication(pi, pos, sourceTask)`. If the top fullscreen task is RECENTS (type 3) it gives up. If
     it is HOME and there is *no* source task, it goes to the minimized "pick" flow
     (`startFlexibleWindowForActiveSplitScreen`). In every other case it calls
     `FlexibleWindowManagerService.startAppInnerSplitScreen(ctx, sourceTask.getTopNonFinishingActivity(), …, pi, pos)`.
   - That path is refused only when the first activity is on the pocket-studio blacklist
     (`FlexibleAppInnerSplitScreenAnimationMgr.isAllowStartAppInnerSplitScreen` → `isInPocketStudioBlackList`).
     Home is not on it (PowOS's package isn't), so **the canvas is built from the source task + the new app**. The
     source task's id goes into `KEY_CANVAS_TASK_ID_LIST`, and the canvas reparents that task into itself as scenario
     2. That is the "took home's task (2527) into it" of 10-31.
   - The source of the second intent in PowOS's own `Tasks.launchAdjacent` (one `startActivities` call) is the first
     app's activity, not home: AOSP's `startActivities` passes the previous result as the source. So that pair becomes
     a [first, second] canvas, which is the 11-09 job 20261109-121732-73666. It cannot pull home in. A
     launch-adjacent sent *from home's own task* would.
2. `needInterceptStartEmbeddedActivityOnCanvasStopped(options)`: a start aimed at an embedded task of a stopped canvas
   is swallowed.
3. **Minimized ("pick a second app") state.** If `isMinimizedPocketStudio(0)`, the result comes from
   `FlexibleWindowManagerService.shouldInterceptStartFromActivityStarter` →
   `OplusFlexibleWindowMinimizedManagerHelper.needInterceptActivityForMinimized`. Below.
4. Otherwise `shouldInterceptStartActivityForSplitScreenAnim`. This swallows (doesn't capture) starts during a
   fullscreen-drag, close or four-finger animation. `shouldInterceptStartActivityForCloseAnim` applies only to calls
   `startByHome(uid)`, and that only matches the uid of `com.android.launcher`.

### 2a. The minimized "pick" state, the 10-31 path

How the state is entered (all of these call `setMinimizedPocketStudio(true, 0)`):

- `toggleFlexibleWindowMode`: the app handle's split item, through SystemUI
  `FullscreenTaskOperations.moveTaskToSplitScreen` → `OplusStatusBarManager.toggleSplitScreen(4)`
- `startFlexibleWindowForRecentTasks` (recents)
- `startFlexibleWindowForActiveSplitScreen` (launch-adjacent with home on top and no source)
- `enterTwoSplitToMini`, `notifyMinimizedReady`, and the drag-to-minimize animations

What happens to the next start in `needInterceptActivityForMinimized`, in order:

- Not intercepted:
  - `isStartFlexibleContainerTask`: only `com.heytap.quicksearchbox` from a flexible launcher
  - `isSpecialConditionStart`, which covers:
    - not minimized
    - `com.oplus.matrix`
    - the hard-coded `mBlackList`: `com.heytap.quicksearchbox`, `android`, `com.oplus.pscanvas`, bootreg,
      `com.android.launcher/…LauncherTaskbarSettingActivity`, `com.android.intentresolver/…ChooserActivityLauncher`, …
    - a start whose `EXTRA_PACKAGE_NAME` is the first app
    - Settings' main page, permission dialogs, GMS sign-in hints
- Not intercepted: a target on a "mirage" display (`OplusMirageWindowManagerService.isMirageDisplayId`: id 2020 or
  ≥ 10000) or a reused task of activity type HOME/RECENTS ("not allowed intercept start launcher, include third
  launcher"). Note that **this does not end the state.**
- A zoom-style launch (`isFlexibleTaskAndHasCaption(options)`: LaunchScenario 1 + `androidx.activity.HasCaption`) is
  let through unless it is the first app itself.
- An app that doesn't support pocket studio (`isSupportPocketStudio(launchIntent)`) is swallowed with a toast. The
  exceptions are the Japanese parental-filter packages and `shouldSkipInterceptForNotSupportIntent`, which end the
  state instead.
- **`"com.android.launcher".equals(startPkg)` → `exitMinimizedToHome()`**. This is the only "user went home" exit, and
  it names the stock launcher's package.
- Otherwise, for a different task in a valid state, `enterSplitForMinimized(taskId, launchIntent, …)` →
  `enterNormalSplitForMinimized` (or `enterThreeSplitForMinimized` in the two-mini state) runs. The state is cleared
  and the canvas is built from the minimized first app + the started one. The statistics call it
  `VALUE_ACTION_HOME_CLICK` only when `startByHome`, which again means the uid of `com.android.launcher`.

So with PowOS as the home app, the "pick a second app" mode the handle menu starts **outlives the trip home**. The
user's next dock or drawer tap is taken as the pick. Every start in that state can be captured, whatever its windowing
mode. On 10-31 02:49 the dock started Settings with Chrome minimized after its handle-menu split item, and that made
the [Chrome, Settings] canvas. How home's task also ended up inside it (scenario 2) is not shown by this code path. It
is either path 1 (something started an adjacent launch with home as the source) or the canvas container's own task
handling, which is in the pscanvas APK (section 6).

### 2b. Inside a canvas

- `interceptStartActivityInVisibleTask` swallows a second start of an app that is already embedded (the "app has
  opened" toast).
- `isIgnoreAppearedAcrossTask` decides whether a new task started from an embedded task joins the canvas ("across
  task"). It does not join when the extra bundle carries **`androidx.flexible.newtask.fullscreen=true`**, or when the
  source is in a scenario-2 root and the launch mode isn't 100.
- `updateFlexibleWindowTask` (`ActivityStarterExtImpl.updateFlexibleWindowTask` → `linkTask`) links new tasks to their
  source's flexible state. This is how an app started from inside the canvas, or a task the canvas reuses, is moved
  onto display 0. Chrome left a PowOS web-window display this way on 10-30 (`WebWindows.kt` reconcile). Only "mirage"
  display ids (2020, ≥ 10000) are exempt, and PowOS's virtual displays get small ids from DisplayManager.

## 3. Conditions: fold state, display, windowing modes

- **Folded vs unfolded is not a gate.** `FlexibleWindowManager.isSupportPocketStudio` is true on the Open (a fold, not
  a flip) in both postures.
  - Posture changes the *layout policy*. `CanvasCalculateLayoutRect.isPhoneDisplay` (aspect > 1.7, the cover screen)
    selects `PhoneCanvasCalculateLayoutRectPolicy`, and the inner screen uses the generic two/three-split layout.
  - `FlexibleWindowManagerService.onFolderStateChange` only hides the IME.
  - `persist.sys.pocket_studio_plus` (default true) changes the cover-screen rules: `isInPsCanvasBlackList` uses
    `supportsSplitScreenMultiWindow` there when it is false, and `setAppUseMaxByStoreData` returns early on the cover
    screen when it is false.
- Windowing modes: the canvas code compares the launch windowing mode only against **100** (zoom):
  `interceptStartActivityFromFlexibleWindow` returns early for 100, `hookOptionsForSplit` and
  `isFromNotificationReply` act on 100. I found no check for FULLSCREEN (1) or FREEFORM (5) on any capture path. The
  other `getLaunchWindowingMode()` reads are in compact-window/access-control code (6, 7) and Panorama.
- Launch bounds matter only for flexible (scenario 1) tasks (`isFlexibleTaskLaunchBoundsOutScreen`).

## 4. CanvasCalculateLayoutRect rules

`com.oplus.flexiblewindow.CanvasCalculateLayoutRect` (oplus-framework). Entry points: `layoutRectCalculate[WithOrientation]`,
`layoutReplaceRectCalculate[Three]`. The service side is `OplusActivityTaskManager.calculateCanvasLayoutRect` /
`calculateReplaceCanvasLayoutRect`.

- Input: 2-3 intents (more → empty list, "invalid intent list"), focus index 0-2, global (panorama) mode.
- Per intent, `taskDataGetFromIntent` asks `FlexibleWindowManager.calculateFlexibleWindowBounds(intent with
  KEY_LAUNCH_TASK_SCENARIO=2, appOrientation, 0)`:
  - `androidx.flexible.ResizeMode` 0 → **"not support pocket studio"**, and the intent is dropped
  - 1 = resizable, 2 = fixed ratio (`KEY_FLEXIBLE_COMPAT_RATIO`), 3 = fill-in
  - bounds, max bounds, predict bounds, screen orientation, stable rect
  - If fewer than 2 remain: "task data list is less two", so no layout.
- Fold + inner screen with 2 apps: an app with the extra `androidx.flexible.window.white.vertical.list` can force a
  vertical (portrait) split. `androidx.flexible.window.flexible.current.rect` carries the current rect, so a resize
  keeps a portrait/landscape choice.
- Orientation: `computeLayoutOrientation` (policy per device: Phone/Tablet/Default via `getCalculateLayoutRectPolicy`)
  → 1 VERTICAL / 2 HORIZONTAL. Three apps: `sortTaskDataList` + the `THREE_LAYOUT_BIG_{UP,DOWN,LEFT,RIGHT}` /
  `THREE_LINE_{VERTICAL,HORIZONTAL}` layouts, `isThreeSpacialLargeRatioRect` for 16:9 apps.
- Two apps: cover screen (`isPhoneDisplay`) → `PhoneCanvasCalculateLayoutRectPolicy.twoSplitLayout` (with
  `predictIfForceRotation`); else `twoSplitLayout`/`twoFixedSplitLayout`, 8 dp padding (`TWO_SPLIT_PADDING`).
  "Use max" (`androidx.flexible.window.flexible.use.max`, `setAppUseMaxByStoreData`) gives a resizable app its max
  rect. This is ignored for two windows of one app (`isSingleApplicationSplit`) and for `com.oplus.wpslauncher` in
  portrait.
- Then `scaleRectForFocusOrPanorama` scales the set to fit the screen around the focused one, or to the "global view"
  (`globalViewScale`), and `getLocationOnScreenWithFocus` handles canvas scrolling.
- Device type comes from the features `oplus.hardware.type.fold` (1) and `oplus.hardware.type.tablet` (2).

The layout takes no package policy into account beyond resize mode. It decides *where*, never *whether*.

## 5. Opt-outs: what exists and who can use it

| switch | scope | what it does | usable by PowOS? |
|---|---|---|---|
| feature `oplus.software.pocketstudio.support` (`OplusFeatureConfigManager`) | whole system | Off → `isSupportPocketStudio` false → none of the above; the old WM Shell split path (`mStackDividerConnection`) comes back | root + a feature-xml change on `/my_product`/`/odm`. Global: it also removes Open Canvas for the user. Not an app opt-out. |
| `persist.sys.pocket_studio_plus` | whole system | Cover-screen layout and blacklist rules only | Not an off switch. |
| `sys_wms_split_app_ps.xml` disable-multi-window map → `isInPocketStudioBlackList(pkg, component)` (type 2/3) | per package or component | For the *first* activity: no app-inner canvas from it (`isAllowStartAppInnerSplitScreen`). Also `isFlexibleTaskInPSBlackList` and `isInPsCanvasBlackList`. | Root write to `/data/oplus/os/config/sys_wms_split_app.xml` with a higher version (RUS overrides; an OTA or RUS push replaces it), then `dumpsys … reload_xml`. Listing PowOS's home there would keep path 1 from pulling home's task in. Not supported and not public. |
| `mSpecialPkgList` (framework-res array `0x0c070055`) | per target package | A launch-adjacent start of that package isn't captured | Needs a framework-res RRO (root, platform-level). |
| `Task.setLaunchAdjacentDisabled(true)` on the source task | per task | The system strips ADJACENT instead of making a canvas | Only through `WindowContainerTransaction.setLaunchAdjacentDisabled`, which belongs to the task organizer (WM Shell). Not an app API. |
| `FlexibleWindowManager.setMinimizedPocketStudio(false, 0)` | global state | Ends the "pick" state without its animation or cleanup (the proper path is `exitMinimizedToHome`) | Needs `com.oplus.permission.safe.WINDOW` (root-uid binder calls pass `enforceCallingPermission`). Not recommended: it flips the flag under a running animation state machine. |
| ActivityOptions extra bundle `androidx.activity.extra`: `androidx.flexible.newtask.fullscreen` | per launch | A new task started from inside a canvas doesn't join it (`isIgnoreAppearedAcrossTask`) | Yes, with the public `startActivity(intent, options.toBundle().apply { putBundle("androidx.activity.extra", …) })`. It doesn't help paths 1 or 2a. |
| `resizeableActivity=false` on an activity | per activity | `ResizeMode` 0 → dropped from the *layout* ("not support pocket studio") | It doesn't stop `startAppInnerSplitScreen` (that checks only the blacklist), and home must stay resizable for PowOS's own windows. Not a fix. |
| Settings keys | | None found. The only Settings read in this area is `Settings.System recommender_split_screen_enable` (the split *recommendation* toast) | |

Reading the state needs no permission: `OplusActivityTaskManagerServiceEnhance.isMinimizedPocketStudio(displayId)`,
`isInPocketStudio(displayId)`, `getPocketStudioTaskRegion(displayId)`. An app reaches them through
`com.oplus.flexiblewindow.FlexibleWindowManager.getInstance()` (oplus-framework is on the boot classpath, so
reflection works).

## Driving Open Canvas from PowOS

The goal (user, 11-23): in the switcher, dragging a window up and to one side docks it to that side of OxygenOS's
native split view (Open Canvas, not PowOS's desktop split). This section lists every way into the canvas that the code
has, what each one needs, and the sequence to use. Not proven on the device yet: the phone stayed off the VPN, see
"Proof still to run".

### Entry points

| # | entry | caller needs | side / size control | existing task? |
|---|---|---|---|---|
| A | **`LauncherApps.startShortcut(publisherPkg, shortcutId, sourceBounds, opts, user)`** on a shortcut with ≥ 2 intents and `isPsSplitScreenCombination=true` (OxygenOS's "app pair" shortcut). Path: `LauncherAppsService.startShortcutInner` → `OplusPairTaskManager.prepareOptionsBeforeStartShortcut` (merges the shortcut's own `ShortcutInfo.getExtras()` into `opts`) → `getActivityOptionsForLauncher` (keeps the raw bundle for a combination) → `ActivityTaskManagerService.LocalService.startActivitiesAsPackage` → `ActivityTaskManagerServiceExtImpl.startPairTaskIfNeed` → `OplusSplitScreenManagerService.startPairTaskIfNeed` → private `startPocketStudio(intents, options, userId)` → `FlexibleWindowManagerService.startShortcut` → `FlexibleWindowManager.startPocketStudio(systemContext, intents, taskIds = all -1, userIds, null, options)`, run with the system's identity (`Binder.clearCallingIdentity`). | **The default launcher**, i.e. the shortcut-host permission, which PowOS has as home. No Oplus permission: system_server makes the privileged call. `persist.sys.pair_split_feature_enable` must not be false (default true). | Order of the intents = order in the canvas: intent 0 is left (or top), intent 1 is right (or bottom). `options` is passed through as `canvasExtra`, so `androidx.flexible.layoutOrientation` (2 = side by side, 1 = stacked, per `CanvasCalculateLayoutRect.twoSplitLayout`), `focusIndex` → `androidx.flexible.focusIndex` and `androidx.flexible.useMaxLayoutArray` (boolean[], each app's max rect) apply. Sizes come from `CanvasCalculateLayoutRect` (section 4); there is no free divider value. | Starts by **intent** with task ids -1. Whether pscanvas reuses an app's existing task is in the pscanvas APK (pending). `mDisplayFolded == 0` on a large-screen non-tablet with 3 apps, or an intent unsupported on the small screen (`hasNoSupportPsIntentInSmallScreen`) → `showCannotOpenShortCut` (which posture 0 means is to confirm on the device). Blacklisted apps → refused (`hasIntentInPsBlackList`). |
| B | `FlexibleWindowManager.startPocketStudio(ctx, intents, taskIds, userIds, activityBundle, canvasExtra)`, the client method in the caller's process | `com.oplus.permission.safe.WINDOW`, checked by `OplusActivityTaskManagerServiceEnhance.shouldSkipStartPocketStudio`. It throws a SecurityException, not a RemoteException, so an unprivileged caller crashes there. Then `startActivityAsUser` of the pscanvas intent from the caller. | Same as A. Here **task ids can be given**: `androidx.flexible.taskIdList`, matched by index to `androidx.flexible.intentList`. | Yes: this is what the system's own paths use for a running task. Examples: `FlexibleAppInnerSplitScreenAnimationMgr.startAppInnerSplitScreen` puts `firstActivity.getTask().mTaskId` in slot 0 or 1 by `position`; the minimized and drag paths do the same. |
| C | `OplusActivityTaskManager.splitScreenForApplication(PendingIntent, position)` → `OplusSplitScreenManagerService.splitScreenForApplication(pi, pos, null)` | `com.oplus.permission.safe.WINDOW` | `position` 0/1/2. The other side is the current top fullscreen task, through `startAppInnerSplitScreen`. With HOME on top it goes into the minimized "pick" flow (`startFlexibleWindowForActiveSplitScreen`) instead. | The top fullscreen task only. |
| D | `OplusActivityTaskManager.startFlexibleWindowForRecentTasks(taskId, rect)` (the recents card's "Split" item) → `OplusFlexibleWindowMinimizedManagerHelper.startFlexibleWindowForRecentTasks(taskId, rect, 0, null)` | `com.oplus.permission.safe.WINDOW` | **No side choice.** The task shrinks from `rect` (the card) into the minimized "pick a second app" state (`initialRecentToFlexibleWindowAnimation`, `setMinimizedPocketStudio(true)`), and the next started app fills the other side (`enterSplitForMinimized`, section 2a). | Yes, by task id. |
| E | launch-adjacent (`FLAG_ACTIVITY_LAUNCH_ADJACENT \| NEW_TASK`) | Nothing: any app | The new app goes beside the *caller's* task (section 2, path 1). | Only the caller's own task, so PowOS home would become a side. Not usable. |

Exit and adjust (all in `OplusActivityTaskManagerServiceEnhance`; the client side is `FlexibleWindowManager`):

- `exitSplitTask(taskId, bundle)` (safe.WINDOW) takes one task out of the canvas, through
  `notifyCanvasTaskEvent(..., 3)`.
- `exitFlexibleEmbeddedTask(embeddedTaskId)` (safe.WINDOW).
- `replaceSplitTask(oldTaskId, intent, newTaskId, bundle)` swaps one side.
- `toggleMultiFlexibleWindowFromCanvas(taskIds, bounds, scales, extra)` (safe.WINDOW) turns the canvas into floating
  windows.
- `dismissSplitScreenMode(5)` (`oplus.permission.OPLUS_COMPONENT_SAFE`) ends the canvas by starting home
  (`OplusSplitScreenManagerService.dismissSplitScreenMode`: "BREENO call PocketStudio exit and go home"), or calls
  `exitMinimzied()` when minimized.
- Without a permission, the canvas's own control bar still works.
- State reads need no permission: `isInPocketStudio(0)`, `getPocketStudioTaskRegion(0)` (task id → rect), and
  `isMinimizedPocketStudio(0)`.

### What to build for the switcher gesture

1. **Without a privileged path, use entry A.** Publish one dynamic shortcut owned by PowOS
   (`ShortcutManager.setDynamicShortcuts`). Its intents are the two apps' launch intents in on-screen order: the
   dragged app first when it was dropped LEFT, second when dropped RIGHT. Its extras (PersistableBundle) are
   `isPsSplitScreenCombination=true`, `userIds=[u, u]` and `androidx.flexible.layoutOrientation=2` (1 for top/bottom).
   Then call `LauncherApps.startShortcut(context.packageName, id, null, null, myUser)`.
   - The other side has to be named, so the gesture needs a second app: the app behind, the next card, or a pick.
   - Open question: whether pscanvas reuses the dragged app's existing task when it is started by intent. That needs
     the APK, or one device run.
2. **With `com.oplus.permission.safe.WINDOW`, use B with real task ids.** That docks the dragged task itself, with
   its state. To get there:
   - Read the permission's protection level on the phone first:
     `dumpsys package permission com.oplus.permission.safe.WINDOW`.
   - If it is `privileged`, PowOS's Magisk module can install the APK as a priv-app with a privapp-permissions
     allowlist. That is a unit change, user OK first.
   - A root (uid 0) binder caller also passes `enforceCallingPermission`, but `startPocketStudio` needs a Context in
     that process, so it would be a helper.
3. **"Dock one, pick the other", like OxygenOS's own recents "Split",** is D. The side is not selectable there, so it
   doesn't fit "drag to the side".

### Proof still to run (verify queue, idle window, harmless apps only)

Run A with Settings + Files (`com.android.settings`, `com.coloros.filemanager`), unfolded, user idle, queued through
`tools/phone/verify/queue.sh add --dev phone …`:

1. Publish the shortcut and call `startShortcut`, from the PowOS app's debug bridge or a broadcast to it.
2. Check:
   - `logcat -s OplusSplitScreenManagerService FlexibleWindowManagerService` shows "start PocketStudio shortcut"
   - `dumpsys activity activities | grep -i pscanvas`
   - the side each app got
3. Leave: the canvas's own close (or HOME), then confirm both apps are back fullscreen.

Never touch the user's apps.

**Built (11-23):** path A is PowOS's switcher dock - `system/CanvasDock.kt` (shortcut `powos-canvas-pair`,
`pushDynamicShortcut` + `LauncherApps.startShortcut`; availability = unfolded + feature/`isSupportPocketStudio` +
pscanvas installed + `persist.sys.pair_split_feature_enable` + shortcut host), the page's gesture in
`shell/ui/carddock.ts` (card pushed up and toward a side; the target half lit while in the zone; the newest other
single Android app is the other side; none: a note, the card springs back - Open Canvas needs two). Bridge:
`tasks.canvas`, `tasks.canvasDock(id, side, other)`, `tasks.canvasState` (the no-permission reads + the last dock's
measurement). Every dock logs, 2.5 s later, each app's task before vs. in the canvas (`logcat -s PowosCanvasDock`,
"reused" / "new task") - that line answers the task-reuse question until the APK is read. The proof above is
`tools/phone/verify/switcher-canvas-dock.sh` (it also prints the protection level of
`com.oplus.permission.safe.WINDOW`).

**Fixed (11-23 evening), the user: "it does play like a click when i activate the switcher and drag the app to one of
the sides, but it doesnt activate splitview for it".** Root cause, page side (reproduced in Chromium by the gate's
`switcher-canvas-drag`, a CDP touch drag): the gesture did reach `tasks.canvasDock`, but (1) the partner pick
(`dockPartner`) excluded PowOS's own tasks by a `com.powos.app` key prefix that no card key has (keys are `a:pkg/act`,
`l:app`, or null for the lock face/home), so the newest "other app" could be PowOS's lock face or a Linux window -
which the host refuses (`PowOS itself can't be a side`), with no log line; (2) after any refusal the card's fly-off
animation was cancelled, and its `gone` flag only cleared `onfinish`, so that card ignored every later touch - the
next drags did nothing at all, not even the note. Also OxygenOS refuses blocklisted apps (`OplusSplitScreenManagerService:
com.android.settings unSupportsSplitScreen by blockList or ForbidActivityList`). Now: `tasks.canvasSides` (host:
TaskInfo `supportsPocketStudioMultiWindow` / `supportsSplitScreenMultiWindow`, read by reflection, either false = no;
not PowOS's package; has a launch intent) picks the partner; a blocked dragged app says "<App> can't be used in split
view"; every host refusal is logged (`PowosCanvasDock ... refused: <reason>`) and shown.

## 6. com.oplus.pscanvas itself

PENDING: the phone was off the VPN for the whole session (see the hand-back). Next: pull `pm path com.oplus.pscanvas`
plus its oat/vdex, decompile it, and answer:

- how the container activity takes the task ids from `KEY_CANVAS_TASK_ID_LIST` (reparent vs. `startActivityFromRecents`)
- what it does with a task of activity type HOME
- how it finishes on a fold

## 7. PowOS's HACKs against this

| HACK | finding | verdict |
|---|---|---|
| `ShellActivity.kt:230` (home stuck at the inner size after the canvas took home's task; re-deliver HOME) | Home's task gets in through path 1 when an adjacent start has home's task as its source (the canvas uses the source task as its first member). The minimized "pick" state (2a) explains the [Chrome, app] canvas. There is no flag that keeps a third-party home out except the PS blacklist. | Keep the recovery. Root cause is now known, and the reason should name it: "launch-adjacent with home as source, or OxygenOS's minimized pick state, which only `com.android.launcher` ends". |
| `ShellBridge.kt:1220` (start, poll, then WM Shell split instead of launch-adjacent) | Confirmed: with pocket studio supported, every ADJACENT + NEW_TASK start is captured (`needInterceptStartForSplitScreen` → `startPsForAdjacent`). The only exemptions are WM Shell's `setLaunchAdjacentDisabled` and a framework-res list. | Keep. The registry's real fix (WM Shell `ISplitScreen.startIntents`, no launch-adjacent flag) is right: such starts don't carry 0x1000, so path 1 never sees them. |
| `Tasks.kt:252` (explicit FULLSCREEN windowing mode "keeps a launcher start out of the canvas") | No capture path reads windowing mode 1. Path 2a captures any start while minimized. What helped on 10-31 was probably dropping the freeform bounds, or that minimized state ended, not the mode. | The reason in the registry is wrong. Real fix: "none public. Opt-out is the PS blacklist or `isMinimizedPocketStudio` handling". Verify on the phone (below) before changing code. |
| `WebWindows.kt:74` reconcile (Chrome taken off its display, then removed) | The canvas reparents reused or linked tasks to display 0 (`updateFlexibleWindowTask` / `linkTask`). Only Oplus "mirage" display ids are exempt. | Keep the reconcile. There is no opt-out for a virtual display PowOS owns. |

### Recommended next change (not implemented)

1. **Measure first:** the logcat check below on the phone: handle-menu split, then home, then a dock tap. Confirm
   path 2a and whether home's task joins.
2. In the launch path (ShellBridge `launch` / `Tasks.fullScreenOptions` callers): read
   `FlexibleWindowManager.isMinimizedPocketStudio(0)`, which is free and needs no permission.
   - If it is set, the user asked OxygenOS for a split. Make that pick a PowOS split: start the app normally and pair
     it with the minimized task through WM Shell `ISplitScreen` (root path). Or let OxygenOS pair it and skip the
     home re-delivery while `isInPocketStudio(0)`.
   - Also show it on the page, so home never looks idle while OxygenOS waits for a pick.
3. Rewrite the `Tasks.kt:252` row's reason and real fix (registry + comment) to match section 7.
4. Longer term, if the user wants PowOS's own split everywhere: list PowOS's package in the RUS split XML (root, data
   partition, survives until RUS/OTA replaces it). That is the only per-package opt-out, and it is a HACK of its own.

### Check on the phone (read-only)

```
tools/phone/adb.sh shell 'logcat -b all -s OplusSplitScreenManagerService FlexibleWindowManagerService \
  OplusFlexibleWindowMinimizedManagerHelper OplusAppInterceptLogger CanvasCalculateLayoutRect'
tools/phone/adb.sh shell 'dumpsys activity oplus split'   # OplusSplitScreenAppReader dump (cmd name to confirm)
```

The lines to look for: `needInterceptActivityForMinimized targetPkg:…`, `get secondaryPkg:`, `startPocketStudio`,
`interceptStartForSplitScreenMode.`

## Where the files are

- Binaries + jadx output: `.58:~powos/research/pscanvas/2026-11-23/` (`in-cache1023/` = the 10-23 pulls, `jadx/`).
  Meant to go to `/mnt/nas/cdn/powos/research/pscanvas/2026-11-23/`, but `/mnt/nas/cdn/powos` is owned by the NAS
  user (no write for the Mac or the NFS clients). Creating the folder needs `ssh claude@192.168.50.231 mkdir …`
  (PowCDN's way). Then `rsync` from .58.
- Decompile command: `~powos/research/pscanvas/2026-11-23/run-jadx.sh <dir>` on .58 (rootless podman,
  `--cgroup-parent=nomad.slice`, 16 threads).
