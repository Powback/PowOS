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
const SURFACES = ".tile, .notif-panel, .assist-panel";

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
 * and the switcher's windows have what's behind them blurred by the host (tint only). The assistant's is over the
 * screen it circles on, which stays 1:1: only its chrome (the panel) is glass - frosted from the screenshot of that
 * same screen, so what's under the panel is what its frost shows (docs/DESIGN-LANGUAGE.md, the exception); live (the
 * screen moving under it), none. The rest (the screen-off clock, the glasses') have none.
 */
// The desktop's home (powos-shell) draws its own wallpaper (ui/desktop.tsx): its tiles frost that picture too.
const OVER_WALLPAPER = new Set(["home", "lock", "desktop"]);
const CHROME = new Set(["windowbar", "windowgrip", "statusbar"]);
const TINT_ONLY = new Set(["shade", "recents", "pull", "quicktools", ...CHROME]);

let lastSource: GlassSource | null = null;
/** The assistant's: the screen it was opened over (its screenshot), and whether it's live (then no picture). */
let assistShot: string | null = null;
let assistLive = false;

/**
 * The wallpaper's tone (html[data-wallpaper] light | dark): its picture's mean luminance, read small once per picture.
 * A theme on a wallpaper of the other tone (dark glass over a bright picture, light glass over a dark one) needs more
 * tint for its text to keep 4.5:1 (theme.css); without a picture, none is set and the reference stays as it is.
 */
let toneFor: string | null = null;
let toneOf: string | null = null;
/**
 * Which wallpaper a picture is of: its URL, but a live wallpaper's every frame is another picture (ShellWallpaper.kt:
 * rev "live-<component>-<fingerprint>", read again on every resume and 2.5 s later). The frame captured as home came
 * back from an app toned the theme the other way until the next one (the user, 10-31 20:08: "When I return home from
 * an app, the theme is fucked up for a moment" - dark labels with a white halo, a light search bar: data-wallpaper
 * flipped to light). The tone is the wallpaper's, read from its first picture; another frame keeps it.
 */
function wallpaperOf(w: GlassSource["wallpaper"]): string | null {
  const live = w?.source === "live" ? /^live-(-?\d+)-/.exec(w.rev) : null;
  return live ? `live-${live[1]}` : (w?.url ?? null);
}
/** The picture's mean luminance (0..1), read small. */
async function luminance(url: string) {
  const img = new Image();
  img.src = url;
  await img.decode();
  const c = document.createElement("canvas");
  c.width = c.height = 16;
  const x = c.getContext("2d", { willReadFrequently: true })!;
  x.drawImage(img, 0, 0, 16, 16);
  const d = x.getImageData(0, 0, 16, 16).data;
  let l = 0;
  for (let i = 0; i < d.length; i += 4) l += 0.2126 * d[i] + 0.7152 * d[i + 1] + 0.0722 * d[i + 2];
  return l / 256 / 255;
}
/**
 * The luminances of a wallpaper's pictures read so far (its last [FRAMES] frames), and its tone from their median - not
 * from one frame. A live wallpaper's frame is the compositor's capture of it, and when the wallpaper's own mirror comes
 * back black the capture is of the whole display minus home (WallpaperBackdrop.still -> displayStill): read on a resume
 * while the closing app's window is still on the screen, that "wallpaper" is the app (a light one) - and the tone kept
 * from it stayed light over the dark wallpaper until the next wallpaper (the user, 11-01 22:27 "I still get a theme glitch
 * sometimes when I close the app", 22:28 screenshot: dark widget text, the search bar a light slab - data-wallpaper
 * "light" under a dark theme). One odd frame now never flips it, and a wrong first one is outvoted by the next two.
 */
const FRAMES = 7;
/** Hysteresis round 0.5: the median has to clear it by this much to turn the tone round (no flicker on a mid picture). */
const BAND = 0.05;
let seen: number[] = [];
function toneFrom(cur: string | undefined): "light" | "dark" {
  const s = [...seen].sort((a, b) => a - b);
  const n = s.length;
  const m = n % 2 ? s[(n - 1) / 2] : (s[n / 2 - 1] + s[n / 2]) / 2;
  if (cur === "light") return m < 0.5 - BAND ? "dark" : "light";
  if (cur === "dark") return m > 0.5 + BAND ? "light" : "dark";
  return m > 0.5 ? "light" : "dark";
}
async function tone(url: string | null, of: string | null = url, source = "") {
  if (url === toneFor) return;
  const another = of !== toneOf;
  toneFor = url;
  toneOf = of;
  if (another) seen = [];
  if (!url) return void delete root.dataset.wallpaper;
  const l = await luminance(url).catch(() => null);
  if (toneFor === url) toned(l, another, `${source} ${of}`);
}
/** A frame's luminance (null: unreadable) counted in: a new wallpaper toned afresh, another frame by the median. */
function toned(l: number | null, fresh: boolean, what: string) {
  if (l == null) return void (seen.length || delete root.dataset.wallpaper);
  seen = [...seen.slice(1 - FRAMES), l];
  const was = root.dataset.wallpaper;
  const t = toneFrom(fresh ? undefined : was);
  if (t !== was) console.log(`glass tone ${was ?? "-"} -> ${t}: ${what} l=${l.toFixed(2)} frames=[${seen.map((v) => v.toFixed(2))}]`);
  root.dataset.wallpaper = t;
}

/** What the page tones by (its wallpaper's picture), when it's over the wallpaper or is chrome over it. */
const tonedBy = (g: GlassSource | null) => (OVER_WALLPAPER.has(mode) || CHROME.has(mode) ? (g?.wallpaper ?? null) : null);
/** What the page frosts: the wallpaper over it, the assistant's screen it was opened over. */
const frostedBy = (g: GlassSource | null) => (OVER_WALLPAPER.has(mode) ? (g?.wallpaper?.url ?? null) : mode === "assist" && !assistLive ? assistShot : null);

function use(g: GlassSource | null) {
  lastSource = g;
  const w = tonedBy(g);
  void tone(w?.url ?? null, wallpaperOf(w), w?.source ?? "");
  root.classList.toggle("glass-behind", TINT_ONLY.has(mode) && g != null);
  source = frostedBy(g);
  void refrost();
}

if (mode === "assist") {
  const shot = (s: { screenshot?: string | null } | null) => {
    assistShot = s?.screenshot ?? null;
    use(lastSource);
  };
  powos.on("assist.context", shot);
  // A new summoning: last time's screen is gone until this one's arrives.
  powos.on("assist.reset", () => shot(null));
  powos.on("assist.live", (l: { on: boolean }) => {
    assistLive = !!l?.on;
    use(lastSource);
  });
  powos.assist?.screen?.().then(shot, () => {});
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

let placed = new WeakMap<HTMLElement, string>();

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
}).observe(document.documentElement, { subtree: true, childList: true, attributes: true, attributeFilter: ["style", "class"], characterData: true });

