# Web windows: THE window architecture (Android + Linux, desktop mode)

Status: **design, 2026-10-30.** Docs only; no code changed with this note. Phone: OnePlus Open CPH2551,
SM8550, SDK 36, OxygenOS 16.

The user, 2026-10-30: **"the whole way we integrate windows is still hacky, it needs to be handled properly fully
inside the PowOS web UI"**, and **"native window handling so that we get as little latency between the real window and
the HTML rendering of it, ideally zero copy, and native window movement and native window rendering so tooltips and
other windows render like they would in Plasma."**

Manager spec (mail 63bf5ca241b5 W1-W3, b3b13ff3dc85 Z1-Z4): home's TypeScript owns every window, for Android and Linux
apps. Each window is a DOM element (page, position, size, z-order, PowOS title bar). Its content is the app's own
buffer, which the **system compositor (SurfaceFlinger)** composites as a child surface placed at that element.

| | hard constraint | where this note meets it |
|---|---|---|
| Z1 | zero copy: the app's own buffer composited at its DOM element, frame-synced, ready in the frame the app commits | §1, §2 |
| Z2 | native move/resize: one transaction per frame, the content is never re-rendered, DOM chrome moves in the same frame | §2 |
| Z3 | popups/menus/tooltips/transients are their own surfaces, not clipped to the parent, above it, below PowOS system UI | §3.2 |
| Z4 | input goes straight to the surface, never re-injected by JS, IME on the real window | §3.1 |

**What this note replaces.** It replaces the window integration in desktop mode: the overlay/task-surface path
(§0.2) and, for windows, the KWin-composites-everything plan of `docs/DESKTOP-KWIN-NATIVE.md` (decided 2026-10-28).
KWin stays the Wayland/X server and window logic for Linux clients (focus, xdg protocol, popup placement, Xwayland). It
becomes a **producer of one buffer per toplevel**. It no longer composites the screen that the user sees. **Open
decision for the manager:** confirm that this overrides DESKTOP-KWIN-NATIVE.md §5 phases 1-5. Folded mode is out of
scope here, and `powos_desktop_mode` stays as it is (unchanged).

---

## 0. What exists (verified in code, worktree base `debd259f`)

### 0.1 Web windows v0 (ee5f776d, behind `Settings.Global powos_web_windows`, default 0)

- `shell/ui/webwindows.tsx`. `webWins` signal, listed bottom first (`:28-29`). `openWebWindow` runs only on the wide home
  for `a:` (Android) keys (`:45-57`) and is called from `state.ts:411-415`. Windows render inside their page's element
  (`grid.tsx:1183`, `WebWindowsOn`), so they slide with the page. The title bar drag goes through DOM state
  (`:131-171`). z = `20 + index` (`:203-218`).
- Geometry: each element runs a rAF loop that sends its body rect over the **async `call` bridge** whenever the rect
  changes (`:90-115` → `bridge.ts:283` → `ShellBridge.kt:244`). This is **not frame-synced**.
- `WebWindows.kt`: one `VirtualDisplay` per window (`:220-221`, flags `PUBLIC|OWN_CONTENT_ONLY|DESTROY_CONTENT_ON_REMOVAL`,
  `:336-337`). Its output surface belongs to a **`SurfaceView` added behind the home WebView** (`:117`), and the DOM body
  is an unpainted hole. `place()` sets `view.x/y` and calls `display.resize(w,h,dpi)` on every size change
  (`:127-153`). Launch: `ActivityOptions.setLaunchDisplayId`, falling back to root `am start --display` (`:249-266`).
- Input v0: the DOM `Body` forwards pointer events from JS (`webwindows.tsx:173-201`) to `input()`. That calls
  `InputManager.injectInputEvent` through reflection and falls back to **root `input` with one process per event**
  (`WebWindows.kt:164-188, 303-323`). PowOS does not hold INJECT_EVENTS (`EdgeGestures.kt:49-51`), so expect the root
  path. Only single-pointer events are sent: `MotionEvent.obtain` with one pointer, `:174`.
- IME v0: `setDisplayImePolicy(displayId, FALLBACK_DISPLAY)` through reflection (`:269-277`). The result is logged and
  not yet confirmed on the device.
- Known HACKs in the class note (`:48-53`): input is coarse; z-order has only two levels (`setZOrderMediaOverlay`,
  `:156-160`); there is no "closed" signal when the app finishes its own task.
- Linux apps are not supported in v0.

### 0.2 The overlay / task-surface path (frozen per W1; retired after §4 passes)

- `WindowFrames.kt`: PowOS title bars are `TYPE_APPLICATION_OVERLAY` windows over Android freeform tasks (`:25, :58`),
  kept on the task by a task-stack listener.
- `FreeformTasks.kt`: reflected `resizeTask` and the task-stack listener (`:9-12`). Off-page windows are hidden in WM
  through `away()` → `TaskLeash.setHidden` and are not focusable (`:282-296`; `TaskLeash.kt:349-363`;
  `PageSlide.kt:368`).
- `TaskSurfaces.kt`: task leashes taken from WM Shell transitions, hidden and shown per page (`:26-70`).
- Linux floating windows run as `PowosWindowActivity` tasks plus kwin patches 0013-0039
  (`targets/android/docs/powos-window-tasks.md`).
- This path has two window worlds (WM for Android tasks, our DOM for chrome), and the bug classes come from that.
  Examples: off-page minimising (the Broforce incident on 10-30, mail f3753779ed30), title bars drifting, popups
  confined to tasks.

### 0.3 Native glass: the frame-sync mechanism to reuse

- The page measures its regions and tags each set with a frame id: `b.f <id> <regions>` over the native port
  (`nativeglass.ts:494-503`).
- The host waits for `WebView.postVisualStateCallback(id)`, which fires once the next draw contains that DOM state. It
  then puts the transaction on that draw with `AttachedSurfaceControl.applyTransactionOnDraw`
  (`GlassBlur.kt:270-322, 410-424`).
- Result: the compositor-side change and the page's pixels land on the same frame.

### 0.4 Linux toplevels reaching Android today

- The display daemon (`engine/native/andromarchy/andromarchy.c`) pairs one consumer with one producer per **surface id**.
- The Android side **dequeues gralloc buffers from an Android `Surface`, dups their dmabuf fds and sends them to KWin**
  (`native_consumer.c:114-170`, `collect_dmabufs`). KWin renders into those buffers and Android queues them.
- `PowosWindowActivity` gives its `SurfaceView` surface to `Native.nativeStartWindow(surface, id, bufW, bufH)`
  (`PowosWindowActivity.java:481`).
- Buffers can be larger than the window, and `nativeSetWindowCrop` shows only part of them. This allows a live resize
  without allocating new buffers (`Native.java:40-48`).
- Touch and keys go to KWin natively, never through JS: `nativeSendWindowTouch/TouchFrame/Key`
  (`PowosWindowActivity.java:611-656`). KWin delivers them to the surface under the point
  (`SeatInterface::notifyTouchDown`, powos-window-tasks.md).
- KWin side, kwin 0013 `AnlandWindowTask` (`anland_window_task.cpp`):
  - Renders the window **and its popups** into the offered buffer with `ItemRenderer::renderItem` (patch line ~686).
  - Sends `framePainted` (~700).
  - Keeps rendering while offscreen through `refOffscreenRendering` (~486).
  - Moves exported windows to a hidden "Android tasks" desktop, so the KDE desktop neither paints them nor sends them input.
- kwin 0027 confines popups to the task area (`Workspace::setPopupAreaHandler`).
- The control channel is `WindowTasks.java:19-27`: `open/close/title/decor/move` from KWin, `closed/focus/hello` to it.
- Text input: `SystemIME.java` (a 1x1 EditText whose ForwardingInputConnection sends text to KWin) plus kwin
  0010/0012/0016 (the Android keyboard follows text focus).
- `sources/powos-shell/src/desktops.cpp` maps KWin's VirtualDesktopManager over D-Bus (`:11-37`). That is the
  powos-shell (KWin desktop) host and is **not on this path**.

**Key reuse:** the Linux producer already writes one toplevel into Android-owned buffers with no CPU copy. Web
windows only change *whose* Surface that is: a child of home's surface instead of an activity's own.

---

## 1. Surfaces in

All window content becomes **`SurfaceControl` children of home's window surface**. Nothing is a View.

**Tree.** For each window, a bufferless *container* SurfaceControl hangs under home's root, created with the public
`SurfaceControl.Builder().setParent(...)` and parented through `View.getRootSurfaceControl()`/`buildReparentTransaction`
(public, API 33). Under each container:
- a *content* SC, cropped to the DOM body;
- one SC per popup (§3.2), without that crop.

Content sits below home's own buffer (negative layer, the same way SurfaceView does it), so DOM painted over a window
covers it. The hole stays unpainted.

### 1.1 Android apps (one VirtualDisplay per window)

