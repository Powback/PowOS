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
// Quick Tools (ui/quicktools.tsx) too: a card in a window over any app, the compositor blurring what's under the card
// alone (a region of that window - the app under it, as it is).
// The desktop's home (powos-shell) too: a surface under every window, KWin blurring the wallpaper under its tiles.
const OVER_WALLPAPER = new Set(["home", "quicktools", "desktop"]);
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
  /** Its own compositor radius (--glass-blur-native set on it: PowOS AI's frost, stronger than home's tiles), or 0. */
  blur: number;
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
    blur: parseFloat(cs.getPropertyValue("--glass-blur-native")) || 0,
  };
}

function reshape() {
  shapesDirty = false;
  const next = new Map<Element, Shape>();
  for (const el of document.querySelectorAll<HTMLElement>(SURFACES)) {
    // A surface inside another: a soft fill on that one's glass (theme.css), none of its own.
    if (el.parentElement?.closest(SURFACES)) continue;
    // In the launcher (the pull-up AI panel's cards): soft fills on the launcher frame's glass - the frame's region
    // is the panel's one.
    if (el.closest(".launcher") && !el.classList.contains("launcher-frame")) continue;
    next.set(el, shapeOf(el));
  }
  shapes = next;
  // A surface's size changing with its content (a widget's text, a list growing): measured then, and only then.
  sized.disconnect();
  for (const el of shapes.keys()) sized.observe(el);
}

/** The surfaces' own size changes (their content, not their place: the triggers below see those). */
const sized = new ResizeObserver((es) => (why("resized", es[0]?.target), kick()));

/** How far a joined side reaches into its neighbour (CSS px; ~1.4 device px at 2.76). */
const JOIN_OVERLAP = 0.5;

const f = (n: number) => (Math.round(n * 10) / 10).toString();

/** A surface's region before clipping: its box (joined sides reaching over), what clips it, its corners, its alpha. */
interface Raw {
  /** Left, top, right, bottom on screen (CSS px), the joined sides' overlap in. */
  box: [number, number, number, number];
  /** The element's own box (its corners are cut where a clip or the screen's edge cuts it). */
  own: [number, number, number, number];
  clips: [number, number, number, number][];
  radii: number[];
  alpha: number;
  /** A square region (home's foot strip): no corners. */
  square?: boolean;
  /** The drawer follower (gesture.ts: a [data-p] element under a Web Animation) it moves with, during a drag. */
  follower?: Element;
  /** Which of its clips move with that follower. */
  clipsFollow?: boolean[];
  /** Its own compositor radius, or the theme's (0). */
  blur?: number;
}

/** The theme's blur radius for the compositor, read when the theme or the shapes change (not every frame). */
let blur = 28;
function readBlur() {
  // The compositor's radius, not a Gaussian's sigma: its blur is ~0.15-0.3 of what it's given (measured on the phone,
  // 2026-10-21), so the theme says it on its own (--glass-blur-native); without it, --glass-blur.
  const css = getComputedStyle(root);
  blur = parseFloat(css.getPropertyValue("--glass-blur-native")) || parseFloat(css.getPropertyValue("--glass-blur")) || 28;
}

