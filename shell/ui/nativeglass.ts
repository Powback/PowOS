/**
 * Live glass: the display compositor blurs what's behind each glass surface (GlassBlur.kt: SurfaceFlinger's blur
 * regions on the page's window), and the page only tints them (theme.css: html.glass-native). Nothing is blurred in
 * the WebView, live or once: the wallpaper - a live one too - shows through blurred, as it is, as the surfaces move.
 *
 * The host says over the native port whether the compositor blurs for this page ("b.state 1|0": the style's switch,
 * Android's own - battery saver turns window blurs off -, an Android without the call); while it doesn't, ui/glass.ts
 * frosts its picture of the wallpaper as before (the rollback: Style "glass.live-blur" off, or `__glass.native(false)`
 * from CDP for this page only).
 *
 * The page sends where its surfaces are as rounded rectangles on the screen ("b.r ..."), every frame while anything
 * moves (a swipe, a transition, a panel sliding) and once when they come, go or change - nothing while home is still.
 * The host applies each set on the window's next drawn frame, the frame that shows the page as it was measured.
 */
import { signal } from "@preact/signals";
import { fromNative, native, send } from "../apps/native.ts";
import { powos } from "../bridge.ts";

const root = document.documentElement;
const mode = new URLSearchParams(location.search).get("mode") ?? "home";
/**
 * Pages whose window is over the wallpaper and nothing else: what's behind it is what the glass shows. Home only - the
 * lock face's window can be over an app (its glass would blur the app, not the wallpaper): it keeps the picture.
 */
const OVER_WALLPAPER = new Set(["home"]);
/** The surfaces with glass (theme.css): one inside another is only a soft fill on it, not glass of its own. */
const SURFACES = ".tile, .notif-panel";

/** The host blurs for this page (b.state 1). */
const hostBlurs = signal(false);
/** CDP's override for this page: false keeps the CSS glass whatever the host says. */
const wanted = signal(true);
/** The live glass is on: ui/glass.ts leaves its picture off, theme.css tints only. */
export const nativeGlass = signal(false);

/**
 * The liquid edges (LiquidGlass.kt): only from a host that bends the live wallpaper ("b.backdrop live":
 * WallpaperBackdrop.kt, the compositor's capture of the wallpaper's own surface). An older one bent OxygenOS's
 * screenshot of the video wallpaper, never the frame on screen - a grey frame inside every surface - so without that
 * word, none. `__glass.live.liquid(false)` from CDP turns them off for this page.
 */
// OFF by default (2026-10-21 08:53): the user found the refraction "a bit broken, looks weird" (smears, fringes,
// seams) - "less is more". Calm plain frost until the design agent signs off on a reviewed contact sheet.
const liquidWanted = signal(false);
const liveBackdrop = signal(false);
fromNative.add((text) => {
  if (text === "b.backdrop live") liveBackdrop.value = true;
});
liveBackdrop.subscribe(() => sendLook());

/** Liquid glass's look, from the theme (theme.css --liquid-*), to the host: on with the live glass, again per theme. */
function sendLook() {
  if (!nativeGlass.value) return;
  const css = getComputedStyle(root);
  // A theme without the tokens (an older theme.css): theme.css's own defaults.
  const n = (name: string, fallback: number) => {
    const v = parseFloat(css.getPropertyValue(name));
    return Number.isFinite(v) ? v : fallback;
  };
  const on = liquidWanted.value && liveBackdrop.value;
  send(`b.liquid ${devicePixelRatio} ${on ? n("--liquid-band", 14) : 0} ${n("--liquid-refraction", 9)} ${n("--liquid-rim", 0.5)} ${n("--liquid-dispersion", 0.25)}`);
}
powos.on("theme.changed", () => setTimeout(sendLook, 0));
liquidWanted.subscribe(() => sendLook());

function update() {
  const on = OVER_WALLPAPER.has(mode) && hostBlurs.value && wanted.value && !!native.value;
  if (on === nativeGlass.value) return;
  nativeGlass.value = on;
  root.classList.toggle("glass-native", on);
  last = "";
  sendLook();
  if (on) kick();
  else send("b.r 1 0");
}

fromNative.add((text) => {
  if (!text.startsWith("b.state ")) return;
  hostBlurs.value = text.endsWith("1");
  update();
});
native.subscribe((p) => {
  if (p && OVER_WALLPAPER.has(mode)) send("b.hello");
  update();
});
wanted.subscribe(update);

// ---- where the surfaces are -------------------------------------------------------------------------------------------

/** What doesn't change from frame to frame about a surface: its corners, what clips it (re-read when things change). */
interface Shape {
  radii: [number, number, number, number];
  /** Ancestors that clip it (overflow other than visible). */
  clips: Element[];
  /** Ancestors (and itself) whose opacity can fade it. */
  chain: Element[];
  /** Sides joined to a neighbour (a merged widget group: --jt/--jr/--jb/--jl), top, right, bottom, left: 1 or 0. */
  joined: [number, number, number, number];
}
let shapes = new Map<Element, Shape>();
let shapesDirty = true;

