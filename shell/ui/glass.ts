/**
 * Glass: the wallpaper as the page's own bottom layer, so the surfaces' plain CSS backdrop-filter (theme.css) blurs
 * what is really behind them - the wallpaper and any other UI under them, one surface over another included.
 *
 * Android draws the wallpaper behind the window, out of the page's reach: CSS backdrop-filter over a transparent page
 * blurs nothing there. So on the pages that stand on the wallpaper (home, the lock face) the host's picture of it
 * (system.glass: the theme's background, a still wallpaper, or OxygenOS's still of a live one) is drawn by the page
 * itself under everything, positioned as Android crops it (centred, covering the screen: html.wallpaper,
 * theme.css). Nothing is frosted ahead of time or placed per surface (the earlier sampled-picture frost: surfaces
 * couldn't blur each other, and a misplaced copy showed as a smear).
 *
 * The windows over apps (the shade's, the switcher's) have what's behind them blurred by the host: their surfaces
 * only tint (html.glass-behind). The assistant's window shows the screen it was opened on 1:1 - no glass at all.
 */
import { powos } from "../bridge.ts";
import type { GlassSource } from "../types.ts";
import { debug as nativeDebug } from "./nativeglass.ts";

const root = document.documentElement;
/** Which page this is (index.html?mode=). */
const mode = new URLSearchParams(location.search).get("mode") ?? "home";
/** The pages that stand on the wallpaper: they draw it themselves. */
const OVER_WALLPAPER = new Set(["home", "lock"]);
/** The windows over apps whose host blurs what's behind them: tint only. */
const TINT_ONLY = new Set(["shade", "recents"]);

/** The wallpaper shown now (its URL), and the one being loaded. */
let shown: string | null = null;
let loading: string | null = null;

function use(g: GlassSource | null) {
  root.classList.toggle("glass-behind", TINT_ONLY.has(mode) && g != null);
  const url = OVER_WALLPAPER.has(mode) ? (g?.wallpaper?.url ?? null) : null;
  if (url === shown || url === loading) return;
  if (!url) {
    shown = loading = null;
    root.classList.remove("wallpaper");
    root.style.removeProperty("--wallpaper");
    return;
  }
  // Decoded first: the layer changes in one frame, never through an empty one.
  loading = url;
  const img = new Image();
  img.src = url;
  img.decode().then(
    () => {
      if (loading !== url) return;
      loading = null;
      shown = url;
      root.style.setProperty("--wallpaper", `url("${url}")`);
      root.classList.add("wallpaper");
    },
    (e) => {
      if (loading === url) loading = null;
      console.warn("glass: the wallpaper didn't load", e);
    },
  );
}

powos.on("system.glass", use);
// Folded or unfolded: another screen, maybe another picture (the host's copy is per screen) - asked again.
addEventListener("resize", () => void powos.system.glass().then(use, () => {}));
powos.system.glass().then(use, () => use(null));

/** For CDP and a browser: a wallpaper by hand (`__glass.use(url)`; null: none). */
(window as unknown as { __glass: object }).__glass = {
  use: (url: string | null) => use(url ? { wallpaper: { url, rev: "manual", source: "manual" }, blurBehind: false } : null),
  get wallpaper() {
    return shown;
  },
  /** The compositor's glass (ui/nativeglass.ts, the windows over apps): its state, `__glass.live.native(false)`. */
  live: nativeDebug,
};