/** Every surface's region as laid out now (one layout read of each surface, its clips and its fading ancestors). */
function measureRaw(followers: Element[] = []): Raw[] {
  if (shapesDirty) (reshape(), readBlur());
  const out: Raw[] = [];
  // Ancestors are shared (a page's tiles): each one's opacity read once a frame.
  const seen = new Map<Element, number>();
  const opacity = (e: Element) => {
    let o = seen.get(e);
    if (o === undefined) seen.set(e, (o = parseFloat(getComputedStyle(e).opacity) || 0));
    return o;
  };
  const followerOf = (e: Element) => followers.find((f) => f.contains(e));
  for (const [el, s] of shapes) {
    if (!el.isConnected) continue;
    const r = el.getBoundingClientRect();
    if (r.width < 1 || r.height < 1) continue;
    if (!el.checkVisibility({ visibilityProperty: true })) continue;
    // A side joined to a neighbour reaches half a CSS px into it: two regions meeting at a fractional device pixel each
    // antialias the shared edge, and unblurred wallpaper showed through between them as a hairline.
    const [jt, jr, jb, jl] = s.joined;
    let alpha = 1;
    for (const a of s.chain) alpha *= opacity(a);
    // Scaled (home's pages shrink a little as the drawer opens): the corners with it.
    const k = r.width / ((el as HTMLElement).offsetWidth || r.width);
    const follower = followerOf(el);
    out.push({
      box: [r.left - JOIN_OVERLAP * jl, r.top - JOIN_OVERLAP * jt, r.right + JOIN_OVERLAP * jr, r.bottom + JOIN_OVERLAP * jb],
      own: [r.left, r.top, r.right, r.bottom],
      clips: s.clips.map((c) => {
        const q = c.getBoundingClientRect();
        return [q.left, q.top, q.right, q.bottom] as [number, number, number, number];
      }),
      radii: s.radii.map((v) => v * k),
      alpha,
      follower,
      clipsFollow: follower ? s.clips.map((c) => follower.contains(c)) : undefined,
      blur: s.blur,
    });
  }
  // The strip under the bar (home's ::after, the navigation bar's band): square, along the screen's foot.
  const home = document.querySelector<HTMLElement>(".home");
  const foot = home && getComputedStyle(home, "::after");
  // Hidden (display: none - home's foot without a slab), its computed height is still the inset's: no region then.
  if (home && foot && foot.display !== "none" && !home.classList.contains("editing")) {
    const h = parseFloat(foot.height) || 0;
    const r = home.getBoundingClientRect();
    if (h >= 1) out.push({ box: [r.left, r.bottom - h, r.right, r.bottom], own: [r.left, r.bottom - h, r.right, r.bottom], clips: [], radii: [0, 0, 0, 0], alpha: 1, square: true });
  }
  return out;
}

/** The regions as the host wants them: "x y w h tl tr br bl alpha radius" per surface on screen, CSS px. */
/**
 * The viewport, read on resize only: innerWidth/innerHeight/devicePixelRatio bring the page's style and layout up to
 * date when read - in a drag frame, right after gesture.ts set its animations' time, that was a forced style recalc
 * every frame (format's 28 ms a second of a drawer drag on the phone, 2026-10-22).
 */
let view = { w: innerWidth, h: innerHeight, dpr: devicePixelRatio };
addEventListener("resize", () => (view = { w: innerWidth, h: innerHeight, dpr: devicePixelRatio }));

function format(raws: Raw[]): string {
  const W = view.w;
  const H = view.h;
  const out: string[] = [];
  for (const g of raws) {
    if (g.alpha < 0.01) continue;
    let [x0, y0, x1, y1] = g.box;
    for (const k of g.clips) {
      x0 = Math.max(x0, k[0]);
      y0 = Math.max(y0, k[1]);
      x1 = Math.min(x1, k[2]);
      y1 = Math.min(y1, k[3]);
    }
    x0 = Math.max(x0, 0);
    y0 = Math.max(y0, 0);
    x1 = Math.min(x1, W);
    y1 = Math.min(y1, H);
    if (x1 - x0 < 1 || y1 - y0 < 1) continue;
    if (g.square) {
      out.push(`${f(x0)} ${f(y0)} ${f(x1 - x0)} ${f(y1 - y0)} 0 0 0 0 1 ${blur}`);
      continue;
    }
    // A corner cut by a clip is square there (a tile half under the screen's edge keeps its own corners on screen).
    const [tl, tr, br, bl] = g.radii;
    const cut = (edge: boolean, v: number) => (edge ? 0 : v);
    const L = x0 > g.own[0] + 0.25;
    const T = y0 > g.own[1] + 0.25;
    const R = x1 < g.own[2] - 0.25;
    const B = y1 < g.own[3] - 0.25;
    out.push(
      `${f(x0)} ${f(y0)} ${f(x1 - x0)} ${f(y1 - y0)} ${f(cut(L || T, tl))} ${f(cut(R || T, tr))} ${f(cut(R || B, br))} ${f(cut(L || B, bl))} ${g.alpha.toFixed(2)} ${g.blur || blur}`,
    );
  }
  return `${view.dpr} ${out.length}${out.length ? " " + out.join(" ") : ""}`;
}

const measure = () => format(measureRaw());

// ---- the drawer's drag, without measuring each frame ------------------------------------------------------------------
/*
 * While a finger drives the drawer, its followers (gesture.ts: each [data-p] element under a paused Web Animation of
 * its transform and opacity, id "drawer"; let go, a settle animation of the same) are the only things that move. The
 * glass is measured once as the animations appear, and each frame after that is computed from the animations' own
 * keyframes at their currentTime: a follower's transform now against its transform then, about its transform-origin,
 * moves the regions inside it; its opacity scales their alpha. No layout or style read per frame. 2026-10-22: the
 * per-frame measure (a getBoundingClientRect of every surface and its clips, a getComputedStyle of every ancestor's
 * opacity) was the drag's top script cost on the phone, 107 ms a second against gesture.ts's 2.
 */