function shapeOf(el: HTMLElement): Shape {
  const cs = getComputedStyle(el);
  const r = (v: string) => parseFloat(v) || 0;
  const clips: Element[] = [];
  const chain: Element[] = [el];
  for (let p = el.parentElement; p && p !== document.body; p = p.parentElement) {
    chain.push(p);
    const s = getComputedStyle(p);
    if (s.overflowX !== "visible" || s.overflowY !== "visible" || s.clipPath !== "none") clips.push(p);
  }
  const j = (side: string) => (parseFloat(cs.getPropertyValue(`--j${side}`)) >= 1 ? 1 : 0);
  return {
    radii: [r(cs.borderTopLeftRadius), r(cs.borderTopRightRadius), r(cs.borderBottomRightRadius), r(cs.borderBottomLeftRadius)],
    clips,
    chain,
    joined: el.parentElement?.classList.contains("joined") ? [j("t"), j("r"), j("b"), j("l")] : [0, 0, 0, 0],
  };
}

function reshape() {
  shapesDirty = false;
  const next = new Map<Element, Shape>();
  for (const el of document.querySelectorAll<HTMLElement>(SURFACES)) {
    // A surface inside another: a soft fill on that one's glass (theme.css), none of its own.
    if (el.parentElement?.closest(SURFACES)) continue;
    // In the launcher (the pull-up AI panel's cards): soft fills on the launcher frame's glass, under a clip-path that
    // cuts them away mid-swipe - a region of their own blurred blobs above the rising frame.
    if (el.closest(".launcher")) continue;
    next.set(el, shapeOf(el));
  }
  shapes = next;
}

/** How far a joined side reaches into its neighbour (CSS px; ~1.4 device px at 2.76). */
const JOIN_OVERLAP = 0.5;

const f = (n: number) => (Math.round(n * 10) / 10).toString();

/** The regions as the host wants them: "x y w h tl tr br bl alpha radius" per surface on screen, CSS px. */
function measure(): string {
  if (shapesDirty) reshape();
  const W = innerWidth;
  const H = innerHeight;
  // The compositor's radius, not a Gaussian's sigma: its blur is ~0.15-0.3 of what it's given (measured on the phone,
  // 2026-10-21), so the theme says it on its own (--glass-blur-native); without it, --glass-blur.
  const css = getComputedStyle(root);
  const blur = parseFloat(css.getPropertyValue("--glass-blur-native")) || parseFloat(css.getPropertyValue("--glass-blur")) || 28;
  const out: string[] = [];
  let n = 0;
  // Ancestors are shared (a page's tiles): each one's opacity read once a frame.
  const seen = new Map<Element, number>();
  const opacity = (e: Element) => {
    let o = seen.get(e);
    if (o === undefined) seen.set(e, (o = parseFloat(getComputedStyle(e).opacity) || 0));
    return o;
  };
  for (const [el, s] of shapes) {
    if (!el.isConnected) continue;
    let r = el.getBoundingClientRect();
    if (r.width < 1 || r.height < 1) continue;
    // A side joined to a neighbour reaches half a CSS px into it: two regions meeting at a fractional device pixel each
    // antialias the shared edge, and unblurred wallpaper showed through between them as a hairline.
    const [jt, jr, jb, jl] = s.joined;
    let x0 = r.left - JOIN_OVERLAP * jl;
    let y0 = r.top - JOIN_OVERLAP * jt;
    let x1 = r.right + JOIN_OVERLAP * jr;
    let y1 = r.bottom + JOIN_OVERLAP * jb;
    for (const c of s.clips) {
      const k = c.getBoundingClientRect();
      x0 = Math.max(x0, k.left);
      y0 = Math.max(y0, k.top);
      x1 = Math.min(x1, k.right);
      y1 = Math.min(y1, k.bottom);
    }
    x0 = Math.max(x0, 0);
    y0 = Math.max(y0, 0);
    x1 = Math.min(x1, W);
    y1 = Math.min(y1, H);
    if (x1 - x0 < 1 || y1 - y0 < 1) continue;
    if (!el.checkVisibility({ visibilityProperty: true })) continue;
    let alpha = 1;
    for (const a of s.chain) alpha *= opacity(a);
    if (alpha < 0.01) continue;
    // Scaled (home's pages shrink a little as the drawer opens): the corners with it.
    const k = r.width / ((el as HTMLElement).offsetWidth || r.width);
    // A corner cut by a clip is square there (a tile half under the screen's edge keeps its own corners on screen).
    const [tl, tr, br, bl] = s.radii.map((v) => v * k);
    const cut = (edge: boolean, v: number) => (edge ? 0 : v);
    const L = x0 > r.left + 0.25;
    const T = y0 > r.top + 0.25;
    const R = x1 < r.right - 0.25;
    const B = y1 < r.bottom - 0.25;
    out.push(
      `${f(x0)} ${f(y0)} ${f(x1 - x0)} ${f(y1 - y0)} ${f(cut(L || T, tl))} ${f(cut(R || T, tr))} ${f(cut(R || B, br))} ${f(cut(L || B, bl))} ${alpha.toFixed(2)} ${blur}`,
    );
    n++;
  }
  // The strip under the bar (home's ::after, the navigation bar's band): square, along the screen's foot.
  const home = document.querySelector<HTMLElement>(".home");
  const foot = home && getComputedStyle(home, "::after");
  // Hidden (display: none - home's foot without a slab), its computed height is still the inset's: no region then.
  if (home && foot && foot.display !== "none" && !home.classList.contains("editing")) {
    const h = parseFloat(foot.height) || 0;
    const r = home.getBoundingClientRect();
    const x0 = Math.max(r.left, 0);
    const w = Math.min(r.right, W) - x0;
    // Off screen (home slid aside for PowOS AI's page): none.
    if (h >= 1 && w >= 1) {
      out.push(`${f(x0)} ${f(r.bottom - h)} ${f(w)} ${f(h)} 0 0 0 0 1 ${blur}`);
      n++;
    }
  }
  return `${devicePixelRatio} ${n}${out.length ? " " + out.join(" ") : ""}`;
}

