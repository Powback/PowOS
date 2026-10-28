# Native glass: OS-level blur, frame-synced with the page

Status: plan (2026-10-28). No code changed. Replaces nothing yet; the reverted wallpaper-in-page hack (8bfadde6)
is ruled out for good.

The rule (the user, 2026-10-28): the display compositor (SurfaceFlinger) blurs what is really behind each glass
element, on the same frame the page shows that element. The page never draws a copy of OS content (wallpaper, apps,
a screenshot), and a picture is never presented as the live blur.

## The design (5 lines)

1. Keep the compositor blur regions on the page's window surface (`Transaction.setBlurRegions`, GlassBlur.kt). They
   are the right primitive: one Kawase blur per radius per frame, per-corner radii, per-region alpha, seamless unions.
2. Fix the sync. Each page frame sends its geometry tagged with a frame id ("b.f"). On receipt the host calls
   `WebView.postVisualStateCallback(id)`. When that fires, it puts the regions on the next window draw with
   `applyTransactionOnDraw`. That draw is the first one that contains the page state the geometry was measured from.
3. Shapes are unions of rounded rects with per-corner radii, morphing per frame, all sharing one radius, so one blur
   image is clipped many times with no seams. Fades use region alpha. Axis-aligned only.
4. DOM over DOM (the launcher over home's widgets): the compositor cannot see inside the WebView's buffer. Chromium's
   own GPU `backdrop-filter` blurs the real page pixels, and the compositor region under it blurs the wallpaper.
   If the edges show, the step after that is a real second surface (the launcher in its own WebView layer).
5. Per-element child SurfaceControls are ruled out as the default (a blur pass per layer, double-blurred overlaps,
   one uniform corner radius). They are kept only for an element that needs a rotate or scale matrix.

## Evidence (this phone: OnePlus Open CPH2551, kalama/SM8550, SDK 36)

| Fact | Where |
|---|---|
| Blur filter is classic Kawase (not the dual filter): `window_blur_kawase2: false`, `restore_blur_step: true` | `dumpsys SurfaceFlinger` flags |
| RenderEngine is SkiaGL: `vulkan_renderengine: false`, `graphite_renderengine: false` | same |
| OEM blur off: `persist.sys.oplus.material_blur_switch=false`. Ours goes through AOSP blur regions | `getprop` |
| Hidden APIs present: `setBlurRegions`, `setBackgroundBlurRadius`, `setCornerRadius`, `setCrop`, `setClientDrawnCornerRadius`, `setBorderSettings`, `setEdgeExtensionEffect`, `setFrameTimelineVsync`, `addTransactionCommittedListener`, `mergeWithNextTransaction`, `applyTransactionOnDraw`, `SurfaceSyncGroup` | `grep -a -c` on `/system/framework/framework.jar` |
| No `setClippedCornerRadius` and no `setBoxShadowSettings` on this build | same (count 0) |
| No per-corner radius found for a layer. `setCornerRadii` is GradientDrawable's. `BlurRegion` does carry `cornerRadiusTL..BR` | framework.jar strings; GlassBlur.kt `Region(l,t,r,b,tl,tr,br,bl,alpha,radius)` |
| HWUI's WebView functor can hand Chromium a SurfaceControl and merge transactions (`getSurfaceControl`, `mergeTransaction` in libhwui). Chromium uses this for its own overlays; we cannot inject into it | `/system/lib64/libhwui.so` strings |
| WebView is `com.google.android.webview` 155.0.8059.46: Google's build, not ours | `dumpsys webviewupdate` |
| Emulator (emulator-5584, SDK 36): `ro.surface_flinger.supports_background_blur=1`, also Kawase and GL RenderEngine. Same blur path, so sync checks run there first | `getprop` / `dumpsys SurfaceFlinger` |
| OxygenOS's BlurRegion layout is 31 floats (AOSP: 10). A hand-built one aborts the app in JNI. The framework's own encoder is used (GlassBlur.kt Codec) | GlassBlur.kt:28-34 |

How the blur is drawn (AOSP SkiaRenderEngine, which this build uses): a layer with background blur or blur regions
forces GPU (client) composition of itself and everything under it. The content under the layer is drawn
downsampled (about 1/4 scale), blurred in up to 4 Kawase passes, then:
- with `backgroundBlurRadius`, drawn under the layer's crop and corner radius;
- with blur regions, generated once per distinct radius and drawn into each region's rounded rect at the region's
  alpha.

So N regions of one radius cost one blur. N child layers cost N blurs, and each one blurs the blurred output of the
layers below it.

## Why the current one lags (today's chain)

`nativeglass.ts:483 frame()` runs in rAF. It measures (`getBoundingClientRect`, current layout) and then
`send("b.r ...")` (:495) over the WebMessagePort. The message goes from the renderer to the app process on the
port's thread, through `GlassBlur.command` (GlassBlur.kt:220) and `main.post` (:245), to
`set()` → `root.applyTransactionOnDraw(t)` (:331-334). That rides the window's next draw.

The page's pixels for the same rAF take a separate path. The main-thread commit goes to the renderer compositor
(activate), and then to the WebView's synchronous compositor, which demand-draws at the app's onDraw through the
HWUI draw functor. The two paths race. Whichever lands first decides whether the region leads or trails the pixels
by a frame, and under jank both happen. Nothing ties a set of regions to the draw that holds that frame's pixels.
That missing link is the bug. The number of layers is not.

## Ruled out

- **Wallpaper (or any OS content) copied into the page + CSS backdrop-filter.** This is the 8bfadde6 hack. It is a
  copy, not the screen: it never shows apps or live wallpaper frames exactly, and it is not the compositor. Never again.
- **Per-element child SurfaceControl as the default.** This means `SurfaceControl.Builder().setParent(window)`
  below the BLAST layer, with `setBackgroundBlurRadius`, `setCrop`, `setCornerRadius`, `setAlpha` and `setPosition`
  per element. It syncs exactly as well as regions do: it goes into the same `applyTransactionOnDraw` transaction,
  so it gains nothing there. It loses on three counts:
  (a) one Kawase pass per layer instead of one per radius;
  (b) where elements overlap or touch (merged widgets), the upper layer blurs the lower layer's blur, which shows
      seams and a doubled blur;
  (c) only one corner radius per layer on this build, where BlurRegion has four.
  Kept for one case only: an element under a rotate or scale `matrix`, which regions (axis-aligned) cannot follow.
- **Putting the blur layer above the WebView and cutting a hole in the page.** The blur would cover the page's tint
  and content. The glass look (tint, rim, text) must draw over the blur, so the blur stays under the page's buffer.
- **A PowOS WebView build** (Chromium emitting `backdrop-filter` layers as SF blur through HWUI's functor
  `getSurfaceControl/mergeTransaction`). In theory this is exact by construction. In practice it means a Chromium
  fork, multi-hour builds and a WebView provider swap. It is the escape hatch if step 4's trace shows the
  VisualStateCallback binding still misses frames. Not now.
- **Sending element boxes earlier (before paint) as the fix on its own.** rAF already measures before paint. The
  problem is binding to the draw, not when we measure. Ahead-of-time curves (step 7) only help a continuous
  drag/settle and are optional.

## Shapes (question 3, stated plainly)

SurfaceFlinger can blur rounded rectangles: crop plus corner radius per layer, or per-corner radii per BlurRegion,
each with alpha. It has no path or mask for a blur.
- A merged-widget union is several regions of the same radius. Because they share one blur image, the union is
  seamless. The page already sends one region per surface.
- A morph is per-frame regions with interpolated rects and radii, which is fine once frame-synced.
- A shape that is not a union of rounded rects (squircle, gooey merge, rotation) can only be approximated by
  several rects, or by a child layer with a matrix (rotate/scale). An exact arbitrary shape needs a RenderEngine
  change (system image). Out of scope.

## DOM over DOM (question 4, stated plainly)

The compositor blurs layers. The whole page is one buffer in one layer, so a region under the window can only show
the wallpaper and apps under the window, never home's widgets. There are two OS-honest answers:
1. **Chromium's `backdrop-filter`** on the glass element. It is Chromium's GPU compositor blurring the page's own
   real pixels, synced by construction. With a compositor region under the same element for the wallpaper, the
   result is blur(widgets) over blur(wallpaper), which differs from blur(widgets over wallpaper) only at widget
   alpha edges. It copies no OS content, so it is not the hack. This is the default.
2. **A real second surface.** The launcher/drawer becomes its own WebView in its own layer above home's. Its
   regions then blur home's widgets plus the wallpaper in SF, which is exact. The cost: a second document and JS
   heap (same renderer process), state across the bridge, and a drag that spans two surfaces (synced the same way,
   one transaction). Do this only if step 9's render shows the edge difference.

## Cost (question 5)

Each blurred frame forces client (GPU) composition. That is the big cost: HWC overlays are lost for the stack
under and including the window, and `dumpsys` shows DEVICE composition at rest. On top of that comes one Kawase
blur at 1/4 scale per distinct radius per blurred layer. Keep one radius for all glass on a page, and keep
regions, not layers. Off at rest (the page sends nothing while still, and an unchanged region set costs no new
transaction) stays as it is. Step 8 measures it.

## Steps (each one a 5-minute edit, then a check)

Emulator: `A=~/Library/Android/sdk/platform-tools/adb; $A -s emulator-5584 ...`, APK from `tools/emu/emu.sh
install`. Phone only after the emulator check passes, via the normal ship.

1. **Trace markers.** Frame ids go into Perfetto so the race can be seen.
   - `nativeglass.ts:483 frame()`: a counter `fid++`, and `console.timeStamp("glass f"+fid)` when it sends.
   - `GlassBlur.kt:220 command`: `Trace.beginAsyncSection("glass f$id")` on receipt.
   - `GlassBlur.kt:331`: `Trace.endAsyncSection` when the transaction is applied on draw.

   Check (emulator): a Perfetto trace with `gfx view webview sf` plus the Chrome category `devtools.timeline`
   while a scripted drawer drag runs. Open it and read, per frame id, the receipt time against the
   `Choreographer#doFrame` / `DrawFrame` / SF `commit` that latched it. Write the measured chain into this doc.
2. **Protocol: frame-tagged geometry.** Add a verb `b.f <id> <dpr> <n> <regions...>`, parsed like `b.r`
   (GlassBlur.kt:220-243 → share one parser), and add it to the dispatch at `ShellNative.kt:127` with a doc line
   at `:41`. `b.r` stays for older pages.

   Check: a unit test on the parser (same regions from `b.r` and `b.f`).
3. **Page sends `b.f`.** `nativeglass.ts:495`: `send(\`b.f ${fid} ${text}\`)`.

   Check (emulator): `cdp.sh eval home '__glass.live.counts'` keeps rising during a drag, and blur still shows
   (`shot.sh`).
4. **Bind to the draw that shows the frame.**
   - `GlassBlur.kt:244-245`: on the main thread, `web.postVisualStateCallback(id, cb)`. GlassBlur already holds the
     WebView (`ShellNative.kt:71` passes `web`; type it `WebView`).
   - In `onComplete(id)`: drop any pending id older than the newest completed one, then `set(regions, 0)`, which is
     `applyTransactionOnDraw` plus `invalidate`.
   - The lag knob (`GlassBlur.kt:78`, `:330-347`) stays as a test override.

   Check (emulator): repeat step 1's trace. Each `glass f<id>` should end on the same `DrawFrame` that drew renderer
   frame `<id>`. Also frame-step a `screenrecord` of a test page whose glass box has a 1-px opaque outline drawn by
   the page and moves 40 px/frame: in every frame the blur's edge must sit on the outline. Note the miss count.
5. **Stale drop + idle.** If `b.f` k+1 arrives before k's callback, skip k: only the newest set goes on. While still,
   nothing is sent, so no callbacks run (keep it 0 frames at rest).

   Check (emulator): `cdp.sh idle 30 home` shows 0 frames, 0 rAF at rest. A trace shows no `glass f` sections at rest.
6. **One radius per page.** Make sure every region a page sends uses the same blur radius (`nativeglass.ts`
   `readBlur`, :201), so SF generates one blur.

   Check: `dumpsys SurfaceFlinger` during a drag lists one blur radius in the home layer's blur regions.
7. **Optional, only if step 4 misses during drag/settle.** Ship the drawer's keyframes once (`track()`
   `nativeglass.ts:362` already parses them) as `b.anim <id> <keyframes> <start>`. The host evaluates them at each
   `Choreographer` frame time and still binds to the drawn frame, so no message rides on each frame of a settle.

   Check: same outline frame-step, misses must be 0.