| step | status | API |
|---|---|---|
| VD per window, app launched on it | **exists** (`WebWindows.kt:220, 249-266`) | `DisplayManager.createVirtualDisplay`, `ActivityOptions.setLaunchDisplayId` |
| VD output = `Surface(contentSc)` instead of a SurfaceView | missing (S1) | `Surface(SurfaceControl)` (public, API 29) |
| **Zero copy:** show the VD's own layer tree, not its composited output. A mirror of the display reparented under the container: SurfaceFlinger then composites the **app's own buffers** at the element, in the same frame the app commits | missing (S3) | `IWindowManager.mirrorDisplay(displayId, outSc)`, hidden, checks READ_FRAME_BUFFER. PowOS holds that permission through the recents role (`AndroidManifest.xml:44`) and already uses its sibling `mirrorWallpaperSurface` the same way (`WallpaperBackdrop.kt:15-27, 172-177`) |
| 120 Hz on the VD | missing | `VirtualDisplayConfig.Builder.setRequestedRefreshRate` (API 34) |
| closing when the app finishes its own task | missing (`WebWindows.kt:52-53`) | task-stack listener on the VD ids (FreeformTasks already registers one) |

Without the mirror (S1-S2), SurfaceFlinger composites the app into the VD's buffer (one GPU pass) and that buffer is
latched in the next frame. That costs one GPU copy plus up to one frame. S3 removes both. **Unknown U1:** whether
apps keep drawing on a VD whose output surface is null or tiny while it is mirrored. AOSP ties the VD's display state
to having a surface. See R1 for the de-risk and fallback.

### 1.2 Linux apps (one buffer per toplevel from KWin)

| step | status | API |
|---|---|---|
| KWin renders one toplevel into Android gralloc buffers (dmabuf fds over the daemon socket) | **exists** (kwin 0013, `native_consumer.c:114-170`) | anland protocol |
| consumer Surface = `Surface(contentSc)` under home, not `PowosWindowActivity` | missing (S6) | `Native.nativeStartWindow(Surface(contentSc), id, screenW, screenH)` unchanged |
| KWin told the window is a **web window**: client area only (PowOS title bar), popups not confined (0027 off for it), popups exported separately (§3.2) | missing (S6/S7) | new control word `web <id> 1` in `caps`/`open` (WindowTasks protocol) |
| client's own dmabuf handed straight to SurfaceFlinger (true passthrough) | **research, not in the slice** | no public dmabuf→AHardwareBuffer import (`AHardwareBuffer_createFromHandle` is LL-NDK/vendor only; libui `GraphicBuffer` is private, and its handle layout is specific to QTI gralloc). Unknown U5 |

**Honest Z1 status for Linux.** KWin does one GPU render pass of the client's buffer into the Android buffer, with no
CPU copy. Plasma pays the same one composite per window when it draws a window to its output. SurfaceFlinger then
places that buffer (as an HWC overlay or through GPU composition). Latency: client commit → KWin render (~1-2 ms GPU)
→ queue → SurfaceFlinger latches it in the next vsync. That matches Plasma, but it is not literally "the app's own
buffer". Full passthrough is S10 (research).

---

## 2. Geometry, clip and z-order from the DOM, frame-synced (Z1, Z2)

One packet per page frame, on the same channel and with the same binding as the glass. **The async `call` bridge is
no longer used for geometry:**

```
page:  w.f <frameId> <id> <x> <y> <w> <h> <radius> <visible> <z> [<id> ...]     (screen px, after transforms)
host:  postVisualStateCallback(frameId) -> one SurfaceControl.Transaction -> root.applyTransactionOnDraw(t)
       per window: setPosition(container), setCrop(content, body), setCornerRadius, setVisibility, setLayer(z)
```

- **Same transaction as the glass.** When both change on one frame, glass regions and window geometry go in one `b.f`
  + `w.f` callback, so they cannot be a frame apart. GlassBlur's frame id / "newest wins" logic (`GlassBlur.kt:270-322`)
  is shared: either extract it into one `FrameSync` helper or make the packet one message.
- **Z2, drag and resize.** The title-bar drag updates DOM state, and the next frame carries the new rect. The content
  is never redrawn; only `setPosition` changes. The chrome and the surface move in the same composited frame because
  both ride the draw that shows that DOM state.
- **Clip.** The body rect is clipped by its page element and the screen (a page sliding off the edge). SurfaceFlinger's
  `setCrop` handles rectangles and `setCornerRadius` handles the corners (both in the verified list in NATIVE-GLASS.md
  "Evidence").
- **Z-order = DOM order.**
  - `webWins` order maps to `setLayer` on the containers. All of them sit under home's buffer, so every DOM element in
    home (drawer, panels, AI pill) is above every window.
  - PowOS system UI windows (status bar, shade, launcher overlay, Quick Tools, IME) are separate windows above home and
    are therefore always above.
  - One case DOM cannot express by itself is a lower window's DOM chrome showing through a higher window's
    transparent body. For that, the page gives each window's chrome a `clip-path` that excludes the bodies of windows
    above it. This is computed from the same rects, in the same frame.
  - This removes the two-level `setZOrderMediaOverlay` HACK (`WebWindows.kt:156-160`).
- **Off page = not visible.** The window's page is not on screen, so its surface gets `setVisibility(false)`. The app
  keeps its buffers, and there is no WM minimise/`setHidden`, so the Broforce class of bugs cannot happen. Input is
  routed only to visible bodies (§3.1), so a swipe where a hidden window sat goes to the page.

---

## 3. Input, IME, child surfaces, resize, pages, maximise

### 3.1 Input and IME (Z4)

**Input is intercepted natively in home, before the WebView sees it.**
- `ShellActivity` (or a FrameLayout wrapping the WebView) checks each `ACTION_DOWN` against the *hit regions*: the
  visible body rects from the last applied `w.f`, minus the chrome clip.
- A down inside a body belongs to that window for the whole gesture, including every pointer (multi-touch), and the
  WebView never gets it. JS sends nothing, and the `Body` pointer handlers (`webwindows.tsx:173-201`) are deleted.
- Raise and focus are reported to the page as an event (`webwindows.focus <id>`), and the page reorders `webWins`.

| | touch / mouse / stylus | hardware keys | IME |
|---|---|---|---|
| Android | the whole MotionEvent (all pointers, history), offset to the body and `setDisplayId(vd)`, sent to a **root-side injector**: a persistent `app_process` helper running as shell/root that holds INJECT_EVENTS (the scrcpy/Shizuku pattern), reached over a local socket. Root `input` per event is removed | `KeyEvent` to the focused window's VD through the same injector | `setDisplayImePolicy(vd, FALLBACK_DISPLAY)` (exists, `WebWindows.kt:269-277`): the phone's real keyboard serves the app's own InputConnection on its VD, so it is the real window's IME (as in DeX). Unknown U3: does the top-focused display follow the injected touch? |
| Linux | `Native.nativeSendWindowTouch/TouchFrame` to KWin (exists, `PowosWindowActivity.java:611-641`). KWin delivers to the surface or popup under the point | `nativeSendWindowKey` (`:656`) | `SystemIME` hosted by home for the focused Linux web window. KWin's text-input focus shows and hides it (kwin 0010/0012/0016), exactly as in `PowosWindowActivity` today |

**Linux IME and full screen as built (kwin 0043, pkg 3.50).** KWin's caps add `window-ime` and `fullscreen-request`.
When a web window's consumer is up, the app sends `ime <id> 1`. From then on, KWin sends `OUTPUT_TYPE_KEYBOARD` for
the active window (or its dialog) to that task's own connection instead of surface 0, and it takes
`INPUT_TYPE_TEXT_INPUT` there (InputMethod::commitText). The window consumer's event thread
(native_consumer.c `window_events`) calls `WebWindowSource.nativeKeyboard(handle, visible)`. Home then hosts one
`SystemIME` with a sink bound to that handle (`hostIme`, from ShellBridge), so the text goes to KWin for that toplevel.
An older KWin sends no cap, so the app sends no `ime` and the desktop path stays. An older app never sends `ime`, so
KWin keeps the desktop path. The full-screen button sends `fullscreen <id> 1`; KWin calls `setFullScreen`, and its
`fullscreen <id> 1|0` confirms or reverts the window. The host lays the container over the whole screen, with no bar.
"Back to window" (`toWindow`) or the app's own F11/Esc brings the window back.

Keyboard cover: when the IME's inset covers the focused body, the page lifts that window above the inset, and the
lift is ordinary geometry in `w.f`. Plasma does not do this, but on a phone it is needed.

### 3.2 Child surfaces: popups, menus, tooltips, transients (Z3)