// ---- when ---------------------------------------------------------------------------------------------------------

/** The last set sent: the same again isn't sent. */
let last = "";
/** Frames in a row the regions didn't change: the loop stops after a few (nothing moves). */
let still = 0;
let running = false;
let fingers = 0;
let transitions = 0;
const STILL_FRAMES = 6;

function frame() {
  if (!nativeGlass.value) {
    running = false;
    return;
  }
  const text = measure();
  if (text !== last) {
    last = text;
    still = 0;
    send(`b.r ${text}`);
  } else {
    still++;
  }
  // A transition that never ended (its element went) can't keep the loop running.
  if (still >= STILL_FRAMES && transitions > 0 && !document.getAnimations().some((a) => a.playState === "running")) transitions = 0;
  if (still < STILL_FRAMES || fingers > 0 || transitions > 0) requestAnimationFrame(frame);
  else running = false;
}

/** Something may move: measured every frame until it's still. */
function kick() {
  still = 0;
  if (running || !nativeGlass.value) return;
  running = true;
  requestAnimationFrame(frame);
}

/** Surfaces came, went or restyled: their shapes again, then measured. */
function changed() {
  shapesDirty = true;
  kick();
}

/** A node added or removed is (or holds) a surface. */
const holds = (nodes: NodeList) => {
  for (const n of nodes) if (n instanceof Element && (n.matches(SURFACES) || n.querySelector(SURFACES))) return true;
  return false;
};
new MutationObserver((records) => {
  if (!nativeGlass.value) return;
  for (const r of records) {
    // A clock's text, a widget's frame: nothing that has glass came or went.
    if (r.type === "childList" ? holds(r.addedNodes) || holds(r.removedNodes) : r.attributeName === "class" || (r.target as Element).matches(SURFACES)) return changed();
  }
  kick();
}).observe(document.documentElement, { subtree: true, childList: true, attributes: true, attributeFilter: ["style", "class"] });

// Fingers down: measured every frame until they're up (the event's own count - one lost end can't leave it running).
const touch = (e: TouchEvent) => ((fingers = e.touches.length), kick());
for (const ev of ["touchstart", "touchmove", "touchend", "touchcancel"] as const) addEventListener(ev, touch, { capture: true, passive: true });
document.addEventListener("visibilitychange", () => {
  fingers = 0;
  transitions = 0;
  if (!document.hidden) changed();
});
addEventListener("transitionrun", () => (transitions++, kick()), { capture: true, passive: true });
const settled = () => ((transitions = Math.max(0, transitions - 1)), kick());
addEventListener("transitionend", settled, { capture: true, passive: true });
addEventListener("transitioncancel", settled, { capture: true, passive: true });
addEventListener("animationstart", kick, { capture: true, passive: true });
addEventListener("resize", changed);
document.addEventListener("scroll", kick, { capture: true, passive: true });
for (const ev of ["theme.changed", "system.insets", "recents.begin", "recents.drag", "recents.end", "recents.show", "recents.hide"]) powos.on(ev, changed);

/** For CDP: on or off for this page (`__glass.native(false)`: the CSS glass), the regions as sent, the host's knob. */
export const debug = {
  native: (on: boolean) => void (wanted.value = on),
  liquid: (on: boolean) => void (liquidWanted.value = on),
  get state(): { native: boolean; host: boolean; port: boolean; last: string } {
    return { native: nativeGlass.value, host: hostBlurs.value, port: !!native.value, last };
  },
  measure,
  lag: (frames: number) => send(`b.lag ${frames}`),
};