interface Track {
  anim: Animation;
  el: Element;
  /** Its keyframes, parsed: offset, matrix, opacity (linear between them, as gesture.ts makes them). */
  frames: { at: number; m: DOMMatrix; o: number }[];
  /** Its transform-origin on screen when measured (the point its matrix is about). */
  origin: [number, number];
  base: { m: DOMMatrix; o: number };
}
let tracks: Track[] | null = null;
/** For CDP A/B (`__glass.live.compute(false)`): every drag frame measured from the page, as before. */
let computing = true;
let rawAtStart: Raw[] = [];

const drawerAnims = () => document.getAnimations().filter((a) => a.id === "drawer" && (a.effect as KeyframeEffect | null)?.target);

/** A track's transform and opacity at its animation's currentTime (or at the current computed style if it can't). */
function sample(t: Track): { m: DOMMatrix; o: number } {
  const dur = Number(t.anim.effect?.getTiming().duration) || 0;
  const p = dur > 0 ? Math.min(1, Math.max(0, Number(t.anim.currentTime ?? 0) / dur)) : 1;
  const fs = t.frames;
  let i = 0;
  while (i < fs.length - 2 && fs[i + 1].at < p) i++;
  const a = fs[i];
  const b = fs[Math.min(i + 1, fs.length - 1)];
  const u = b.at > a.at ? Math.min(1, Math.max(0, (p - a.at) / (b.at - a.at))) : 0;
  const mix = (x: number, y: number) => x + (y - x) * u;
  const m = new DOMMatrix([mix(a.m.a, b.m.a), mix(a.m.b, b.m.b), mix(a.m.c, b.m.c), mix(a.m.d, b.m.d), mix(a.m.e, b.m.e), mix(a.m.f, b.m.f)]);
  return { m, o: mix(a.o, b.o) };
}

/** Starts computing the drag's frames: the glass measured once, the followers' animations read. False: can't. */
function track(anims: Animation[]): boolean {
  const list: Track[] = [];
  for (const anim of anims) {
    const fx = anim.effect as KeyframeEffect;
    const el = fx.target as HTMLElement;
    const kf = fx.getKeyframes();
    const frames: Track["frames"] = [];
    for (const k of kf) {
      const tf = typeof k.transform === "string" ? k.transform : "none";
      let m: DOMMatrix;
      try {
        m = new DOMMatrix(tf === "none" ? undefined : tf);
      } catch {
        return false;
      }
      // 2D translate/scale only: anything else (a rotation, 3D) is measured each frame as before.
      if (!m.is2D || Math.abs(m.b) > 1e-6 || Math.abs(m.c) > 1e-6) return false;
      frames.push({ at: Number(k.computedOffset ?? k.offset ?? 0), m, o: k.opacity == null ? 1 : parseFloat(String(k.opacity)) });
    }
    if (frames.length < 1) return false;
    // Where its transform is about: its layout box (untransformed) plus transform-origin.
    const cs = getComputedStyle(el);
    const [ox, oy] = cs.transformOrigin.split(" ").map((v) => parseFloat(v) || 0);
    const r = el.getBoundingClientRect();
    const t: Track = { anim, el, frames, origin: [0, 0], base: { m: new DOMMatrix(), o: 1 } };
    t.base = sample(t);
    // Under scale s about origin O and translate T, a layout point L is on screen at O + T + s*(L - O); O is the
    // layout box's corner plus transform-origin o. The box's corner on screen, r = O + T - s*o, gives O.
    t.origin = [r.left - t.base.m.e + t.base.m.a * ox, r.top - t.base.m.f + t.base.m.d * oy];
    list.push(t);
  }
  tracks = list;
  rawAtStart = measureRaw(list.map((t) => t.el));
  return true;
}

/** A point on screen moved from a track's base state to its state now (translate+scale about its origin). */
function mover(t: Track) {
  const now = sample(t);
  const [Ox, Oy] = t.origin;
  const b = t.base.m;
  const n = now.m;
  // screen = O + T + s*(L - O): from base to now, L = O + (screen - O - Tb)/sb.
  const fx = (x: number) => Ox + n.e + n.a * ((x - Ox - b.e) / (b.a || 1));
  const fy = (y: number) => Oy + n.f + n.d * ((y - Oy - b.f) / (b.d || 1));
  return { fx, fy, k: (n.a || 1) / (b.a || 1), alpha: t.base.o > 0.001 ? now.o / t.base.o : null };
}

