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