- **Linux** (new KWin work, S7). For a web window, KWin stops rendering popups into the toplevel's buffer and stops
  confining them (0027 off). Each `xdg_popup`, and each Xwayland override-redirect window whose transient-for or
  pointer parent is a web window, is exported as **its own surface id**: `popup <id> <parent> <x> <y> <w> <h>`, with
  coordinates relative to the parent's client area.
  - Android places a popup SC under the parent's **container**, not under its content. It is therefore not cut by the
    parent's crop, follows every move of the parent in the same transaction, and uses a **positive** layer, above
    home's buffer. This matches Plasma, where popups sit above all normal windows.
  - Popups stay below every PowOS system UI window. While home opens an in-DOM overlay, such as a panel, it hides
    popups, and they also close because focus leaves.
  - Placement stays KWin's (xdg_positioner flipping and sliding against the **screen** area, as in Plasma).
  - **Transient toplevels** (dialogs, Dolphin's Properties) become **web windows of their own**: DOM chrome, movable,
    grouped in z just above their parent.
- **Android.** `PopupWindow`s, menus and dialogs are windows on the app's own VD and therefore inside its bounds. This
  is Android's own freeform/DeX behaviour, and it is a **known limitation**: Z3 holds for Linux apps, but Android
  popups cannot go beyond their window. Lifting them out would mean mirroring individual window layers of the VD and
  then routing their input, which is unknown and not in the slice.

### 3.3 Resize = the app's real resolution

- **Android:** `VirtualDisplay.resize(w, h, densityDpi)` with the device's dpi, so the app lays out at its real pixel
  size (as `:143` does). During a drag, at most one resize is outstanding. The crop follows the DOM every frame,
  showing the last frame anchored top-left on the window background until the app draws at the new size. This is
  KWin's behaviour in Plasma.
- **Linux:** buffers are allocated at screen size once, and `nativeSetWindowCrop` follows the window (`Native.java:43-47`).
  KWin `moveResize`s the client (kwin 0018/0032), so a live resize allocates nothing.

### 3.4 Pages = desktops, maximise → full screen

- **Pages.**
  - `WebWin.page` (`webwindows.tsx:20`) is the only source of truth. A window renders inside its page element and
    moves with the swipe, and the surface follows through `w.f`.
  - Off page = `setVisibility(false)` (§2). The app is not paused, and KWin stops frame callbacks
    (`unrefOffscreenRendering`) for a Linux window that is not shown.
  - Persisting the page across a home restart: windows are re-adopted from the VD list and KWin's `session` message
    (WindowTasks.java). Detail for S8.
- **Maximise.** The element fills its page minus the status bar, and the chrome becomes an auto-hiding strip. The
  content is resized to that size (§3.3). An app's own full-screen request (Linux: `open ... fullscreen` / xdg
  `set_fullscreen`; Android: immersive on its VD) makes the element cover the whole screen. **Unknown U4:** whether an
  Android app's immersive request on a VD is observable (no system bars there). The fallback is a title-bar
  full-screen button.

---

## 4. First slice (W3): Chrome (Android) + Dolphin (Linux), behind `powos_web_windows`

Order: de-risk first, then build. Each step is checked on the phone (unfolded, flag on), with a screenshot or trace
as evidence. The estimates are agent working time plus the coordinator's build and deploy.

| # | step | acceptance test on the phone | size |
|---|---|---|---|
| S0 | **De-risk spikes** (throwaway, not landed): (a) U1, mirror a VD under home and check whether Chrome keeps drawing with a null or 1x1 VD surface; (b) U2, a root `app_process` injector, measuring `inject → dispatch` latency and multi-touch; (c) U3, the IME on the VD with FALLBACK policy; (d) the glass-stall bisect (R6). | (a) `dumpsys SurfaceFlinger --list` shows a mirror of Chrome's layer under home and the page scrolls; (b) p95 < 2 ms in `dumpsys input` timestamps, pinch zoom works; (c) tapping the URL bar opens the OnePlus keyboard and text appears in Chrome; (d) stalls are present or absent with the glass off | 1 day total; each result decides a fallback (R1-R3, R6) |
| S1 | Surfaces as SC children of home (container + content, `Surface(contentSc)` for the VD), replacing the SurfaceView | Chrome opens in a web window; SF list shows `powos-ww-<id>` under home's layer; the drawer opened over it covers it | ~150 lines Kotlin, 0.5 day |
| S2 | `w.f` frame-synced geometry, shared with the glass's FrameSync: crop, radius, visibility, z = DOM order, chrome clip-path | Fast title-bar drag recorded with `screenrecord` at 120 Hz: on every frame, chrome and content are in the same place (step through the frames). Two overlapping windows: raising either one stacks it correctly, title bars included. A Perfetto async slice "ww f<id>" ends on the same vsync as the draw | ~250 lines (Kotlin + TS), 1 day |
| S3 | Zero copy for Android: `mirrorDisplay` under the container (if S0a passes). If it fails, keep S1 and record the Z1 gap in this note | `dumpsys SurfaceFlinger`: the virtual display does no composition per frame, and Chrome's own buffer layer is composited at the element. A tap-to-pixel camera test at 240 fps, compared with Chrome full screen: ≤ 1 frame apart | ~120 lines, 0.5-1 day |
| S4 | Native input: intercept in home, hit regions from `w.f`, the injector (Android), the existing Native calls (Linux); keys; JS forwarding deleted | Chrome: smooth fling scroll, long-press text selection, pinch zoom. A touch on a chrome-covered part of the body goes to the chrome. No `input` processes in `ps` | ~300 lines + helper ~150, 1-1.5 days |
| S5 | IME: Chrome through FALLBACK policy; Linux through home-hosted SystemIME; lift above the keyboard | Type a URL in Chrome and a filename in Dolphin (F2 rename) with the phone keyboard; the focused window is not covered by the IME | ~150 lines, 0.5-1 day |
| S6 | Dolphin as a web window: `web` control word, KWin client-area export into home's content SC, launched from the launcher when the flag is on | Dolphin opens on the current page with the PowOS title bar, moves, live-resizes (no reallocation), and closes from the title bar (KWin gets `closed`) | ~300 lines app + ~150 KWin patch, 1.5-2 days |
| S7 | Z3 for Linux: popups exported as their own surfaces above home's buffer, 0027 off for web windows, transients as their own web windows | Dolphin's hamburger menu, opened near the window's bottom edge, extends **past** the window and is not clipped. A tooltip over another window. File > Properties opens as its own movable window above Dolphin | ~400 lines KWin + ~150 app, 2-3 days, **riskiest** |
| S8 | Resize = real resolution, maximise → full screen, page pinning + re-adoption | Resize Chrome to 800x600: `dumpsys display` shows the VD at 800x600 and Chrome re-lays out. Maximise: no chrome, fills the page. Swipe away and back: the window is there at once, no reload, no minimise | ~200 lines, 1 day |
| S9 | Shown to the user on the phone, then default-on; then retire §0.2 step by step (each removal checked: folded Linux tasks still open, type and close) | the user's OK on the rendered phone | follow-up |
| S10 | (research) Linux client-buffer passthrough (U5) | — | unknown; not in the slice |

Total S0-S8: about **9-12 working days** of agent time. S7 and S0's unknowns carry the most variance. S1-S5 make
Chrome usable alone, so the user can see Chrome as a web window after about 4-5 days, before Dolphin.

---

## 5. Risks and unknowns (each with how to de-risk it first)