// The lock face's cards come, go and change while it's up (a notification arrives, one is cleared): their frost is
// placed again when the list's box resizes, and when the face is shown again (the cards moved while it was hidden,
// where nothing laid out) - not only on a mutation, which a hidden window's frame never turned into a placement.
if (mode === "lock") {
  const again = () => {
    placed = new WeakMap();
    schedule();
  };
  const watch = new ResizeObserver(again);
  const hook = () => {
    const l = document.querySelector(".lock-notes");
    if (l) watch.observe(l);
  };
  new MutationObserver(hook).observe(document.body, { childList: true, subtree: true });
  hook();
  powos.on("lock.shown", again);
  document.addEventListener("visibilitychange", again);
  addEventListener("pageshow", again);
  addEventListener("focus", again);
}

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

/**
 * Evidence for the next wrong-theme return (the user, 11-01 22:27, intermittent): on every return of home, its theme as
 * the first 5 frames, 1 s and 5 s after drew it - the tone, the theme, the glass, a widget's text and the search bar's
 * fill - each that differs from the 5 s one logged as a "theme mismatch" (stuck when the 5 s one is the odd one out is
 * shown by the tone log above; a short flash, by frames only).
 */
function probeTheme() {
  const css = (sel: string, prop: "color" | "backgroundColor") => {
    const el = document.querySelector(sel);
    return el ? getComputedStyle(el)[prop] : "-";
  };
  const state = () =>
    [root.dataset.light ?? "-", root.dataset.wallpaper ?? "-", root.classList.contains("glass") ? "glass" : "plain", css(".page .home-tile > .tile", "color"), css(".home > .bar .bar-pill", "backgroundColor")].join(" ");
  const t0 = performance.now();
  const got: [number, string][] = [];
  const take = () => got.push([Math.round(performance.now() - t0), state()]);
  let n = 0;
  const frame = () => {
    take();
    if (++n < 5) requestAnimationFrame(frame);
  };
  requestAnimationFrame(frame);
  setTimeout(take, 1000);
  setTimeout(() => {
    const steady = state();
    const odd = got.filter(([, s]) => s !== steady);
    if (odd.length) console.warn(`theme mismatch after resume: steady(5s)=[${steady}] ${odd.map(([t, s]) => `${t}ms=[${s}]`).join(" ")}`);
  }, 5000);
}
if (mode === "home") document.addEventListener("visibilitychange", () => document.visibilityState === "visible" && probeTheme());
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
  /** The wallpaper's tone only (no picture glass): what a page under the compositor's glass is told. */
  tone: (url: string | null) => tone(url),
  /** The live glass (ui/nativeglass.ts): `__glass.live.native(false)` back to the picture on this page, its state. */
  live: nativeDebug,
};