/** This frame's regions from the drag's start: none read from the page. Null: measure the page instead. */
function computed(): string | null {
  if (!tracks) return null;
  const movers = new Map<Element, ReturnType<typeof mover>>();
  for (const t of tracks) {
    // A track's animation gone (cancelled at a settle's start, or done): measure again (a new set may be there).
    if (t.anim.playState === "idle" || t.anim.playState === "finished") return (tracks = null);
    movers.set(t.el, mover(t));
  }
  const out: Raw[] = [];
  for (const g of rawAtStart) {
    const mv = g.follower && movers.get(g.follower);
    if (!mv) {
      out.push(g);
      continue;
    }
    // Faded from zero at the start (no ratio to scale by): measured from the page this frame.
    if (mv.alpha == null) return (tracks = null);
    const box = (q: [number, number, number, number]) => [mv.fx(q[0]), mv.fy(q[1]), mv.fx(q[2]), mv.fy(q[3])] as [number, number, number, number];
    out.push({
      ...g,
      box: box(g.box),
      own: box(g.own),
      clips: g.clips.map((c, i) => (g.clipsFollow?.[i] ? box(c) : c)),
      radii: g.radii.map((v) => v * mv.k),
      alpha: g.alpha * mv.alpha,
    });
  }
  return format(out);
}

/** This frame's regions: computed during the drawer's drag, measured otherwise. */
function regions(): string {
  if (!computing) return measure();
  const c = computed();
  if (c != null) return c;
  const anims = drawerAnims();
  if (anims.length && track(anims)) return computed() ?? measure();
  return measure();
}

// ---- when ---------------------------------------------------------------------------------------------------------

/** The last set sent: the same again isn't sent. */
let last = "";
/** Frames in a row the regions didn't change: the loop stops after a few (nothing moves). */
let still = 0;
let running = false;
const STILL_FRAMES = 6;
/** Counters for CDP (`__glass.live.counts`): measured frames and region sets sent to the host. */
const counts = { measured: 0, sent: 0, since: performance.now() };
/** For CDP A/B only (`__glass.live.hold(true)`): measured as ever, but the regions not sent to the host. */
let held = false;

/**
 * Something that can move or fade glass: a surface itself, or an element holding one (its ancestors: the track, the
 * launcher, home). Anything else - a widget's content, the pet, a button's press, an icon - moves no glass, and its
 * style changes, transitions and animations measure nothing. 2026-10-21: every style write anywhere (the pet's
 * transform each frame, the performance widget's numbers) set off a measured frame - a layout read of every surface.
 */
const carries = (t: EventTarget | Node | null | undefined): boolean => {
  const e = t instanceof Element ? t : t instanceof Node ? t.parentElement : null;
  // data-glass-ignore: an overlay that moves on its own and whose glass (the pet's bubble) the host doesn't blur.
  return !!e && !e.closest("[data-glass-ignore]") && (e.matches(SURFACES) || !!e.querySelector(SURFACES));
};
/** A running animation (CSS or a Web Animation, scrubbed or playing) on something that carries glass. */
const moving = () => document.getAnimations().some((a) => a.playState === "running" && carries((a.effect as KeyframeEffect | null)?.target));

function frame() {
  if (!nativeGlass.value) {
    running = false;
    return;
  }
  counts.measured++;
  const text = regions();
  if (text !== last) {
    last = text;
    still = 0;
    if (!held) {
      counts.sent++;
      send(`b.r ${text}`);
    }
  } else {
    still++;
  }
  // Still for a few frames: stop - unless glass is animating (a settle, a fade), which can be still between frames.
  // (While tracking the drawer's animations, they are what's running: no scan of every animation for it.)
  if (still < STILL_FRAMES || (tracks ? tracks.some((t) => t.anim.playState === "running") : moving())) requestAnimationFrame(frame);
  else running = false;
}

/** For CDP (`__glass.live.kicks`): what set off the last measures - the cause and when (a ring of 30). */
const kicks: string[] = [];
const why = (cause: string, t?: EventTarget | Node | null) => {
  if (running) return;
  const e = t instanceof Element ? t : t instanceof Node ? t.parentElement : null;
  const name = e ? e.tagName.toLowerCase() + (typeof e.className === "string" && e.className ? "." + e.className.trim().split(/\s+/).slice(0, 2).join(".") : "") : "";
  kicks.push(`${Math.round(performance.now() / 1000)}s ${cause} ${name}`);
  if (kicks.length > 30) kicks.shift();
};

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
  tracks = null;
  kick();
}