| # | risk / unknown | de-risk first | fallback |
|---|---|---|---|
| R1 / U1 | **A mirrored VD may stop drawing** without a real output surface (AOSP ties a VD's display state to its surface). `mirrorDisplay`'s permission check is unverified on OxygenOS (it was seen for `mirrorWallpaperSurface` only) | S0a: 1-2 h spike, logs + SF dump | keep an output surface at the window size (one SF pass per frame, S1 path); try a surface that is never latched (an ImageReader with `maxImages` 1 and no reads) to stop SF composing; else accept the copy and report the gap |
| R2 / U2 | **No INJECT_EVENTS** for an app (it is signature level, so a privapp allow-list does not grant it, contrary to the `WebWindows.kt:48-49` note). Without it Android touches cannot reach a VD | S0b: root `app_process` helper (as scrcpy does), measuring latency and checking that SELinux allows it from Magisk's `su` context | a platform-signed system module in the PowOS image; until then the helper |
| R3 / U3 | IME focus on an untrusted VD: phones do not have per-display focus (`config_perDisplayFocusEnabled` false), so does the injected touch move the top focused display to the VD, and does the IME bind to the app's editor? | S0c: tap Chrome's URL bar with the flag on and read the logged "IME policy" line plus `dumpsys input_method` | create a trusted VD (`VIRTUAL_DISPLAY_FLAG_TRUSTED`, which needs ADD_TRUSTED_DISPLAY) from the root helper, which also gives system decorations and IME on the VD |
| R4 | Hidden APIs and OEM changes: `mirrorDisplay` and the BlurRegion precedent (OxygenOS has 31 floats where AOSP has 10, `GlassBlur.kt:28-34`) | probe each hidden call once at start through `HiddenApi`, logging and falling back as GlassBlur does | the SurfaceView/S1 path, which uses public APIs only |
| R5 | SELinux / sandbox: dmabuf fds from the chroot already cross today (anland); the root injector and any trusted VD are new | S0b runs under the real enforcing policy | Magisk sepolicy rule in the image, declared in the unit registry (no unmanaged system deps) |
| R6 | **Frame-sync stalls:** home shows 160-340 ms stalls (mail 9e58153c0442, 348e1db90c23), suspected to be either `applyTransactionOnDraw`/visual-state waits or ART JIT after an install. Web windows lean on the same mechanism, and a stall would freeze window moves | S0d: the bisect with the glass flag off, plus a Perfetto trace of `glass f<id>` receipt→apply | apply geometry right away (`t.apply()`) while a visual-state callback is late (> 1 vsync): chrome and content may be up to a frame apart, but nothing freezes |
| R7 | Apps on VDs: FLAG_SECURE content is blank on a non-secure VD; some apps refuse a secondary display (DESKTOP-KWIN-NATIVE.md §3). Chrome is resizable and expected to work | the slice uses Chrome; a list of apps tried, logged as they are found | secure VD from the root helper; otherwise the app opens full screen on the phone's own display |
| R8 | Android popups stay inside their window (§3.2): Z3 is only partly met for Android | none in the slice; stated plainly to the user | research: per-layer mirrors of the VD's popup windows |
| R9 / U5 | Linux zero copy is one KWin GPU pass, not passthrough (§1.2) | S10 spike: wrap a client dmabuf as a gralloc buffer on QTI (private handle layout) | stays at the one-pass path, which is Plasma-equivalent |
| R10 | HWC overlay planes are limited (SM8550 count unknown). Beyond them SF falls back to GPU composition: no extra app copy, but more GPU and power | `dumpsys SurfaceFlinger` composition types with 1/3/6 windows | none needed for correctness; measure power |
| R11 | Architecture conflict with DESKTOP-KWIN-NATIVE.md (KWin composites in desktop mode). Two plans in flight would double the window code | the manager confirms this note supersedes it for windows | — |
| R12 | Memory: one VD per Android window plus screen-sized Linux buffers (about 22 MB each at 2268x2440 RGBA, times 3) | PSS with 4 windows open | Linux buffers sized to the window plus a margin, reallocated past it |

---

## S0 results (measured)

Measured 2026-10-30 on the OnePlus Open (SDK 36, SELinux enforcing), spike code in
`targets/android/spikes/webwindows-s0/` (`S0.java`, `build.sh`, `run.sh`; runs as `shell` through `app_process`).
Setup: Chrome on a 720x800 VD **A**; a second VD **B** (output = ImageReader) stands in for home's display; a root
container layer on B's layer stack stands in for home's window. Under it: the **mirror** of A
(`IWindowManager.mirrorDisplay`, x=0) and a **copy** layer whose `Surface(sc)` is A's output (x=800, the S1 path). The
page paints its rAF counter as 8 black/white blocks, so every B frame says which Chrome frame each path shows.
Note: most runs had the phone's own screen off (dozing). A VD in the default display group follows display 0 to
OFF, so those runs added `TRUSTED|OWN_DISPLAY_GROUP|ALWAYS_UNLOCKED` (`0x1c00`, shell may set them) to A and B.

Cleanup note (2026-10-30): the S0 runs opened the test page (`http://127.0.0.1:8765/`) as an ordinary Chrome tab,
and that tab stayed in the user's Chrome ("This site can't be reached"). S0.java now opens the page as a session-less
Custom Tab: it has its own task, the task ends with display A, and the page never enters Chrome's tab list. This is
not yet verified on the phone. Every spike must close what it opens. P1 (S1) launches nothing.

### (a) Mirror (U1 / R1)

- `mirrorDisplay(A)` **works as shell** (READ_FRAME_BUFFER) and returns a `MirrorRoot` layer; reparented under the host
  it shows Chrome's live content (`dumpsys SurfaceFlinger --list`: `MirrorRoot#2441 parentId=<s0-host>`). It returns
  `false` if called before WM has added the display (~100 ms after `createVirtualDisplay`): wait for
  `dumpsys window displays` / a display listener first.
- **Latency** (A surface on, 10.2 s, Chrome 59.6 frames/s, SF at 120 Hz → B composed 1125 times): the mirror shows each
  Chrome frame in the **same composition** in which SF composites it into A; the copy shows it **one composition
  later** (lag histogram mirror−copy: `{0: 519, 1: 606}` B frames, never more than 1). So S1 costs one SF frame
  (8.3 ms at 120 Hz) plus one GPU pass; the mirror removes both.
- **Extra copy:** while A has any output surface, SF composites A with **client (GPU) composition every frame**
  (`usesClientComposition=true` in the A section of `dumpsys SurfaceFlinger`), mirrored or not. A also carries
  display 0's colour transform (`colorTransformMatrix` diag `1, .923, .788`, night light), so the S1 copy path gets
  night light applied **twice** (once into A's buffer, again on display 0). The mirror path does not.
- **Output surface and lifecycle** (Chrome frames per second seen through the mirror):

  | A's output | display A state | Chrome | frames/s via mirror |
  |---|---|---|---|
  | `Surface(copy)` shown | ON | RESUMED, visible | 59.6 |
  | `setSurface(null)` | **OFF** | **STOPPED**, `mVisible=false` within ~40 ms (last mirror frame 42 ms later); still STOPPED after 65 s | 0 |
  | unread ImageReader, `maxImages` 1 | ON | RESUMED | 59.3 (SF still GPU-composites A, into a buffer nobody reads) |
  | 1x1 ImageReader (read) | ON | RESUMED | 59.8 (the GPU pass now writes 1 pixel) |
  | `Surface(copy)`, copy layer **hidden** | ON | RESUMED | 59.8 |
  | copy shown, **mirror hidden** | ON | RESUMED | copy 59.7 |

  So the AOSP tie is real: **null surface = display OFF = app stopped.** Hiding the layer that shows A's output does not
  stop anything; only the VD's surface (and its display group's power state) matters.
- **Untrusted VD + Chrome's launcher intent lands on display 0.** With the WebWindows.kt flags
  (`PUBLIC|OWN_CONTENT_ONLY|DESTROY_CONTENT_ON_REMOVAL`, untrusted), `am start --display A ... com.android.chrome`
  started `ChromeLauncherActivity` on A, and its trampoline then put `ChromeTabbedActivity` (task) on **display 0**
  (seen twice: screen off and screen on). With the trusted own-group flags it stayed on A. Not yet split into which
  flag fixes it, nor tried with `setLaunchDisplayId` + the explicit component.
- `DESTROY_CONTENT_ON_REMOVAL` finishes Chrome's activity when A is released but **leaves its task in recents**:
  the window close path must also remove the task (`removeTask`).

### (c) Keyboard (U3 / R3)

Trusted own-group VD A, `setDisplayImePolicy(A, FALLBACK_DISPLAY)` (accepted from shell), one `input -d A tap` on the
page's text field:
- WM **moved the top focused display to A** (`mTopFocusedDisplayId=26`, `imeInputTarget in display# 26 ChromeTabbedActivity`):
  a touch on the VD takes global focus even without per-display focus.
- The IME **bound to Chrome** (`mCurClient ... mUid=10194 (Chrome) mSelfReportedDisplayId=26`) and **showed on
  display 0** (`mCurTokenDisplayId=0`, `mInputShown=true`, the `InputMethod` window `mDisplayId=0 isVisibleRequested=true`).
- A tap that misses an editor still moves focus to A but shows no IME; the IME client stays Chrome.
- After A was released, focus went back to display 0 (`mTopFocusedDisplayId=0`, `mInputShown=false`).
- Not measured: text committed by the IME into Chrome (that needs a touch on the keyboard on the user's display), the
  untrusted VD (Chrome did not stay on it, see above), and LOCAL policy.

### What it means for S1-S3, S5

- **S1:** `Surface(contentSc)` as the VD output works and keeps the app resumed even when that layer is hidden. Never set
  the VD's surface to null for a minimised/hidden window (it stops the app); hide the layer instead. The copy path is
  one frame late and double-applies night light. Wait for WM to know the VD before launching or mirroring. Check that
  Chrome actually lands on the VD with the production flags; if not, the VD must be trusted (needs
  ADD_TRUSTED_DISPLAY, which shell has: create it from the root/shell helper of S4) or Chrome launched by component.
  Remove the task on close.
- **S2:** unchanged; geometry on the mirror/content layer is ordinary SC transactions (crop/position worked).
- **S3: passes.** `mirrorDisplay` gives zero-latency content (same composition as the app's commit). For the remaining
  GPU pass on A, give A a **1x1 ImageReader** surface once the mirror is in place: display stays ON, Chrome stays at 60
  frames/s, and SF's per-frame A composition shrinks to 1 pixel (still one tiny client composition; A's size must then
  come from `VirtualDisplay.resize`, not the surface). Not yet checked through `mirrorDisplay` from the PowOS app's own
  uid (recents role) rather than shell, and with home's real window as parent.
- **S5:** FALLBACK works as designed: tap on the VD → top focus moves to the VD → the phone keyboard on display 0 serves
  Chrome's editor. S5 must handle the focus side effect: while a web window has focus, home (display 0) is not the
  top focused display, so home's own inputs/IME need focus handed back (a tap on home's area does that today).

---

## S1-S3 (built 2026-10-30, behind `powos_web_windows`, not yet run on the phone)

### Probe results (measured, `targets/android/spikes/webwindows-s1/P1.java`, run as the real uids under Magisk `su <uid>`)

| question | result |
|---|---|
| `mirrorDisplay` from **PowOS's uid** (10359, READ_FRAME_BUFFER granted) | **works**: `true`, valid layer, reparented under a PowOS-made SurfaceControl. Also on a VD that **another uid** (shell) created. Returned `false` for the first ~20-90 ms (one retry) |
| VD flags PowOS's uid may set | `PUBLIC\|OWN_CONTENT_ONLY\|DESTROY_CONTENT_ON_REMOVAL` ok; `+TRUSTED` → `SecurityException: Requires ADD_TRUSTED_DISPLAY permission to create a trusted virtual display`; `+OWN_DISPLAY_GROUP` → `Requires ADD_TRUSTED_DISPLAY ... not in the default DisplayGroup`; `+ALWAYS_UNLOCKED` accepted. ADD_TRUSTED_DISPLAY is `signature\|role` on this phone (no privapp allow-list can grant it); shell (2000) has it |
| why Chrome escaped to display 0 | `ActivityManager.isActivityStartAllowedOnDisplay` (the same `canPlaceEntityOnDisplay` ActivityStarter uses before moving a launch to the default display): on an **untrusted** VD owned by PowOS, PowOS's uid → `true` for any Chrome activity, **Chrome's uid → `false`** (its trampoline `ChromeLauncherActivity` → `ChromeTabbedActivity` is Chrome's own launch). On a **TRUSTED** VD (shell-made, `0x409` or `0x509`) Chrome's uid → `true`, PowOS's → `true` |
| the minimal fix | **TRUSTED alone** (`1<<10`). OWN_DISPLAY_GROUP / ALWAYS_UNLOCKED are not needed (the S0 runs needed them only because the screen was off). Launching by component would not do it: every later launch Chrome makes itself (a new window, its settings) would still escape |

### What was built

- `WebWindowsHost.kt`: a shell-uid helper (`su 2000 -c "CLASSPATH=<apk> app_process /system/bin dev.omalauncher.shell.WebWindowsHost"`,
  started at the first window, stdin/stdout line protocol). It creates each window's VD with
  `PUBLIC|OWN_CONTENT_ONLY|DESTROY_CONTENT_ON_REMOVAL|TRUSTED` and a **1x1 ImageReader** output (read and dropped), resizes it
  (`VirtualDisplay.resize`), releases it. Its stdin closing (home gone) releases everything. HACK: real fix is the
  platform-signed system module; the S4 injector will live in the same helper.
- `WebWindows.kt`: per window a container SC `powos-ww-<id>` under one `powos-webwindows` SC, a child of home's window
  surface (`buildReparentTransaction`) at layer -1 (below home's buffer, above the page's surface tiles at -2). The
  content is the VD's **mirror** (`mirrorDisplay` from the app, retried every 16 ms up to 2 s until WM knows the
  display); only then the app is launched on it. Container: position = DOM frame, crop = frame, corner radius, layer = DOM
  order, visibility; mirror: offset = body, crop = body. Hidden = layer hidden, never a null surface. Body size change →
  helper resize (coalesced). Close: tasks on the display removed (`getAllRootTaskInfosOnDisplay` + `removeTask`), then
  the VD released.
- Frame sync: `FrameSync.kt` is GlassBlur's `postVisualStateCallback` → `applyTransactionOnDraw` binding, extracted;
  GlassBlur and WebWindows both use it. One page frame id counter (`apps/port.ts nextFrameId`) for `b.f` and `w.f`, so
  both channels of one page frame ride the same draw.
- Page: `ui/webwindows.tsx` measures every window each frame while any exist and sends
  `w.f <frame> <dpr> <n> [<id> <frame x y w h> <body x y w h> <radius> <visible>]*n` (bottom first) when it changed.
  The async `webwindows.place` / `raise` bridge calls are gone. Input stays v0 (S4).

### The d41c991b rollback (2026-10-30 15:45)

The APK installed while a web window (Calculator, display 37) held the phone's top focus. The update killed home and
the old process, and with the process its helper, so display 37 went away
(`15:45:59.479 Changing focus from Window{... Calculator} to null,diplayid=37`). Android never ran
`startHomeOnDisplay` for display 0 again. There is none between 15:45:59 and the rollback at 15:48:23. Home never
started and the boot check timed out. The rollback booted because no web window existed by then. The app's own logs of
that run were lost (main log buffer 256 KiB, overwritten from 15:48), so no home crash can be ruled in or out from
logs. The system log shows home was never launched at all. Fix: `WebWindows.homeAfterRestart`, called at SystemUI's
connect (`PowosRecentsService.onInitialize`). With the flag on, it starts home on display 0 when no home task runs
4 s after the restart. It runs off the main thread and never starts a second home. Real fix (S5): hand the top focus
back to display 0 whenever a web window's display goes. The browser gate cannot catch this (no native host, no
displays).

