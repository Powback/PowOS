# ABZÛ low fps (abzu-fps, 2026-11-07)

Board task `abz-has-low-fps`. User: "abzo has low fps". Goal: 120 fps (games-120fps-goal), judged with the screen
touched (ColorOS's no-touch 60 Hz cap is out of scope).

## The live capture (11-07 ~01:4x, the user playing; job af8ebd0c live-abzu)
ABZÛ = appid 384190, UE 4.12 DX11 (`AbzuGame (64-bit, PCD3D_SM5)`) -> DXVK v3.1.1-97 (Proton Experimental
11.0-20261027b ARM64) -> Turnip (vulkan-freedreno-kgsl eb3e7fd4) -> Xwayland copy -> KWin window task -> SurfaceFlinger.

    layers: game 19.6 > xwayland 17.3 > kwin 15.1 > sf 20.6 > panel 120 Hz

- GPU busy 81 % at 625 MHz average (the a740's top level is 680 MHz, `gpu_available_frequencies` 680/615/550/...;
  thermal_pwrlevel 0, not throttled): the GPU already runs at ~92 % of its top clock. RenderThread 36.5 % of a core,
  game main 23.5 %, dxvk-cs 13.9 % - no thread is near a full core. **GPU-bound.**
- Xwayland waits on the game's GPU fence for half its Present copies (avg 24 ms): the frame isn't drawn yet.
- CPU 85-93 C, skin 38-39 C; CPU caps policy7 1977/3187, policy3 2188/2803 (horae's skin gear, see
  broforce-fps.md) - not the limit here.
- Window: `QSize(2268, 2440)` = the whole inner screen (5.53 MP).

## What ABZÛ renders at
Its own settings (`pfx/.../AppData/Local/AbzuGame/Saved/Config/WindowsNoEditor/GameUserSettings.ini`, section
`/Script/AbzuGame.AbzuGameUserSettings`): `ResolutionScale=SCALE_100`, `Fullscreen=ON`, `VSync=ON`,
`DesiredScreenWidth/Height=1280x720`, `bUseDesktopResolutionForFullscreen=False`, every sg.* quality at 3 (Epic),
Shadows/Fish/Reflections HIGH. No standard UE `ResolutionSizeX/Y`: ABZÛ has its own class. Its render scale is the
game's own enum `EGraphicsRenderScale::SCALE_25/50/75/100/125/150/175/200` (strings in AbzuGame-Win64-Shipping.exe)
= UE's r.ScreenPercentage, i.e. SCALE_75 = 56 % of the pixels, SCALE_50 = 25 %.
Proton 11 still has Wine's fullscreen hack (`WINE_DISABLE_FULLSCREEN_HACK`, `WINE_FULLSCREEN_INTEGER_SCALING` in
win32u/winex11) but **no FSR** (`WINE_FULLSCREEN_FSR` is gone from Proton 11's binaries) - so "lower game res + Wine
FSR" isn't available; the engine's own screen percentage (UE upsamples in its tonemapper/upscale pass) is.

## Levers measured
(filled below per run: bf-pacing.sh APP=384190 WIN_NAME=AbzuGame, the game's title/menu scene after a 45 s settle)

**What it really renders at (PROTON_LOG run, 03:00):** Steam's command line is
`AbzuGame.exe -windowed -ResX=2268 -ResY=2440` - unity-screen's Unreal arm (agent/game-resize-all 0ffd18c3, on
master; written into every Unreal game's LaunchOptions by `powos-steam-compat apply`). DXVK's swapchain:
`Buffer size: 2268x2439` (FIFO). With ResolutionScale=SCALE_100 the game now renders **5.53 MP every frame** - before
that launch option it rendered its saved 1280x720 (0.92 MP, 6x fewer pixels) and Proton's fullscreen hack scaled it.
So the "low fps" the user sees is mostly the native-res launch: the container-size fix is right for layout, but it
needs a render scale next to it on a GPU this size.

| run (title menu, 30 s, unfolded, web window) | game fps | layers line | GPU busy / clock | skin |
|---|---|---|---|---|
| live, user's play 01:4x (SCALE_100, noubwc) | 19.6 | game 19.6 > xw 17.3 > kwin 15.1 > sf 20.6 | 81 % / 625 | 38.3-39.0 |
| base (PROTON_LOG=1, SCALE_100, noubwc) 03:00 | 19.6 | game 19.6 > xw 20.2 > kwin 21.2 > sf 18.7 | 79 % / 640 | 37.4-38.2 |
| gus:ResolutionScale=SCALE_50 (25 % pixels) 03:05 | **27.3** | game 27.3 > xw 28.6 > kwin 30.2 > sf 25.3 | 74 % / 606 | 38.9-39.4 |

GPU time per frame (busy / fps): ~40 ms at SCALE_100, ~27 ms at SCALE_50 -> ~17 ms scales with the render
resolution, **~23 ms doesn't** (UE's full-output-res passes: upscale/tonemap/UI at 2268x2439, shadow-map and
reflection passes, plus Xwayland's 2268x2440 copy, KWin's composite and SurfaceFlinger's CLIENT composition of home
at 120 Hz - all on the same a740). Resolution alone tops out near ~30 fps; the fixed part needs the other levers.

## The other levers (queued, results go to board task abz-has-low-fps)
Still in the verify queue at hand-back (03:40): `env:TU_DEBUG=startup` (UBWC on: steam-env's noubwc overridden),
`gus:ResolutionScale=SCALE_75`, `env:DXVK_CONFIG=d3d11.relaxedBarriers=True`, a low-quality run
(`gus:Shadows=LOW,Fish=LOW,Reflections=LOW,sg.ShadowQuality=0,sg.PostProcessQuality=0,sg.EffectsQuality=0,sg.AntiAliasingQuality=0`)
and SCALE_50 + UBWC. Each ran at least once but ended INVALID (below).
- **UBWC** (lever 2): the game's own render targets lose framebuffer compression under `TU_DEBUG=noubwc`
  (steam-env HACK from Broforce's black 16x4 dashes). The ~23 ms fixed GPU part is mostly full-res, bandwidth-heavy
  passes, exactly what UBWC saves. Static check of Turnip eb3e7fd4 (tu_knl_kgsl.cc:2165-2205): UBWC config comes
  from KGSL_PROP_HIGHEST_BANK_BIT/UBWC_MODE (UBWC 4 -> 8-channel macrotile, swizzle 0x6). A wrong layout there would
  corrupt every frame, not 17-44 % of them, so the Broforce dashes look like a flag/data race (fast-clear or flag
  read before the RB's flag write lands), not a config mismatch. Real fix path (unchanged): `bf-checker.sh base ubwc
  syncdraw gmem 3dload` + a TU_DEBUG=rd capture of a dashed frame. Only after that can noubwc go for all games.
- **Clocks**: GPU 606-640 MHz of 680 at 74-81 % busy, thermal_pwrlevel 0: <= 8 % left there; not touched (vendor
  limits stay).
- **DXVK**: v3.1.1-97 in Proton Experimental 11 ARM64; native aarch64 DXVK -> our Turnip 27.0.0-devel
  (eb3e7fd4 + 0002 warning seen in the log). FIFO present, no frame cap.

## Measurement friction (why most runs were INVALID)
7 of 9 ABZU runs 02:56-03:37 ended `INVALID ... in front=HomeShell, game layers=0`: the screenshots (02:58
s1, 03:36 s4) show home's **recent-apps overview** left open (Steam + a settings card, "2 running in background")
with the game's window behind it; the game's full-screen web window never composes while the overview is up. The two
valid runs came right after `input keyevent 3` (Home) closed it. So: a game launched while the overview is open
doesn't come to the front (product: launching should close the overview, as Android does), and bf-pacing should
close transient home UI before launching.

## Conclusion so far / next
1. The drop is the native-res launch (unity-screen's `-ResX/-ResY`, 5.53 MP) on a GPU-bound UE4 title. Render scale
   is the right generic lever, but it is per game and per engine: ABZU's own `ResolutionScale` (EGraphicsRenderScale)
   in GameUserSettings.ini; plain UE4 `r.ScreenPercentage` in Engine.ini [SystemSettings]; Unity has no such knob
   (keep its container size). Proposal: a PowOS per-game "render scale" setting (default 100; GPU-bound games get a
   hint) that unity-screen applies at launch next to -ResX/-ResY - NOT a lower -ResX (that brings back the scaled,
   blurry UI and the layout bugs game-resize fixed). SCALE_50 alone: 19.6 -> 27.3 fps.
2. UBWC: measure (queued); if large, fix the dash race in Turnip so noubwc can go for every game.
3. Quality presets: measure (queued) how much of the fixed ~23 ms is shadows/reflections/post.
4. 120 fps is not reachable for ABZU on this GPU at these settings; 60 needs ~16 ms of GPU per frame, i.e. scale +
   UBWC + lower quality together.