/** A node added or removed is (or holds) a surface. */
const holds = (nodes: NodeList) => {
  for (const n of nodes) if (n instanceof Element && (n.matches(SURFACES) || n.querySelector(SURFACES))) return true;
  return false;
};
new MutationObserver((records) => {
  if (!nativeGlass.value) return;
  let moved = false;
  for (const r of records) {
    if (r.type === "childList") {
      if (holds(r.addedNodes) || holds(r.removedNodes)) return why("nodes", r.target), changed();
      continue;
    }
    if (!carries(r.target)) continue;
    // A surface's own class (its corners, a join): its shape again. A holder's style or class: it may have moved.
    if (r.attributeName === "class" && (r.target as Element).matches(SURFACES)) return why("class", r.target), changed();
    if (!moved) why(r.attributeName ?? "attr", r.target);
    moved = true;
  }
  if (moved) kick();
}).observe(document.documentElement, { subtree: true, childList: true, attributes: true, attributeFilter: ["style", "class"] });

// A finger moving the drawer: measured until still again (gesture.ts scrubs paused animations by currentTime - no
// style written, nothing the observer above sees; its touchmoves are what says it moved). Only then: any other touch
// that moves glass writes a style or class the observer sees (a page swipe's track, the shade's --q, home's
// "dragging"), and a tap, a scroll of the drawer's list, a press on a widget moves none. 2026-10-22: every touch on
// home measured every surface every frame (58 measures a second while the user used home).
const touch = (e: Event) => (tracks || document.querySelector(".home.dragging")) && (why(e.type), kick());
for (const ev of ["touchstart", "touchmove", "touchend", "touchcancel"] as const) addEventListener(ev, touch, { capture: true, passive: true });
document.addEventListener("visibilitychange", () => {
  if (!document.hidden) why("shown"), changed();
});
const animated = (e: Event) => carries(e.target) && (why(e.type, e.target), kick());
for (const ev of ["transitionrun", "transitionend", "transitioncancel", "animationstart", "animationend"]) addEventListener(ev, animated, { capture: true, passive: true });
addEventListener("resize", () => (why("resize"), changed()));
// A scroll moves only what's in the scrolled box: the drawer's list holds no glass (the launcher's is its frame's), so
// its scroll measures nothing - nothing re-sent, nothing re-read, a frame of the list is the list's alone.
document.addEventListener(
  "scroll",
  (e) => {
    const t = e.target;
    if (t === document || (t instanceof Element && t.querySelector(SURFACES))) why("scroll", t instanceof Node ? t : null), kick();
  },
  { capture: true, passive: true },
);
for (const ev of ["theme.changed", "system.insets", "recents.begin", "recents.drag", "recents.end", "recents.show", "recents.hide"]) powos.on(ev, () => (why(ev), (tracks = null), changed()));

/** For CDP: on or off for this page (`__glass.native(false)`: the CSS glass), the regions as sent, the host's knob. */
export const debug = {
  native: (on: boolean) => void (wanted.value = on),
  liquid: (on: boolean) => void (liquidWanted.value = on),
  get state(): { native: boolean; host: boolean; port: boolean; last: string } {
    return { native: nativeGlass.value, host: hostBlurs.value, port: !!native.value, last };
  },
  measure,
  /** This frame's regions as sent (computed during a drawer drag) and whether a drag is being computed. */
  regions,
  get tracking() {
    return !!tracks;
  },
  lag: (frames: number) => send(`b.lag ${frames}`),
  hold: (on: boolean) => void (held = on),
  compute: (on: boolean) => void ((computing = on), (tracks = null)),
  /** What set off the last measures (cause, element), oldest first. */
  get kicks() {
    return [...kicks];
  },
  /** Measured frames and region sets sent per second since the last read (and reset). */
  get counts() {
    const secs = (performance.now() - counts.since) / 1000;
    const out = { secs: +secs.toFixed(1), measuredPerSec: +(counts.measured / secs).toFixed(2), sentPerSec: +(counts.sent / secs).toFixed(2) };
    counts.measured = counts.sent = 0;
    counts.since = performance.now();
    return out;
  },
};
