/**
 * Glass: the shell's surfaces over the wallpaper frosted, the wallpaper softly showing through them.
 *
 * The page is transparent and Android draws the wallpaper behind the window, so the page has no wallpaper pixels and
 * CSS backdrop-filter over it blurs nothing (and a live backdrop blur on every tile costs a render pass each, every
 * frame). Instead the host hands over the wallpaper as an image (system.glass) and this blurs it ONCE, small, into a
 * frosted copy of the screen (an object URL, --glass-image); every glass surface draws that one picture as its
 * background, placed where the surface is on the screen (--gx/--gy, or --gb from the bottom for a surface whose top
 * edge moves), under the theme's tint (theme.css). Drawing a picture costs a surface nothing per frame.
 *
 * Positions are layout positions (offsets: transforms left out), with home's pages each counted as at the screen's
 * left: at rest every surface is exact; while a page or panel slides, its glass slides along with it and lands exact,
 * never jumping. Measured again when surfaces come, go, move or resize - not per frame.
 *
 * Frosted again only when the picture changes ("system.glass": another wallpaper, the theme's), the screen's size
 * changes (fold/unfold), or the theme does (the light ones frost lighter). Without system.glass (an older host, the
 * desktop's) or without a wallpaper the page keeps the plain fills; in the windows over apps (the shade's and the
 * switcher's, which the host blurs behind; the assistant's) surfaces are only tinted (html.glass-behind).
 */
import { powos } from "../bridge.ts";
import type { GlassSource } from "../types.ts";
// Live glass (ui/nativeglass.ts): while the compositor blurs behind the surfaces, no frosted picture here.
import { debug as nativeDebug, nativeGlass } from "./nativeglass.ts";

const root = document.documentElement;
/** Which page this is (index.html?mode=): home is over the wallpaper; the shade's window over an app; others neither. */
const mode = new URLSearchParams(location.search).get("mode") ?? "home";
/**
 * The surfaces that get the glass: every tile and the notification panel (PowOS AI's page shows the wallpaper as home
 * does; its cards are tiles).
 */
const SURFACES = ".tile, .notif-panel";

let source: string | null = null;
let frosted: string | null = null;
/** What the current frosted copy was made from (picture, screen size, theme): the same again is not frosted again. */
let frostedFor = "";
let busy: Promise<void> | null = null;

/** The wallpaper, frosted at [scale] of the screen's CSS size: blur, saturation and brightness from theme.css. */
async function frost(url: string): Promise<string> {
  const img = new Image();
  img.src = url;
  await img.decode();
  const css = getComputedStyle(root);
  const num = (name: string, fallback: number) => {
    const v = parseFloat(css.getPropertyValue(name));
    return Number.isFinite(v) ? v : fallback;
  };
  const blur = num("--glass-blur", 28);
  const saturate = num("--glass-saturate", 1.5);
  const brightness = num("--glass-brightness", 1);
  // Half the CSS size is plenty for a picture this soft (and a tenth of the pixels to blur once).
  const scale = 0.5;
  const w = Math.max(1, Math.round(innerWidth * scale));
  const h = Math.max(1, Math.round(innerHeight * scale));
  const r = blur * scale;
  const pad = Math.ceil(r * 2);
  // The wallpaper as Android shows it on this screen: centered, covering it (wallpaperCrop at the middle offset).
  const sharp = document.createElement("canvas");
  sharp.width = w + 2 * pad;
  sharp.height = h + 2 * pad;
  const s = sharp.getContext("2d")!;
  const cover = Math.max(w / img.naturalWidth, h / img.naturalHeight);
  const dw = img.naturalWidth * cover;
  const dh = img.naturalHeight * cover;
  // Past the screen's edges the blur needs pixels too, or the edges go dark: the picture stretched under it.
  s.drawImage(img, 0, 0, sharp.width, sharp.height);
  s.drawImage(img, pad + (w - dw) / 2, pad + (h - dh) / 2, dw, dh);
  const out = document.createElement("canvas");
  out.width = w;
  out.height = h;
  const o = out.getContext("2d")!;
  o.filter = `blur(${r}px) saturate(${saturate}) brightness(${brightness})`;
  o.drawImage(sharp, -pad, -pad);
  const blob = await new Promise<Blob | null>((done) => out.toBlob(done, "image/png"));
  if (!blob) throw new Error("glass: the frosted wallpaper didn't encode");
  return URL.createObjectURL(blob);
}

/** Frosts [source] for the screen as it is now, unless that's what's up already; no source: the plain fills. */
function refrost(): Promise<void> {
  const live = nativeGlass.value;
  const key = `${live ? "live" : source}|${innerWidth}x${innerHeight}|${root.dataset.light ?? ""}`;
  if (key === frostedFor) return busy ?? Promise.resolve();
  frostedFor = key;
  const run = (async () => {
    if (!source || live) {
      root.classList.remove("glass");
      root.style.removeProperty("--glass-image");
      return;
    }
    try {
      const url = await frost(source);
      if (frostedFor !== key) return URL.revokeObjectURL(url);
      const old = frosted;
      frosted = url;
      root.style.setProperty("--glass-image", `url("${url}")`);
      root.style.setProperty("--glass-w", `${innerWidth}px`);
      root.style.setProperty("--glass-h", `${innerHeight}px`);
      root.classList.add("glass");
      if (old) setTimeout(() => URL.revokeObjectURL(old), 1000);
      place();
    } catch (e) {
      console.warn("glass: no frosted wallpaper", e);
      root.classList.remove("glass");
    }
  })();
  busy = run;
  return run;
}