### First phone test (2026-10-30 15:15) and fixes

Worked: helper ready, trusted display 35, mirrored after 27 ms from PowOS's uid, Chrome launched on display 35,
w.f followed drags. The user: "works but the old titlebars etc interfere", "when i try to move the window it moves the
whole page", and the widgets painted over Chrome's body.

- **One switch.** `AppWindows.floating()` is false while `powos_web_windows` = 1, as it is folded. That stands the whole
  old path down: freeform launch options, WindowFrames' overlay bars and grips (and adopting full-screen apps),
  TaskSurfaces' dressing, PageSlide/TaskLeash, PanelLift, and the host's window list, so `ui/desktops.ts` gets
  nothing either. `FreeformTasks.list` also skips tasks on other displays while the flag is on. With the flag at 0
  nothing changes.
- **Z-order (Z1 kept).** The window layer stays under home's buffer, where it is still the zero-copy mirror and every
  DOM element over it (its own title bar, the dock and bar, the drawer, panels, popovers) stays above it with no
  second layer. What was wrong was the page painting into the hole. The page element (`.page`) is now **masked over
  the window bodies** (`ui/webwindows.tsx pageMask`, CSS `mask-composite`). The holes are built bottom window up as
  H = (H ∩ not-title-bar(i)) ∪ body(i), so a higher window's title bar stays over a lower app. The page = all minus H.
  It is computed from the windows' state in the same render as their DOM, so it moves in the same frame as their
  `w.f`. The dock, bar, drawer and panels live outside `.page` and are never cut. The compositor glass leaves the
  bodies out as well (`GlassBlur.holes` + `WebWindows.bodies`): a blur region over a body would blur over the app.
  Rejected alternatives: windows above home's buffer, which needs a second top layer (another window or WebView) for
  the dock, chrome and popovers and adds a third sync path; per-window crop-outs, which a rectangle crop can't express
  for an L-shaped overlap.
- **Gestures.** `gesture.ts startGesture` never starts a home swipe or pull from inside `.webwindow`, and home.tsx
  reports every web window as a claim-free region to the host's pulls. Gate check: `desktops` scene →
  `webWindowCheck` drags the title bar and swipes the body sideways, asserts the page didn't turn, and asserts that a
  control swipe at the same spot without a window does turn it. Before the fix it failed with "turned the page (0 -> 1)".

---

## Element model (2026-10-30, branch ww-element)

The user, 2026-10-30: **"the whole way we integrate windows is still hacky, it needs to be handled properly fully
inside the powos web ui"** and **"The apps were supposed to be working directly in the webview."** Manager W1: position,
clip, z-order, page membership, transforms during swipes and animations, and hit-testing are decided by the web layer
every frame; shell elements sit above or below a window by DOM order; zero copy (Z1) stays. This section **replaces**
"Native frame and move" (windows above home, `WebWindowChrome.kt`, `HomeWebView.touchHook` taking the bar, the
invisible page model) and the native dividers, snap hint and tile menu of "Tiles" (`WebWindowTiles.kt`). What that
caused: windows did not follow page swipes, showed over the PowOS AI page, popups and menus over them got no taps,
the title bar's input was dead and full screen regressed.

### Design as built (the SurfaceView model)