8. **Cost measurement.** On the phone (after ship): the skill's perf tools, `gfxinfo` plus a SF trace, with home
   drag at 0, 1 and 6 regions of one radius, against 6 regions of 2 radii. Record the GPU composition ms per frame
   on the Adreno 740 in this doc.

   Check: numbers in the doc, and the idle budget (about 3% of one core at rest) unchanged.
9. **DOM over DOM: backdrop-filter on the launcher frame.** In `theme.css` (`html.glass-native`, the launcher
   frame only, which sits over home's DOM), add `backdrop-filter: blur(var(--glass-blur))`. The compositor region
   under it stays.

   Check (emulator): a `shot.sh` render of the drawer half open over a widget, zoomed on a widget edge, against
   the drawer closed. If the edge halo is visible, open the second-surface plan (DOM over DOM, answer 2) as its
   own task.
10. **Child-layer path (only for rotate/scale).** A `GlassLayer` helper:
    `SurfaceControl.Builder().setParent(windowSurface).setName("glass:<id>")`, `setRelativeLayer` under the BLAST
    layer, `setBackgroundBlurRadius`, `setCrop`, `setCornerRadius`, `setMatrix`, `setAlpha`, all in the same
    `applyTransactionOnDraw` transaction. Only elements marked `data-glass-layer` use it.

    Check (emulator): `dumpsys SurfaceFlinger` lists the `glass:` layer with `backgroundBlurRadius>0` under the
    window, and a frame-stepped rotation of a test card has its blur turning with it.

## Risks

- `postVisualStateCallback` guarantees that the next draw shows the state as of the call **or later**. If the
  renderer already committed k+1 when k's callback is posted, we show k's geometry on k+1's pixels. Step 4 counts
  this. Steps 5 and 7 bound it. The real fix beyond that is the WebView fork, ruled out for now.
- Each callback is a renderer round trip. During a drag that is 1 per frame. Watch the drag's script and IPC cost
  (`cdp.sh raster`). Stale drop keeps the queue at most 1 deep.
- Hidden API drift: `setBlurRegions` and the OEM's 31-float BlurRegion. Today's check-before-use (GlassBlur.kt
  `valid`) stays. Any failure sends `b.state 0` and the page shows plain tint. It must not substitute a picture
  presented as live blur (the rule above). The frosted wallpaper picture fallback in `ui/glass.ts` is a fallback
  only when the compositor cannot blur, and must be labelled as such in Style.
- Client composition on every moving frame costs battery. Keep 0 frames at rest. Battery saver turns cross-window
  blur off (`isCrossWindowBlurEnabled`), and the page is told.
- Rotated or skewed glass is not covered by regions. It needs step 10 or stays axis-aligned.
- The emulator's GL RenderEngine runs on the host GPU. Sync checks transfer to the phone; cost numbers do not
  (step 8 is phone-only).
