/**
 * Which way this page's glass is blurred - the one place that decides it, per window/mode:
 *
 * - "page" (PAGE_BLUR, while the host has handed over the wallpaper's picture and home isn't lifted over app windows):
 *   the page draws the wallpaper itself as its bottom layer (theme.css html.glass-page) and every glass surface blurs
 *   with CSS backdrop-filter. The blur follows every shape and transform in the same frame (a morph, a scale, a
 *   radius animating) and blurs the DOM beneath it, as on the web.
 * - "native" (NATIVE_BLUR, and a PAGE_BLUR page without a picture or lifted over windows): the page can't see what's
 *   behind its window (an app, another window), so the compositor blurs rounded-rect regions (ui/nativeglass.ts,
 *   GlassBlur.kt). The shade's/switcher's/pull's windows are blurred behind by their host (ui/glass.ts TINT_ONLY).
 *
 * ui/glass.ts sets [wallpaperUrl] once the picture is decoded; ui/panellift.ts sets [overApps].
 */
import { computed, signal } from "@preact/signals";

export const mode = new URLSearchParams(location.search).get("mode") ?? "home";

/** Over the wallpaper and nothing else: home (its pages, PowOS AI's page, the launcher on home) and the lock face. */
const PAGE_BLUR = new Set(["home", "lock"]);
/**
 * Over something the page can't see: Quick Tools' card over any app, the status chrome over apps, the desktop's home
 * (powos-shell: KWin blurs under its tiles; it draws its own wallpaper, but Plasma mode stays as it is for now).
 */
const NATIVE_BLUR = new Set(["quicktools", "desktop", "statusbar"]);

/** The wallpaper's picture (same-origin /_wallpaper URL), decoded and ready to draw; null: none (yet). */
export const wallpaperUrl = signal<string | null>(null);
/** Home lifted over app windows (panellift.ts overWindows): what's behind the page is apps, not the wallpaper. */
export const overApps = signal(false);

/** This page draws the wallpaper and blurs with backdrop-filter. */
export const pagePath = computed(() => PAGE_BLUR.has(mode) && !!wallpaperUrl.value && !overApps.value);
/** The compositor blurs regions for this page (nativeglass.ts). */
export const nativePath = computed(() => NATIVE_BLUR.has(mode) || (PAGE_BLUR.has(mode) && !pagePath.value));
/** This page may use either: it says hello to the host's blur either way, in case it falls back. */
export const anyBlur = NATIVE_BLUR.has(mode) || PAGE_BLUR.has(mode);