/**
 * Which way each page gets its glass: home and the lock face stand on the wallpaper (the frosted copy); the shade's
 * and the switcher's windows have what's behind them blurred by the host (tint only); the assistant's is over an app
 * it circles on: none at all (the real screen 1:1). The rest (the screen-off clock, the glasses') have none.
 */
const OVER_WALLPAPER = new Set(["home", "lock"]);
// Not the assistant's: it shows the real screen 1:1 for circling - no glass, no tint (docs/DESIGN-LANGUAGE.md).
const TINT_ONLY = new Set(["shade", "recents"]);

function use(g: GlassSource | null) {
  root.classList.toggle("glass-behind", TINT_ONLY.has(mode) && g != null);
  source = OVER_WALLPAPER.has(mode) ? (g?.wallpaper?.url ?? null) : null;
  void refrost();
}

/**
 * Where a surface is, transforms left out: offsets up to the page's root, home's pages each counted at the left
 * edge (a page is laid out a screen to the right of the one before; at rest it's moved back there), what scrolled
 * taken off.
 */
function where(el: HTMLElement): [number, number] | null {
  if (!el.offsetParent && getComputedStyle(el).position !== "fixed") return null;
  let x = 0;
  let y = 0;
  let n: HTMLElement | null = el;
  while (n) {
    if (!n.classList.contains("page")) x += n.offsetLeft;
    y += n.offsetTop;
    const parent = n.offsetParent as HTMLElement | null;
    // What scrolled between this and its offset parent.
    for (let p: HTMLElement | null = n.parentElement; p && p !== parent; p = p.parentElement) {
      x -= p.scrollLeft;
      y -= p.scrollTop;
    }
    if (parent) {
      x += parent.clientLeft;
      y += parent.clientTop;
    }
    n = parent;
  }
  return [x, y];
}

const placed = new WeakMap<HTMLElement, string>();

/** Every glass surface told where it is (only those that moved get new values: a style change is a restyle). */
function place() {
  pending = false;
  if (!root.classList.contains("glass")) return;
  for (const el of document.querySelectorAll<HTMLElement>(SURFACES)) {
    const at = where(el);
    if (!at) continue;
    const b = innerHeight - (at[1] + el.offsetHeight);
    const v = `${at[0]} ${at[1]} ${b}`;
    if (placed.get(el) === v) continue;
    placed.set(el, v);
    el.style.setProperty("--gx", `${at[0]}px`);
    el.style.setProperty("--gy", `${at[1]}px`);
    el.style.setProperty("--gb", `${b}px`);
  }
}

/**
 * Placed once things have stopped moving (SETTLE_MS without a change), in a frame of its own: during a swipe home
 * re-renders its tiles every frame (their style written again), and placing them each time read their layout mid-frame
 * - a second style pass per frame, measured: a dropped frame in eight of the drawer's swipe. A surface's glass moves
 * with it until then, as on a page swipe.
 */
const SETTLE_MS = 120;
let pending = false;
let settleTimer = 0;
function schedule() {
  clearTimeout(settleTimer);
  settleTimer = window.setTimeout(() => {
    if (pending) return;
    pending = true;
    requestAnimationFrame(place);
  }, SETTLE_MS);
}

/**
 * Surfaces come and go, and move (edit mode, a widget resized, the launcher settling open or shut): placed again on
 * the next frame. Not for what changes every frame of a swipe on its own - the openness (--p, --q), the pages' track,
 * the dock folding under the launcher: a surface it moves (the bar) is placed again when the swipe settles. No
 * ResizeObserver either: it fired every frame of the drawer's swipe (the dock's height).
 */
new MutationObserver((records) => {
  if (!root.classList.contains("glass")) return;
  for (const r of records) {
    const t = r.target as HTMLElement;
    // Restyled every frame of a swipe without moving anything's layout: the openness, the pages' track, the screens.
    if (r.attributeName === "style" && t.matches?.("[data-p], [data-q], .page-track, .home, .ai-screen")) continue;
    return schedule();
  }
}).observe(document.documentElement, { subtree: true, childList: true, attributes: true, attributeFilter: ["style", "class"] });

addEventListener("resize", () => {
  // Folded or unfolded: another screen, maybe another picture (the host's copy is per screen) - asked again.
  powos.system.glass().then(use, () => void refrost());
  schedule();
});
// A scroll moves only what's in the scrolled box: the drawer's list, a widget's own - most hold no glass at all.
document.addEventListener(
  "scroll",
  (e) => {
    const t = e.target;
    if (root.classList.contains("glass") && (t === document || (t instanceof Element && t.querySelector(SURFACES)))) schedule();
  },
  { capture: true, passive: true },
);
powos.on("system.glass", use);
nativeGlass.subscribe(() => void refrost());
powos.on("theme.changed", () => setTimeout(() => void refrost(), 0));
powos.system.glass().then(use, () => use(null));

/** For CDP and a browser: frost a picture by hand (`__glass.use(url)`), what's up now. */
(window as unknown as { __glass: object }).__glass = {
  use: (url: string | null) => use(url ? { wallpaper: { url, rev: "manual", source: "manual" }, blurBehind: false } : null),
  get frosted() {
    return frosted;
  },
  place,
  /** The live glass (ui/nativeglass.ts): `__glass.live.native(false)` back to the picture on this page, its state. */
  live: nativeDebug,
};