| part | where | what |
|---|---|---|
| content layer | `WebWindows.kt root()` | `powos-webwindows` is a child of home's surface at layer **-1** (under home's buffer, as a SurfaceView); one container `powos-ww-<id>` per window, the Android VD mirror or the Linux content layer in it at 0,0 |
| per-frame measure | `ui/webwindows.tsx entry()/shown()/geometry()/tick()` | each rAF while windows exist: the **body element's** `getBoundingClientRect` (after every transform: page track, the `.screens` slide to PowOS AI, the drawer zoom, the window's scale), intersected with every ancestor that clips (overflow, and always its own `.page`: PS2) and the screen; visibility = non-empty clip, ancestors' opacity > 0.01, no full-screen overlay (`.folder-view.open`); alpha = the ancestors' opacity product; z = DOM order |
| message | same | `w.f <frame> <dpr> <n> [<id> <frame x y w h> <body x y w h> <clip l t r b> <radius> <visible> <alpha> <scale> <maximised> <titleEnd> <controls>]*n`, tagged with `nextFrameId()` (`apps/port.ts`), the glass's id counter |
| same draw | `WebWindows.frameCommand/apply` | `FrameSync` (postVisualStateCallback → `applyTransactionOnDraw`), the glass's binding: the layer and the page's pixels change in one draw |
| layer from geometry | `WebWindows.frameAt/place` | container at the body's place, `setScale` = the element's scale, crop = the clip in the body's own px (extended `radius` up under the bar so only the bottom corners round), `setAlpha`, `setLayer(z)`, visibility; mirror at 0,0 cropped to the body's size; a new body size resizes the display / KWin window (`resizeContent`) on every change: tile, divider let go, maximise, restore, resize |
| transparent body | `ui/shell.css` "Web windows" | the live body paints nothing; the page's own content is in `.page-under` (`grid.tsx`), masked over the page's windows, bar and body (`underWindows`); a lower window's element is masked over higher windows (`holes`) - otherwise DOM under the app's layer would paint over it, or show crisp through a bar's glass (the compositor blurs only what is under home's surface) |
| placeholder (LW1) | `Body` + `.ww-placeholder` | until `webwindows.live`: the theme's surface, the app's icon, a quiet progress line - never a hole. HACK: live = a task on the display (Linux: the consumer up) + 250 ms (`WebWindows.liveWhenDrawn`); real fix: the mirror's first-buffer callback |
| title bar | `TitleBar` | DOM, the widget glass (`.tile`: the same CSS fill/veil and compositor blur as the widgets, region = the bar strip only, so the old `blurs = false` HACK is gone with the native bar). Drag moves (clamped, DB1), double tap maximises, let go at a screen edge/corner tiles (24 px / 120 px) |
| buttons | `Controls` | tile (opens the DOM tile menu), minimise, full screen (`powos.webwindows.fullScreen`: moveTask to display 0, 82d7b688, unchanged in `WebWindows.fullScreen`), close |
| resize | `Edge` | 8 DOM grabs; the top edge stops at the status bar (DB1) |
| tile menu | `TileMenu` | DOM sheet over the window's body: it takes its taps by DOM order (gate-checked) |
| dividers | `DividerEl` | DOM handle; the drag moves the handle, let go: `snapRatio` or, within 12 % of an edge, the squeezed side to the dock - the same rules as before (`divided`) |
| merged bar | `TitleBar` merged + `barsOf` | maximised: the bar's middle is transparent, its title and controls glass pieces; the page sends `titleEnd`/`controls`, the host gives `ShadeHost.windowBars` the bar rects and merge, unchanged |
| glass under windows | `nativeglass.ts cutOut` | a blur region is shrunk off a window above it that spans a side, else dropped (HACK: one rounded rect per region) - a widget under a window never blurs the app |
| input | `Body` → `webwindows.input` → `WebWindows.input/forward` | the DOM hit test decides (anything above the body wins). One call site: Android = v0 injection on its display; Linux = `linuxClaim`: the gesture's DOWN replayed from the watched gesture, then every native event of the gesture (all pointers) to KWin (`linuxInput`). HACK: moves between the DOWN and the page's answer (~1 frame) aren't replayed |
| raise / focus | `Body`/`TitleBar` pointerdown → `raise` | one implementation for both kinds: the window goes last in `webWins` = top in the DOM = top layer (z in the same `w.f`), and the press is forwarded (Android: the injected touch moves the top focused display to the window's VD, S0c; Linux: KWin `focus`) |
| work area | `workArea()` | the `.pages` box (PS1: a side dock's column is not a page's), above the dock and bar |
| DB1 | `clampPlace` | a floating window's bar never above the status bar's bottom (`--inset-top`), at least a third of it on screen sideways and above the work area's bottom; drag, top-edge resize and restore |

The touch hook stays as a **watcher** (`WebWindows.onTouch` returns false): it keeps the current gesture for the Linux
claim and never takes a touch. ww-linux2 owns Linux input delivery: its change goes into `linuxInput` / `linuxClaim`,
the forwarding call site stays `forward`.

### Measured lag

The app's layer must move on the same displayed frame as its DOM frame. 2026-10-30 (APK c68a9eb7, user: "the windows are
disconnected from their contents, like it's lagging behind"): `FrameSync.bind` put each "w.f" on the draw its
`postVisualStateCallback` fired on, and 888 of 932 applies had 1-4 newer page frames already received (`behind=` in the
`w.f f<id>` log line). Cause: the page sends "w.f" from its rAF and then commits that frame; the visual-state request
reaches the renderer after that commit, so it rides the NEXT commit - always a frame or more late. Home's WebView is a
synchronous compositor (it draws the renderer's newest active frame inside the window's draw), so the first window draw
after the receipt is the one that shows the measured frame: `FrameSync.next` applies the geometry on the main thread
ahead of that draw (an async handler, so a pending traversal's sync barrier doesn't push it a frame later) and asks for no
draw itself (an invalidate could draw before the commit is ready: content a frame ahead). The log's `lag=a/b/c/d`
counts applies by window draws between receipt and apply (0 = the draw that shows that page frame).

Left: a CSS transition the compositor runs (the page track's 280 ms snap after a swipe's release) is ticked with the
draw's frame time, the page's rAF measured it at the previous one: during that snap the DOM leads the content by about a
frame. Finger-driven moves (drag, resize, swipe while held) are main-thread and exact.

### Removed

- `WebWindowChrome.kt` (native bar, background, glass), the native tile menu/dividers/snap hint of
  `WebWindowTiles.kt` (only `splitEntryPoints`, OnePlus's split settings, stays: now an `object`).
- In `WebWindows.kt`: the native drag/resize/zoom/divider/menu touch code (`Drag`, `down`, `hit`, `follow`,
  `endDrag`, `held`, `dividerDown..dividerUp`, `snapSlot`, ~700 lines), `w.area` / `w.theme` (and their plumbing in
  `ShellNative`, `ShellBridge`, `ShellHost`), the `webwindows.moved/raise/tile/divider` events.
- Two-finger zoom of a window (it was the native bar's). The model's `scale` is still honoured (CSS transform, measured).

### Proof

- Gate (`dev/gate.mjs webWindowMaskCheck`, desktops scene): page content and a lower window masked over bodies, a live
  body transparent, a new body a placeholder, the bar a `.tile`, a tap on the DOM tile menu over a body hits the menu
  and tiles; **`w.f` on a page swipe**: with the page track at -200 px the body's x in the last `w.f` equals its
  `getBoundingClientRect` and is 200 px left of before, still visible; swiped a page away, PowOS AI side, a folder
  open → `visible 0`; a window hanging past its page's right edge is clipped at it (PS2); maximise/restore.
  `webWindowCheck`: bar drag moves the window and never turns the page; dragged up it stops at the status bar (DB1).
- Shots: `webwindows` (two windows, one live = stand-in stripes, one placeholder), `ww-menu` (tile menu over a body),
  `ww-swipe` (mid swipe: the windows go with their page), `ww-tiles-2/3/4`.

### Phone check (read-only; the coordinator ships)

Unfolded, `powos_web_windows` = 1, Chrome open as a window:
- `dumpsys SurfaceFlinger --list | grep powos-ww`: `powos-webwindows` under home's layer **below** its buffer
  (layer -1), `powos-ww-<id>` with the mirror; no `-bar`/`-back` layers, no `powos-ww-divider`.
- swipe pages slowly: Chrome's content stays inside its DOM frame mid-swipe; logcat `PowosWebWindows: w.f f<id>
  behind=0 ... clip ...` once a second; on the PowOS AI page and with a folder open the window is `hidden`.
- tap the tile button → the DOM menu over Chrome takes the tap (Left half tiles it); Calculator tiled left/right/
  quarter lays out at the tile's size (`helper resize` lines per settle).
- drag the bar (moves, stops at the status bar), an edge (resizes), double tap (maximise: the bar merges with the
  status bar), full screen (a real full-screen task on display 0: `window N: its app (task T) is a full-screen app`).

### Not yet

- During a live edge/divider drag the app's display resizes every frame (coalesced in the helper); the app's last
  frame shows anchored top-left (cropped, never stretched), the rest of a bigger body shows home under it until the
  app draws. No cover-scaling yet (it was the native divider's).
- Android body input is still v0 (single pointer, injected); the S4 injector replaces `forward`'s Android branch.
- Linux popups (S7) and the switcher's Linux cards are unchanged.

---

## Tiles: PowOS's own split screen (2026-10-30, branch ww-tiles)

The user, 2026-10-30: **"lets take full control and replace that too so we can unlock our own splitscreen
capabilities maybe with like 3 of 4 apps at once"**. Android's split (WM Shell) holds 2 apps and paints a veil while its
divider moves (`SplitDecorManager`: a layer in the app's TaskDescription background colour, white for most apps). With
`powos_web_windows` = 1 PowOS tiles its own web windows instead. Folded is unaffected (no web windows there).

### Model (page: `shell/ui/webwindows.tsx`, section "tiles")

- A **tiling** is a state of one home page's windows: `tilings[page] = {layout, ids, rx, ry}`. A window listed in
  `ids` is *tiled*, every other window floats as before. `ids` may hold `null`, an empty tile. The next window opened
  on that page fills it (`fillEmptyTile`).
- Layouts: `2h` left | right, `2v` top / bottom, `3` one big left plus two stacked right, `4` a 2x2 grid. Two apps
  split left | right unless the tile area is clearly portrait (h > 1.3 w). The unfolded screen is portrait by a hair, and
  the user asked for left | right there on 10-29, so top/bottom applies only to a truly tall area.
- Tiles fill the **tile area**: the work area below the status bar (`--inset-top`; a bar under the status bar could
  not be grabbed) and 8 CSS px above the dock (`tileArea`). There are 8 px gaps between tiles (`TILE_GAP`), and home
  shows through them.
- A tiled window's frame is simply its tile's rect (x/y/w/h, scale 1, not maximised). The host places it like any
  window (`w.f`), and a new body size resizes its display (`VirtualDisplay.resize` via the helper), so the app lays out
  at the real tile size.
- Leaving a tiling (`untile`): **float** (back to the floating frame it had before, `untiled`), **minimise**
  (dock), **keep** (dragged out by its bar: it stays where it was let go), or **gone** (closed). The rest close up: 2-3
  windows get the layout for their count, and a 2-split keeps its direction and ratio. A last window alone fills the work
  area (maximised, with restore = its floating frame), as Android's split ending gives the other app the screen.
  The bar's double tap (the work-area maximise) or minimise on a tiled window takes it out of the tiling first. Its
  *full screen* button (a real full-screen app, "Full screen = a full-screen app") does too: on `webwindows.full {on}`
  the window leaves its tile as **float** (back in a window later, it floats at its old frame) and the others close
  up; the host drops any divider drag or tile menu on it. Closing a tiled window (its bar, or a swipe away in the
  switcher: `Tasks.remove` → `closeForTask` → the same `drop`) frees its tile (`webwindows.closed` → **gone**).
  The switcher's split picking an app that is a full-screen app now brings it back into its window first
  (`webwindows.toWindow`), then tiles it.
  With the switcher up (`WebWindows.switcherOpen` hides the windows' root) the dividers, the snap hint and the tile
  menu hide with it - they are children of that root; a divider drag in progress is let go as cancelled and the menu
  and hint close (`tilesUnderSwitcher`), and no divider takes a touch until the switcher is down. The card menu keeps
  both *Split screen* (2-4 apps tiled) and the new *Back to window* / *Floating window* item.

### Dividers (superseded: DOM handles now, see "Element model"; the rules below are unchanged)

- The page sends the dividers in `w.f` after the windows: `<n> [<page:axis> <x|y> <pos> <from> <len> <lo> <hi>
  <before ids> <after ids>]`, measured from invisible `.webwindow.ww-divider` elements in the page. They therefore move
  with a page swipe, and home's swipes and pulls leave them alone (`gesture.ts` / `home.tsx` already skip `.webwindow`).
- The host draws one handle layer per divider (a 5 dp pill in the page's foreground colour with a surface-coloured rim)
  under `powos-webwindows`, above every window (layer 10000). Touch target: 44 dp across, the divider's whole length.
  It is hit before any window's bar or edge.
- **Drag: native and live.** Each MOVE is one transaction: the before side's far edge and the after side's near edge
  follow the finger (`dividerFrames`). Each app's **last frame** is cropped where its tile shrank and **scaled up to cover**
  where it grew (`Geo.cover` → mirror `setScale` + crop in `frameAt`), so there is never a background, veil or white. A
  tile stops 48 dp from the span's ends.
- **Release:** the divider snaps to the nearest of **1/3, 1/2, 2/3** right away (one transaction). The layers are held
  there (`heldByDivider`) until the page's next `w.f` has those frames (2 px) or 1 s passes. The page takes the ratio
  (`webwindows.divider {key, ratio}`), and its frame resizes each display.
- **To an edge** (within 12 % of the span): the squeezed side's window(s) **go to the dock** (minimised, still running; a
  tap on the dock icon brings them back floating), and the rest close up (`webwindows.divider {key, ratio, drop:
  [ids]}`). Decided this way because closing would lose the app's state, and floating it on top would cover the tile the
  user just widened. The user asked the same of Android's split on 10-29 ("putting it inside of a drawer or something"
  instead of closing).

### Entry points

- **Title bar:** a 4th button, *tile* (two panes), left of minimise (the bar, right to left: close, full screen,
  minimise, tile). It opens a native menu under it (layer 10002):
  left, right, top, bottom, grid, and float when the window is tiled. Pick = `webwindows.tile {id, slot}` →
  `tile()`. A half makes a 2-split; the page's other tiled windows keep a tile, and an empty half takes the page's
  topmost floating window (two windows, one split). Grid tiles the window with the page's other windows (2-4, layout
  by count, this one first). A corner makes the 2x2 grid; empty corners stay empty until a window opens.
- **Drag to an edge:** moving a window by its bar (one finger) with the finger within 24 dp of the work area's
  left/right edge shows a translucent snap hint (layer 10001) of the half. Within 120 dp of the top/bottom there, it
  shows the quarter. Letting go there puts the window into that tile at once (its last frame covering the tile), then
  the page tiles it. A tiled window dragged elsewhere by its bar floats again.
- **Switcher:** "Split screen" with web windows on: pick the first app, then 1-3 more. A banner counts them and has a
  **Split** button; the 4th pick tiles at once (`ui/recents.tsx splitTiles` → `tileApps`). The apps open as web
  windows on the home page on screen, tiled in pick order. With web windows off, it stays Android's split (second pick).
- **OnePlus's own split entry points** are off while web windows are on: `Settings.Secure
  double_finger_split_screen_enable` and `Settings.System recommender_split_screen_enable` (both 1 on the phone,
  read 2026-10-30). They are set to 0 at SystemUI's connect, and the old values are restored when the setting goes off
  (`WebWindowTiles.splitEntryPoints`, HACK: OxygenOS private keys).

### Fallback: Android's split

- `WebWindows.open` refuses an activity with `resizeMode` UNRESIZEABLE and targetSdk < 36 (Android 16 ignores the flag
  on large screens from 36). Log: `fallback: <pkg> keeps Android's own window/split, not a web window: not resizeable
  ...`. The launcher then launches it as before; the switcher's split uses `tasks.split` (Android's) for the first
  two picks.
- After every launch on a window's display: no task on that display 3 s later (the app refused it, or its launch
  escaped) → the window goes and the app opens as Android's own window. Log: `fallback: <pkg> has no task on display N
  3000 ms after its launch`.

### Shots

`shell/dev/shots.mjs` scenes `ww-tiles-2/3/4` (unfolded, unfolded-land): the page's tile rects painted with stand-ins
for the native frame, bar and handles (`TILE_PAINT`; on the phone those are layers). Run:
`shell/dev/shot.sh OUT 'ww-tiles'`.

### Phone check

With the APK shipped and the user idle, open two apps from the launcher (web windows), then:
- tap the *tile* button on one bar → menu; pick left → `window N: tile left (its tile menu)`, page console
  `[tiles] page P: 2h [N,M] (left for window N)`;
- drag the divider → `divider P:x: K live moves in T ms (last frames scaled/cropped, no veil), 0.41 -> snapped 0.33`;
  then helper resizes for both displays; no white flashes while dragging;
- drag a divider to the edge → `... let go at 0.05: windows N leave the tiles (to the dock)`;
- drag a window by its bar to the left edge → hint shows, `window N: snapped to tile left ...`;
- switcher → card menu → Split screen, pick 2-4 → `[tiles] page P: 3 [..] (split screen)`;
- `dumpsys SurfaceFlinger --list | grep powos-ww-divider` shows the handle layers;
- `settings get secure double_finger_split_screen_enable` → 0 while web windows are on.

### Not yet

- Touch routing into the app is still v0 (the page forwards body touches).
- In a 2x2 grid the two handles cross at the centre. The vertical divider wins a press there; there is no 2-D drag of
  both at once.
- Divider handles sit above floating windows that overlap a tiling.
- No swap of two tiles by dragging one onto the other; no per-tile resize from the outer edges (dividers only).
- The snap hint is a plain rectangle (no corner radius: the layer is scaled from 8x8).

---

## An app into a desktop window (2026-10-30)

One path makes a running app a web window: `ShellBridge.toWebWindow(task)`. A web window's full-screen app goes back
into its window; a web window already is shown; any other app gets a new window on home's current page holding its
existing task (`webwindows.adopt` -> `adoptWebWindow` -> `webwindows.open(key, rect, task)` -> `WebWindows.adoptNow`
moves the task onto the window's trusted display), at its freeform bounds, else its last place by hand
(`WindowPlaces`), else a centred default. Callers: the switcher card's "PowOS desktop window" and "Back to window", and
the system's "..." app-handle menu.

That menu is OnePlus' `FullscreenCaptionHandleMenu` (Split screen / Floating window / Close), not AOSP's desktop handle
menu: its items are fixed, and AOSP's menu (with its Desktop button) only exists when `config_isDesktopModeSupported`
(false here) swaps in `DesktopModeWindowDecorViewModel` for every task. So `SystemFloat` relabels the menu's "Floating
window" (`com.android.systemui:string/caption_menu_text_zoom`) to "Desktop window" with a fabricated overlay
(`com.android.shell:PowosDesktopWindowItem`) while `powos_web_windows` is 1, and converts a task that goes from full
screen to floating (OnePlus' zoom mode 100, or freeform) without PowOS's hand (`FreeformTasks.markOwnFloat`). Setting
off: the overlay is disabled, nothing converted.

With tiles (above): the adopted window joins home's current page like any window opened there. If that page has a
tiling with an empty tile, it fills that tile (`fillEmptyTile`, the same rule as `openWindow`; its adopted frame is kept
as `untiled`, so a float out puts it back where the app was). Otherwise it floats at that frame, on top, and a full
tiling stays untouched. Chosen this way because an empty tile only exists to wait for the next window, and an adopted
app is that next window, so it gets no exception. Pushing a tiled window out to make room would rearrange what the user
set up. Full screen, close, minimise and the tile menu then behave as for any web window (a tiled one leaves its tile
as in "Leaving a tiling"). An app whose activity can't be a web window (`unresizeable`) returns -1 from `open` and
keeps its task where it is.

---

## S6: Linux windows as web windows (2026-10-30, branch ww-linux; first slice, not yet run on the phone)

The user, 2026-10-30: **"The Linux windows are not launching like the other Android Windows with like the web OS
window"** and **"Linux apps still use the old launcher."** Before this, with `powos_web_windows` = 1, Dolphin still
opened as a `PowosWindowActivity` freeform task with the old `WindowFrames` overlay bar (plain "Dolphin", no icon,
another bar and glass): shots `screen-1793381345898.jpg`, `screen-1793382050699.jpg` in the phone's powos-ai-shared.
Manager spec X1-X3: Linux windows open through the same web-window component (bar, glass, shadow, move, resize,
two-finger scale, z-order, tiles); the content fills its frame exactly; nothing draws outside its frame.

### Design: one window model, two sources

A web window (`WebWindows.Win`) has a container, the native frame (`WebWindowChrome`), geometry from the page (`w.f`)
and the finger, and a **content layer** in the mirror's place (`Win.mirror`). The source is either an Android
app's VirtualDisplay mirror (S1-S3) or, new, a **KWin toplevel** (`Win.linux: LinuxSource`). Everything that places,
crops, rounds, orders, hides, hit-tests and moves a window is the same code for both; only the source-specific steps
branch on `linux` (size, input, close).

| step | Android app (S1-S3) | Linux window (S6) |
|---|---|---|
| opens | page `openWindow` → `webwindows.open(key, rect)` → helper VD + mirror → launch | KWin `open <id> <app> <caption>` → `WindowTasks.open` → `WebWindowSource.offer` (instead of a `PowosWindowActivity` task) → ShellBridge's host → `WebWindows.linuxOpened` → page `webwindows.adopt {kwin, key, label}` → `adoptWebWindow` → `webwindows.open(key, rect, -1, kwin)` → `WebWindows.openLinux` |
| content | `mirrorDisplay` layer tree | a buffer layer `powos-ww-<id>-linux` in the container; `Surface(content)` given to the **same consumer** (`Native.nativeStartWindow`, native_consumer.c, pre-rotated buffers of kwin 0041) PowosWindowActivity's SurfaceView used |
| size | `VirtualDisplay.resize` (helper) | `size <id> <w> <h>` to KWin + the consumer's crop + the buffer queue's size (`Transaction.setBufferSize`, applied at once) |
| body touches | page forwards (v0) | **native**: `onTouch` → `linuxBodyAt` → the whole gesture (every pointer) to KWin with `nativeSendWindowTouch/TouchFrame`, mapped to body px through the frame's place and scale; `focus <id>` to KWin on the first touch of another window |
| close (bar) | tasks removed, VD released | `quit <id>` (KWin closes the window, then ends the app, kwin 0041) |
| KWin closes it | — | `close <id>` → `linuxClosed` → the window goes, nothing told back |
| full screen button | a real full-screen app on display 0 | (not yet) the work area's maximise |

**X2 (no crop, no offset).** The buffers are the screen's size (as PowosWindowActivity's `buffersFor`); KWin draws the
window from their top left at the size it was told (`size` = the body's px); the consumer's crop and the content
layer's buffer-queue size are that same body size, so a buffer shows 1:1 at the body's top left. A resize allocates
nothing; until KWin lays out at the new size the last frame stays anchored top-left (a queued frame of the old size
is dropped by the queue, never stretched). On the shots, Dolphin's Places panel is whole while its compact view's
first column is cut and its own horizontal scroll bar shows: that cut is inside Dolphin's view (scrolled), not the
Android crop, which would cut the Places panel first. To recheck on the phone with the new path.

**X3.** The container is cropped to the frame and the work area, the content to the body (`frameAt`, unchanged).
Popups still render inside the toplevel's buffer (kwin 0013) and are confined to it (0027), so nothing of a Linux
window draws outside its frame - the price is Z3 (S7 below).

**Fallbacks (the old path stays).** Web windows off, folded, no home bridge, a KWin without `size`, a full-screen
application (`open ... fullscreen`: a game stays a full-screen task), or a window that already has a task: a
`PowosWindowActivity` task exactly as before. A window offered to the page and not taken within 3 s
(`LINUX_ADOPT_MS`: no page, a page from before S6), or `openLinux` without a surface: `WebWindowSource.fallback` →
`WindowTasks.openAsTask`. Home's bridge closing (`closeAll`: the activity destroyed, a fold) hands every Linux web
window back as a task (`handBack`), never quits the app. Launch windows (LaunchWindows' splash tasks) are not opened
while web windows want Linux windows (`Runtime.openRooted`); a launcher tap on a Linux app that has a web window
brings it to the page (`ui/webwindows.tsx linuxWindow`), as an Android app's does.

No KWin change: the slice uses only what KWin 6.7.5-3.49 (installed) already says (`caps`: `size`, `quit`, `nodecor`,
pre-rotation). Install order: any. An older APK keeps the task path; the new APK with an older KWin without `size`
keeps it too.

Files: `engine/.../WebWindowSource.java` (new: the host interface, the consumer and control calls for the app module),
`WindowTasks.java` (`open(..., web)`, `openAsTask`, `onWebWindow`, `session`), `shell/WebWindows.kt` (`LinuxSource`,
`linuxOpened`, `openLinux`, `linuxClosed`, `dropLinux`, `linuxBodyAt/linuxDown/linuxInput`, the Linux branch of
`place`, `fullScreen`), `shell/ShellBridge.kt` (`linuxWindows` host: app id → `l:<desktop id>` key, name, icon;
`webwindows.open` with a KWin id), `Runtime.kt` (no launch window), page `ui/webwindows.tsx` (`adoptWebWindow` with
`kwin`, `linuxWindow`), `state.ts`, `bridge.ts`, `types.ts`.

### Phone check

With the APK installed, unfolded, `powos_web_windows` = 1 and the user idle: open Dolphin from the launcher.
- logcat `WebWindowSource: open N (org.kde.dolphin): a web window`, `PowosWebWindows: KWin window N ... offered to the
  page as l:org.kde.dolphin`, `window W: KWin window N ... as a web window, WxH`, `consumer up, buffers ...`; no
  `PowosWindow` / `LaunchWindows` lines for it, no `fallback:`.
- `dumpsys SurfaceFlinger --list | grep powos-ww-W` shows `powos-ww-W`, `powos-ww-W-linux`, `-bar`, `-back`;
  `dumpsys activity recents` has no `powos-window://N` task.
- the shot: Dolphin with the same bar as Chrome's (icon, "Dolphin", tile/min/full/close), its Places panel at the
  body's left edge, nothing outside the frame; drag the bar (moves), an edge (resizes: then
  `size N w h` and Dolphin re-lays out), two fingers on the bar (scales); tap a folder (opens: touches reach it); the
  close button → `quit N` and Dolphin's process gone a few s later.

### Next steps (not in this slice)

- **Z3 / S7, popups as their own surfaces:** KWin control word `web <id> 1` (new kwin patch): popups not rendered into
  the toplevel's buffer and not confined (0027 off for it), each exported as its own surface id
  (`popup <id> <parent> x y w h`), placed by the host under the window's container above the content (not cut by its
  crop). Until then Dolphin's menus stay inside its window.
- **Transient toplevels** (File > Properties) already arrive as their own KWin windows, so they open as their own web
  windows; grouping them in z above their parent is not done.
- **Tiles:** a Linux web window is in the page's model like any window, so the tile menu, dividers and snap use it
  unchanged (a divider's live cover scale uses its body size); not yet tried on the phone.
- **Switcher card:** a Linux web window has no Android task, so no card; it needs a card from the host
  (`contentShot` of its content layer) in `recents.tasks`, and the dock's running state for `l:` keys.
- **Keyboard:** `SystemIME` hosted by home for the focused Linux web window (kwin 0010/0012/0016 text focus), and
  hardware keys (`nativeSendWindowKey`) from home's key dispatch while a Linux web window has focus (S5).
- **Title updates** (`title <id>`): the bar shows the app's name; a caption change is ignored (WebWindowChrome is being
  reworked by bar-merge).
- **Full screen:** an app going full screen (`fullscreen <id> 1`) stays in its window; the bar's full-screen button is
  the work-area maximise. A Linux full-screen app as a real full-screen surface is open.
- **Client-side frames (CSD, kwin 0046 / 3.53, 2026-10-30):** KWin says `decor <id> 0 own` for an undecorated normal
  window or dialog that draws its own frame (Wayland: kept client-side decorations; X11: `_MOTIF_WM_HINTS` no
  decorations or `_GTK_FRAME_EXTENTS`). The page shows no PowOS bar over it (`WebWin.ownFrame`, adopt payload +
  `webwindows.frame`); the task path's `WindowTasks.drawsOwnBar` follows the same rule (an older KWin: PowOS's bar). Its
  own drag/resize (`xdg_toplevel.move/resize`, `_NET_WM_MOVERESIZE`) is cancelled in KWin and sent as
  `moveresize <id> move|<edges>`: `WebWindows.linuxMoveResize` cancels the touch to KWin, the page's Body drives the
  frame with the same pointer (`appDragMove`: moves/untiles/snaps like the bar, resizes like an edge; held still 500 ms:
  the tile menu). Its maximize (button or double click on its tab strip) = PowOS full screen, minimize = the dock.
- **Content = the visible frame (kwin 0046):** an undecorated window is shown and sized by KWin's `frameGeometry` (the
  X11 client geometry includes `_GTK_FRAME_EXTENTS`, the shadow): before, Brave's frame sat ~16 logical px inside the
  body with a dark gutter left/right/bottom and KWin's refit loop ("took 543x628 itself, the task is 504x606").
- **Frame pacing (kwin 0046):** `window task N frames: last 5 s C commits, D drawn (fps); commit -> drawn median/p90/max`
  in KWin's log (`/run/powos-app/hyprland.log`) every 5 s while the window draws: commits > drawn or a long
  commit -> drawn = the per-toplevel path holds frames; commits ~= drawn at low fps = the client (Xwayland/Brave).
- **Home restart:** windows are handed back as tasks; re-adopting them as web windows when home returns (KWin's
  `session` list) is open.
