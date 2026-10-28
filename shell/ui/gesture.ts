/**
 * Home's swipes, following the finger like a stock launcher's:
 *
 * - Up anywhere on home: the drawer slides up under the finger; released past 15% of the way, or flicked up (even a
 *   short flick), it opens, else it falls back.
 * - Pulled on past open (or up again at the end of the open drawer's list): stage 2 (overpull.ts), the search and
 *   the keyboard.
 * - Down on the open drawer - from the top of its list, or anywhere outside the list - drags it closed the same way.
 *   A list that's scrolled down just scrolls.
 * - Sideways on home: the pages slide under the finger and snap to the next one past a quarter of the width or a flick.
 * - Down on home: the system shade's window (ShadeHost, mode=shade) - the host takes that finger itself on its gesture
 *   input, as from the status bar over an app ([shadeTakesHome]); home has no notification panel of its own.
 * - The shade's page (shade.tsx) uses these too: up on its panel - from the bottom of its list, or outside the list -
 *   drags it shut, sideways switches notifications / control center.
 *
 * A gesture is only claimed once its direction is clear (SLOP), so taps, long presses (moving and resizing tiles),
 * the drawer's scrolling and the A-Z bar keep their touches. Touch events, not pointer events: those end in a
 * pointercancel once the browser scrolls something.
 */
import { computed, effect, signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import { dropKeyboard } from "./keyboard.ts";
import { overPull, overRelease } from "./overpull.ts";
import { inWindow } from "./desktops.ts";
import { ccEditing, ccExpanded, EXPAND_AT, settle as settleCc, stretch as stretchCc } from "./ccexpand.ts";
import { carry, closeDrawer, dockDrag, drawer, editing, folder, menu, notif, onLibrary, page, pageCount, panel, pullKind, pullPanels, selected, separatePanels } from "../state.ts";

const SLOP = 10;
/** Page swipe (iOS/Android launcher rule): commit past this share of a page's width, or on a clear flick. */
const PAGE_AT = 0.3;
/** A clear page flick: release speed (px/ms, over the last PAGE_V_WINDOW ms) after at least this many px. */
const PAGE_FLICK = 0.3;
const PAGE_FLICK_MIN = 16;
const PAGE_V_WINDOW = 50;
/** Axis lock, decided at SLOP: vertical only when clearly so (> ~54 deg off the horizontal), so a diagonal swipe pages. */
const VERTICAL_RATIO = 1.4;
/** px per ms: a flick, whatever the distance. */
const FLICK = 0.45;
/** Up, opening the drawer: a short flick is enough (px per ms), or past this much of the way. */
const OPEN_FLICK = 0.2;
const OPEN_AT = 0.15;
/** Down, closing it: let go above this much open and it stays open - half the (short, shell.css --rise) way: ~45 px
    of finger at 15vh and 1.5x, about what 2/3 of the old 30vh rise took. */
const CLOSE_KEEP = 0.5;
/** The drawer moves this much faster than the finger (clamped at the top): it covers its rise in 2/3 of the swipe. */
const GAIN = 1.5;
/** The notification panel's / control center's open travel (shell.css --drop, px), as the drawer's --rise. */
const dropOf = () => {
  const p = document.querySelector<HTMLElement>(".notif-panel");
  return (p && parseFloat(getComputedStyle(p).getPropertyValue("--drop"))) || innerHeight * 0.15;
};
/** What takes a tap in the launcher; a tap anywhere else in it closes it. */
const TAPPABLE = ".app, .letter-bar, .msg, .chat-head, button, input, textarea, a, .menu, .tile, [role=button], [role=slider]";

/** While a finger drags the drawer: its openness, 0..1; null otherwise (then the drawer signal decides). */
export const drawerDrag = signal<number | null>(null);
/** While a finger drags the notification panel: its openness, 0..1; null otherwise (then the notif signal decides). */
export const notifDrag = signal<number | null>(null);
/** The notification panel's openness on screen: dragged, or settled. */
export const notifShown = () => notifDrag.value ?? (notif.value ? 1 : 0);
export const notifOpen = computed(() => notifShown() > 0);
export const notifDragging = computed(() => notifDrag.value != null);
/**
 * The host takes a pull down on home itself (shade.homePull answered true): home claims nothing for it. False (no
 * gesture input): a swipe down on home asks for the shade (shade.open), not following the finger.
 */
export const shadeTakesHome = signal(true);
/**
 * Something picked up by a long press and dragged (the control center's tiles, control.tsx useReorder): the finger is
 * its own - a pull, a close or a page swipe under way lets go of it.
 */
export const held = signal(false);
/** While a finger drags the pages: their offset in px; null otherwise. */
export const pageDrag = signal<number | null>(null);

// The page, the shade/control panel opening or switching: the same, whatever started it (a swipe, a tap, the bridge).
let seen = "";
effect(() => {
  const now = `${page.value}|${notif.value}|${panel.value}`;
  if (seen && now !== seen) dropKeyboard();
  seen = now;
});

/** The drawer's openness on screen: dragged, or settled. */
export const drawerShown = () => drawerDrag.value ?? (drawer.value > 0 ? 1 : 0);

/**
 * What rendering reads - whether the drawer shows at all, whether a finger holds it - changes a few
 * times a gesture. The openness itself changes every frame of it, and goes straight to the elements that follow it
 * (data-p: their --p; .page-track: its transform), never through a render: a render per frame of a swipe rebuilt the
 * drawer's every app and home's every tile.
 */
export const drawerOpen = computed(() => drawerShown() > 0);
export const drawerDragging = computed(() => drawerDrag.value != null || notifDrag.value != null);

/*
 * A finger on the drawer drives Web Animations, not --p: each element that follows it ([data-p]) gets one paused
 * animation of its transform and opacity, its keyframes read once from its own CSS (shell.css: what --p 0..1 gives it),
 * and the finger only sets their currentTime - nothing restyled through a custom property each frame. Let go, it
 * settles along the same curve as a --p transition (180 ms, shell.css [data-p]), then --p takes over at rest. Opened
 * or closed without a finger (a tap, Back, a launch), --p's own transition still does it.
 */
const SPAN = 1000;
const SAMPLES = 41;
const SETTLE_MS = 180;
const SETTLE_CURVE = [0.1, 0.8, 0.2, 1] as const;
interface Follower {
  el: HTMLElement;
  /** Its transform and opacity at --p 0, 1/40, ... 1. */
  table: Keyframe[];
  anim: Animation;
}
let followers: Follower[] | null = null;
/** Keyframes per element, kept while its size and home's foot layout stay as they were. */
const tables = new WeakMap<HTMLElement, { key: string; table: Keyframe[] }>();

function tableOf(el: HTMLElement): Keyframe[] {
  const key = `${innerWidth}x${innerHeight} ${el.offsetWidth}x${el.offsetHeight} ${el.closest(".home")?.classList.contains("pill-below")} ${el.closest(".home")?.classList.contains("search-parked")} ${document.querySelector(".home")?.className.match(/dock-(bottom|left|right)/)?.[0]}`;
  const had = tables.get(el);
  if (had?.key === key) return had.table;
  const st = el.style;
  const [p0, t0] = [st.getPropertyValue("--p"), st.transition];
  st.transition = "none";
  const table: Keyframe[] = [];
  for (let i = 0; i < SAMPLES; i++) {
    const p = i / (SAMPLES - 1);
    st.setProperty("--p", String(p));
    const cs = getComputedStyle(el);
    table.push({ offset: p, transform: cs.transform, opacity: cs.opacity });
  }
  st.setProperty("--p", p0);
  st.transition = t0;
  tables.set(el, { key, table });
  return table;
}

/** The settle curve's progress at time fraction t (a CSS cubic-bezier with these control points). */
function bezier(t: number) {
  const [x1, y1, x2, y2] = SETTLE_CURVE;
  const at = (s: number, a: number, b: number) => 3 * a * s * (1 - s) ** 2 + 3 * b * s * s * (1 - s) + s ** 3;
  // The curve's own parameter for time t (x is monotonic): bisection is plenty for keyframe offsets.
  let lo = 0;
  let hi = 1;
  for (let i = 0; i < 24; i++) {
    const m = (lo + hi) / 2;
    if (at(m, x1, x2) < t) lo = m;
    else hi = m;
  }
  return at((lo + hi) / 2, y1, y2);
}
/** When along the settle (0..1 of its time) it has come fraction f of the way: bezier's inverse. */
function settleAt(f: number) {
  let lo = 0;
  let hi = 1;
  for (let i = 0; i < 24; i++) {
    const m = (lo + hi) / 2;
    if (bezier(m) < f) lo = m;
    else hi = m;
  }
  return (lo + hi) / 2;
}

function follow(p: number) {
  if (!followers) {
    for (const el of document.querySelectorAll<HTMLElement>("[data-p]")) el.getAnimations().forEach((a) => a.id === "drawer" && a.cancel());
    followers = [...document.querySelectorAll<HTMLElement>("[data-p]")].map((el) => {
      const table = tableOf(el);
      const anim = el.animate(table, { duration: SPAN, fill: "both", easing: "linear", id: "drawer" });
      anim.pause();
      return { el, table, anim };
    });
  }
  for (const f of followers) f.anim.currentTime = p * SPAN;
}

/** Let go at p: from there to `to` along the settle curve, then --p (at `to` already, under it) shows through. */
function settle(p: number, to: number) {
  const list = followers!;
  followers = null;
  for (const { el, table, anim } of list) {
    const now = getComputedStyle(el);
    const frames: Keyframe[] = [{ offset: 0, transform: now.transform, opacity: now.opacity }];
    const span = to - p;
    for (const k of table) {
      const f = span === 0 ? 1 : ((k.offset as number) - p) / span;
      if (f > 0 && f < 1) frames.push({ ...k, offset: settleAt(f) });
    }
    frames.sort((a, b) => (a.offset as number) - (b.offset as number));
    frames.push({ ...table[Math.round(to * (SAMPLES - 1))], offset: 1 });
    anim.cancel();
    el.style.transition = "none";
    el.style.setProperty("--p", String(to));
    const done = el.animate(frames, { duration: span === 0 ? 0 : SETTLE_MS, easing: "linear", id: "drawer" });
    done.finished.then(
      () => {
        done.cancel();
        el.style.transition = "";
      },
      () => (el.style.transition = ""),
    );
  }
}

effect(() => {
  const drag = drawerDrag.value;
  if (drag != null) return follow(drag);
  const shown = drawer.value > 0 ? 1 : 0;
  if (followers) {
    // The drag's end and the drawer's new state come as two writes (gesture.ts end, pull.tsx): settle once both are in.
    const p = followers[0] ? Number(followers[0].anim.currentTime ?? 0) / SPAN : shown;
    queueMicrotask(() => followers && drawerDrag.value == null && settle(p, drawer.value > 0 ? 1 : 0));
    return;
  }
  const v = String(shown);
  for (const el of document.querySelectorAll<HTMLElement>("[data-p]")) el.style.setProperty("--p", v);
});
// The notification panel's openness, as the drawer's: --q on whatever follows it (data-q).
effect(() => {
  const q = String(notifShown());
  for (const el of document.querySelectorAll<HTMLElement>("[data-q]")) el.style.setProperty("--q", q);
});
/**
 * The pages' track: its position and whether it follows the finger (no transition) are set here only, never by a
 * render - a render in the middle of a swipe put it back where the page rests, and the next move took it to the
 * finger again: it jumped back and forth.
 */
effect(() => applyTrack());
export function applyTrack() {
  // Read first: an effect subscribes to what it reads, and the track may not be there yet on its first run.
  const dx = pageDrag.value;
  const at = page.value;
  // Page -1 is PowOS AI's, left of home: the whole screen slides to it - home (bar and dock with it) and the AI page
  // move as one; home's own pages stay on the first meanwhile.
  const toAi = at === -1 || (at === 0 && (dx ?? 0) > 0);
  const transform = `translateX(calc(${-Math.max(at, 0) * 100}% + ${toAi ? 0 : (dx ?? 0)}px))`;
  const shift = toAi ? (dx ?? 0) : 0;
  const track = document.querySelector<HTMLElement>(".page-track");
  for (const [sel, base] of [
    [".home", at === -1 ? 100 : 0],
    [".ai-screen", at === -1 ? 0 : -100],
  ] as const) {
    const el = document.querySelector<HTMLElement>(sel);
    if (!el) continue;
    el.classList.toggle("sliding", dx != null);
    el.style.transform = `translateX(calc(${base}% + ${shift}px))`;
  }
  if (!track) return;
  track.classList.toggle("dragging", dx != null);
  track.style.transform = transform;
  // Each page's glass layer (grid.tsx PageGlass) the other way - against the track, and against home sliding over to
  // PowOS AI's page - in the same frame and with the same transition: it stays put on screen, over the wallpaper.
  const back = Math.max(at, 0) - (at === -1 ? 1 : 0);
  const pull = (toAi ? 0 : (dx ?? 0)) + shift;
  track.querySelectorAll<HTMLElement>(":scope > .page").forEach((p, i) => {
    const img = p.querySelector<HTMLElement>(":scope > .page-glass > .page-glass-img");
    if (!img) return;
    img.classList.toggle("sliding", dx != null);
    img.style.transform = `translateX(calc(${back - i} * 100% - ${pull}px))`;
  });
}

/** Elements that follow the openness, newly mounted: given its current value. */
export function followOpenness(el: HTMLElement | null) {
  // peek: a ref callback runs inside its component's render tracking - a read here subscribed Home (and all under it:
  // the pages, their glass, every app cell, the pet) to drawerDrag, a re-render on every move of a drag.
  el?.style.setProperty("--p", String(drawerDrag.peek() ?? (drawer.peek() > 0 ? 1 : 0)));
}

/** The same for the notification panel's (--q). */
export function followNotif(el: HTMLElement | null) {
  el?.style.setProperty("--q", String(notifShown()));
}

interface Gesture {
  x0: number;
  y0: number;
  last: [number, number, number];
  /** Velocity along the gesture's axis, px/ms. */
  v: number;
  mode: "open" | "close" | "closeUp" | "over" | "pages" | "notifClose" | "panel" | "ccAll" | null;
  open: boolean;
  /** The notification panel was down when it started. */
  notif: boolean;
  inList: boolean;
  /** On the recent apps row: sideways, it scrolls rather than turning the page. */
  inStrip: boolean;
  listTop: boolean;
  /** The list under the finger is scrolled to its end (the notification list: up from there drags the panel shut). */
  listBottom: boolean;
  /** The finger's recent positions [x, t], for the release velocity (the last PAGE_V_WINDOW ms, not the average). */
  samples: [number, number][];
  /** A page settle was in flight at touch-down: how far (px) the track still was from the page's rest. */
  base: number;
  t0: number;
  /** Where it started: a tap closes the launcher unless it was on something that takes taps. */
  target: Element;
  own: boolean;
  height: number;
  /** The drawer's way, closed to open: its rise (shell.css --rise). */
  travel: number;
}

/** The gesture under way: module state, so a re-render in the middle of one (the drawer moving) keeps it. */
let g: Gesture | null = null;

/**
 * A gesture dropped half-way (a long press took over, a second finger, an end that never came): whatever it was
 * dragging settles where its state says, rather than staying half-open.
 */
function abandon() {
  g = null;
  overRelease(false);
  drawerDrag.value = null;
  notifDrag.value = null;
  pageDrag.value = null;
}

/** The drawer's way, closed to open: its rise (shell.css --rise, a length: px computed), not its height - it opens
 * from just below where it rests. Without one (a page with no --rise), its height. */
function travelOf() {
  const l = document.querySelector<HTMLElement>(".launcher");
  return (l && parseFloat(getComputedStyle(l).getPropertyValue("--rise"))) || l?.clientHeight || innerHeight;
}

/**
 * The page track's offset from its page's rest, px, while a settle is still in flight (page.value is already the
 * target): a new swipe continues from there instead of jumping to the rest position.
 */
function trackBase() {
  const track = document.querySelector<HTMLElement>(".page-track");
  const pages = document.querySelector<HTMLElement>(".pages");
  if (!track || !pages || page.value < 0 || pageDrag.peek() != null) return 0;
  const w = pages.clientWidth;
  const off = track.getBoundingClientRect().left - pages.getBoundingClientRect().left + page.value * w;
  return Math.abs(off) < 1 || Math.abs(off) >= w ? 0 : off;
}

/** Home's own layers have the touch: a tile carried or picked, a menu, an open folder. */
const busy = () => !!(carry.value || selected.value || menu.value || folder.value);

/** A touch down on home: what's under it, and what the drawer and the panels are doing. */
function startGesture(x: number, y: number, target: Element) {
  // A new touch while one is under way: the old one's end was lost.
  if (g) abandon();
  // An open folder (ui/folderview.tsx) takes its own taps and swipes (down closes it).
  // A touch inside a floating app window is the app's, always (a scroll in Chrome must never pull the launcher up or
  // the shade down): home's swipes start only outside every window (ui/desktops.ts inWindow).
  if (busy() || inWindow(x, y) || target.closest?.(".dock")) return;
  g = {
    x0: x,
    y0: y,
    last: [x, y, performance.now()],
    v: 0,
    mode: null,
    samples: [[x, performance.now()]],
    base: trackBase(),
    t0: performance.now(),
    open: drawer.value > 0,
    notif: notif.value,
    ...listUnder(target),
    // A strip that scrolls sideways itself (the recent apps, the dock's pages): sideways is its own.
    inStrip: !!target.closest?.(".strip, .dock-pages, .cc-subs"),
    target,
    own: !!target.closest?.(OWN),
    height: document.querySelector(".home")?.clientHeight || innerHeight,
    travel: travelOf(),
  };
}

/**
 * What takes its own drags: the A-Z bar, a slider, a widget's drag, the control center's edit mode (its tiles are
 * dragged), an Android widget's list (appwidget.tsx). Any widget's slider or drag control too - a range, role=slider,
 * or anything marked data-owns-gesture: its sideways drag is its own (a pill dimming a light), never a page swipe.
 * (Home's swipes are touch events on .home: a control's pointerdown stopPropagation doesn't reach them.)
 */
const OWN = ".letter-bar, input[type=range], [role=slider], [data-owns-gesture], .resize-handle, .menu, .mic, .cc-editing, .aw-face.scrolls";

/** The scrolling list under the finger - the drawer's, PowOS AI's chat, the notifications: it scrolls until its end. */
function listUnder(target: Element) {
  const list = target.closest?.(".drawer-list, .ai-panel .ai-scroll, .ai-panel, .chat, .notif-list");
  if (!list) return { inList: false, listTop: true, listBottom: true };
  return { inList: true, listTop: list.scrollTop <= 0, listBottom: list.scrollTop + list.clientHeight >= list.scrollHeight - 1 };
}

/** A finger moving: its velocity, the gesture's kind once it's clear (SLOP), then what follows it. */
function moveGesture(x: number, y: number, e: Event | null) {
  if (!g || g.own) return;
  // An app picked up (onto home, or along the dock) has the finger now.
  if (carry.value || dockDrag.value || held.value) return abandon();
  const dx = x - g.x0;
  const dy = y - g.y0;
  track(g, x, y);
  if (!g.mode && !claim(g, dx, dy)) return;
  if (e?.cancelable) e.preventDefault();
  dragTo(g, dx, dy);
}

/** Velocity along the gesture's axis (sideways for the pages and the panels), px/ms. */
function track(gs: Gesture, x: number, y: number) {
  const now = performance.now();
  const [lx, ly, lt] = gs.last;
  if (now > lt) gs.v = gs.mode === "pages" || gs.mode === "panel" ? (x - lx) / (now - lt) : (y - ly) / (now - lt);
  gs.last = [x, y, now];
  gs.samples.push([x, now]);
  while (gs.samples.length > 2 && now - gs.samples[1][1] > 150) gs.samples.shift();
}

/** Sideways release velocity, px/ms: the finger over the last PAGE_V_WINDOW ms up to now (a dwell before lifting = 0). */
function releaseVx(gs: Gesture) {
  const now = performance.now();
  const [, t1] = gs.samples[gs.samples.length - 1];
  const x1 = gs.samples[gs.samples.length - 1][0];
  if (now - t1 > PAGE_V_WINDOW) return 0;
  const old = gs.samples.find(([, t]) => now - t <= PAGE_V_WINDOW) ?? gs.samples[0];
  const dt = t1 - old[1];
  return dt > 0 ? (x1 - old[0]) / dt : 0;
}

/** The gesture's kind, once the finger is past SLOP. False: not yet, or not home's at all (dropped). */
function claim(gs: Gesture, dx: number, dy: number): boolean {
  if (Math.hypot(dx, dy) < SLOP) return false;
  const mode = gs.notif ? claimOnPanel(gs, dx, dy) : claimOnHome(gs, dx, dy);
  if (!mode) {
    g = null;
    return false;
  }
  gs.mode = mode;
  // A page swipe or an overlay change takes the keyboard down as it starts, not once it settles.
  dropKeyboard();
  return true;
}

/** The notification panel down. */
function claimOnPanel(gs: Gesture, dx: number, dy: number): Gesture["mode"] {
  const vertical = Math.abs(dy) > Math.abs(dx);
  if (vertical && ccAllWay(gs, dy)) return "ccAll";
  // Up drags it shut (the list scrolls until its end); sideways is a card's.
  if (dy < 0 && vertical && atListEnd(gs)) return "notifClose";
  return panelSwipe(gs, dx, dy) ? "panel" : null;
}

/** The list scrolled to its end, or none under the finger. */
const atListEnd = (gs: Gesture) => !gs.inList || gs.listBottom;

/**
 * The one panel open: down at its top shows the control center's whole view; with it shown, the list scrolls through
 * it all and the notifications, and up at the end folds it (ccexpand.ts) - before up shuts the panel.
 */
function ccAllWay(gs: Gesture, dy: number) {
  if (separatePanels.value === "on" || notifDrag.value != null) return false;
  return dy > 0 ? !ccExpanded.value && gs.listTop : ccExpanded.value && atListEnd(gs);
}

/**
 * Sideways, not on a notification (a card slides away by itself): between the notifications and the control center,
 * as OnePlus's panels - when they're apart (one panel: nothing to swipe to).
 */
function panelSwipe(gs: Gesture, dx: number, dy: number) {
  if (separatePanels.value !== "on" || gs.inStrip || Math.abs(dx) <= Math.abs(dy)) return false;
  return !gs.target.closest?.(".notif.tile:not(.notif-access)");
}

/** Home itself: up and down the drawer (or the shade), sideways the pages. */
function claimOnHome(gs: Gesture, dx: number, dy: number): Gesture["mode"] {
  const vertical = Math.abs(dy) > Math.abs(dx) * VERTICAL_RATIO;
  if (vertical && Math.abs(dx) >= 6) logSwipe(`lock=vertical dx=${r(dx)} dy=${r(dy)} ratio=${(Math.abs(dy) / Math.abs(dx)).toFixed(2)} page=${page.value}`);
  // PowOS AI's page and the app library: up and down are their own (they scroll).
  if (vertical && (page.value === -1 || onLibrary())) return null;
  if (vertical) return claimVertical(gs, dy);
  return !gs.open && !gs.inStrip ? "pages" : null;
}

function claimVertical(gs: Gesture, dy: number): Gesture["mode"] {
  if (gs.open) return claimOnOpen(gs, dy);
  // Editing home, up isn't the launcher (the sheet has the bottom), and down isn't the shade.
  if (editing.value) return null;
  if (dy < 0) {
    // The pull-up corners (state.ts pullPanels): from the left half PowOS AI's panel, from the right the apps.
    pullKind.value = pullPanels.value === "on" && gs.x0 < innerWidth / 2 ? "ai" : "apps";
    return "open";
  }
  askShade();
  return null;
}

/**
 * The drawer open: down from its list's top (or off the list) closes it; up at its list's end (or off the list) is
 * the over-pull to stage 2 (overpull.ts). Within the list it scrolls.
 */
function claimOnOpen(gs: Gesture, dy: number): Gesture["mode"] {
  if (dy > 0) return !gs.inList || gs.listTop ? "close" : null;
  // Up from the panel's foot (its bottom strip only - never the list's scroll): shuts it, as an app drawer closes on iOS/Android.
  // Not from a text field: the search pill sits in this strip, and a finger drifting up while tapping/placing the caret in
  // it was read as a close - dropKeyboard() then took the keyboard down as the user typed.
  if (gs.y0 > gs.height - CLOSE_UP_FOOT_PX && !gs.target.closest?.("input, textarea, [contenteditable]")) return "closeUp";
  return pullKind.value === "apps" && atListEnd(gs) ? "over" : null;
}

/** Down on home: the shade's - the host's own pull (it takes the finger); without it, the shade is asked for. */
function askShade() {
  if (!shadeTakesHome.value && document.documentElement.dataset.mode === "home") void powos.shade.open();
}

/** What follows the finger, by the gesture's kind. */
function dragTo(gs: Gesture, dx: number, dy: number) {
  switch (gs.mode) {
    case "ccAll":
      return void stretchCc(dy);
    case "panel":
      lastDx = dx;
      return void panelBody()?.style.setProperty("--panel-dx", `${panelResist(dx)}px`);
    // Up, shutting the shade / control center: the finger on its short --drop at the drawer's gain (shell.css).
    case "notifClose":
      notifDrag.value = clamp(1 + (dy * GAIN) / dropOf());
      return;
    case "open":
      drawerDrag.value = clamp((-dy * GAIN) / gs.travel);
      return overPull(-dy - gs.travel / GAIN);
    case "over":
      return overPull(-dy);
    case "close":
      drawerDrag.value = clamp(1 - (dy * GAIN) / gs.travel);
      return;
    case "closeUp":
      drawerDrag.value = clamp(1 + (dy * GAIN) / gs.travel);
      return;
    default:
      pageDrag.value = pageOffset(dx + gs.base);
  }
}

/** The pages under the finger: past the first and last page they resist. */
function pageOffset(dx: number) {
  const last = pageCount.value - 1;
  const edge = (page.value === -1 && dx > 0) || (page.value === last && dx < 0);
  return edge ? dx / 3 : dx;
}

/** The panel's foot: only a swipe up starting in this bottom strip (css px) shuts it; anywhere above it scrolls the list. */
const CLOSE_UP_FOOT_PX = 36;
/** Shut when let go with it this far (or less) still showing; a flick up this fast (px/ms) after this many px; a dwell. */
const CLOSE_UP_KEEP = 0.75;
const CLOSE_UP_SPEED = 0.35;
const CLOSE_UP_MIN = 20;
const CLOSE_DWELL_MS = 120;

/** The finger up: a tap, or the gesture settles. */
function endGesture() {
  if (!g) return;
  const gs = g;
  g = null;
  if (!gs.mode) return tapAt(gs);
  if (gs.mode === "over") return void overRelease();
  settleGesture(gs, gs.last[1] - gs.y0);
}

/** A clean tap (no gesture claimed). */
function tapAt(gs: Gesture) {
  if (gs.notif && tapOnPanel(gs)) return;
  // On the open launcher's empty space (not an app, a message, a control): it closes, as tapping outside does.
  if (gs.open && !gs.own && gs.target.closest?.(".launcher") && !gs.target.closest(TAPPABLE)) closeDrawer();
}

/** A tap on the notification panel / control center: true when it was theirs. */
function tapOnPanel({ target, own }: Gesture) {
  // The control center in edit mode: a tap beside its tiles leaves it (as a tap on home's empty space), the panel stays.
  if (ccEditing.value && !target.closest?.(`${TAPPABLE}, [data-key], .tile-actions`)) {
    ccEditing.value = false;
    return true;
  }
  // On the notification panel's or the control center's empty space: it closes, with its own animation - as a tap
  // beside the open launcher closes it.
  if (notif.value && !own && !target.closest?.(`${TAPPABLE}, .notif, .cc-tile`)) {
    notif.value = false;
    return true;
  }
  return false;
}

function settleGesture(gs: Gesture, dy: number) {
  const { mode, v } = gs;
  if (isDrawerMode(mode)) return settleDrawerGesture(gs, v);
  if (mode === "notifClose") return settleNotif(v);
  // Past the threshold, or a flick its way: committed; otherwise it springs back.
  if (mode === "ccAll") return settleCc(!ccExpanded.value ? dy > EXPAND_AT || v > FLICK : dy < -EXPAND_AT || v < -FLICK);
  if (mode === "panel") return settlePanel(lastDx, v);
  if (mode === "pages") settlePages(gs);
}

/**
 * Up from the foot shut it. Let go: as the switcher's early release (NavGestureClassifier) - far enough, or a fast
 * flick up after a short way (and not a flick back down), or held at the end of the pull (dwell) - it shuts; else it
 * springs back open.
 */
function settleCloseUp(gs: Gesture, v: number) {
  const p = drawerDrag.value ?? 1;
  drawerDrag.value = null;
  const lift = -(gs.last[1] - gs.y0);
  const dwell = performance.now() - gs.last[2] > CLOSE_DWELL_MS;
  const shut = v <= FLICK && (p < CLOSE_UP_KEEP || (-v >= CLOSE_UP_SPEED && lift >= CLOSE_UP_MIN) || (dwell && lift >= CLOSE_UP_MIN));
  if (shut) closeDrawer();
  else drawer.value = 1;
}

const isDrawerMode = (m: Gesture["mode"]) => m === "open" || m === "close" || m === "closeUp";

function settleDrawerGesture(gs: Gesture, v: number) {
  if (gs.mode === "closeUp") return settleCloseUp(gs, v);
  settleDrawer(gs.mode as "open" | "close", v);
}

function settleDrawer(mode: "open" | "close", v: number) {
  const p = drawerDrag.value ?? 0;
  drawerDrag.value = null;
  // Let go past the over-pull: open, with the search focused and the keyboard up (overpull.ts).
  if (overRelease() || drawerWanted(mode, v, p)) drawer.value = 1;
  else closeDrawer();
}

/** A flick decides; otherwise where it was let go. */
function drawerWanted(mode: "open" | "close", v: number, p: number) {
  if (v < -(mode === "open" ? OPEN_FLICK : FLICK)) return true;
  if (v > FLICK) return false;
  return mode === "open" ? p > OPEN_AT : p > CLOSE_KEEP;
}

function settleNotif(v: number) {
  const q = notifDrag.value ?? 0;
  notifDrag.value = null;
  // A flick decides; otherwise where it was let go (as the drawer).
  notif.value = v > FLICK ? true : v < -FLICK ? false : q > CLOSE_KEEP;
}

const r = Math.round;
/** One compact line per page-swipe decision, to logcat (console.info, tag PowosShell). */
const logSwipe = (msg: string) => console.info(`pageswipe ${msg}`);

/**
 * Let go: commit when dragged past PAGE_AT of the width, or flicked (PAGE_FLICK px/ms over the last PAGE_V_WINDOW ms,
 * after PAGE_FLICK_MIN px); a flick back cancels; a short, slow release springs back. The target is always the page
 * on screen +-1 (page.value is the in-flight target when a settle was running; the drag continued from its position).
 */
function settlePages(gs: Gesture) {
  const total = pageDrag.value ?? 0;
  pageDrag.value = null;
  const width = document.querySelector(".pages")?.clientWidth || innerWidth;
  const dx = gs.last[0] - gs.x0;
  const vx = releaseVx(gs);
  const { dir, why } = pageDecision(total, dx, vx, width);
  const from = page.value;
  const to = Math.max(editing.value ? 0 : -1, Math.min(pageCount.value - 1, from + dir));
  page.value = to;
  const outcome = to !== from ? "commit" : dir !== 0 ? "edge-cancel" : "cancel";
  logSwipe(
    `dx=${r(dx)} dy=${r(gs.last[1] - gs.y0)} total=${r(total)} base=${r(gs.base)} dur=${r(performance.now() - gs.t0)}ms v=${vx.toFixed(2)}px/ms thr=${r(width * PAGE_AT)}px/${PAGE_FLICK} page=${from}->${to} ${outcome} why=${why}`,
  );
}

/** The page step (-1, 0, 1) and the reason, from the offset on screen, the drag's dx and the release velocity. */
function pageDecision(total: number, dx: number, vx: number, width: number) {
  const flick = Math.abs(vx) >= PAGE_FLICK && Math.abs(dx) >= PAGE_FLICK_MIN;
  if (flick && Math.sign(vx) !== Math.sign(dx)) return { dir: 0, why: "flick-back" };
  if (flick) return { dir: -Math.sign(vx), why: "velocity" };
  if (Math.abs(total) >= width * PAGE_AT) return { dir: -Math.sign(total), why: "distance" };
  return { dir: 0, why: "short-slow" };
}

/** Include a release's last position before deciding where the gesture settles. */
function releaseGesture(x: number, y: number) {
  // WebView can coalesce moves under load; the release still has the final position.
  // Do not replace a flick's velocity with zero when the last move already reached it.
  if (g && (x !== g.last[0] || y !== g.last[1])) moveGesture(x, y, null);
  endGesture();
}

/** Handlers for home's root element. */
export function homeGestures() {
  return {
    onTouchStart: (e: TouchEvent) =>
      e.touches.length === 1 ? startGesture(e.touches[0].clientX, e.touches[0].clientY, e.target as Element) : abandon(),
    onTouchMove: (e: TouchEvent) => moveGesture(e.touches[0].clientX, e.touches[0].clientY, e),
    onTouchEnd: (e: TouchEvent) => {
      const p = e.changedTouches[0];
      if (p) releaseGesture(p.clientX, p.clientY);
      else endGesture();
    },
    onTouchCancel: endGesture,
    // A mouse (working on the shell in a desktop browser).
    onPointerDown: (e: PointerEvent) => e.pointerType === "mouse" && startGesture(e.clientX, e.clientY, e.target as Element),
    onPointerMove: (e: PointerEvent) => e.pointerType === "mouse" && e.buttons && moveGesture(e.clientX, e.clientY, null),
    onPointerUp: (e: PointerEvent) => e.pointerType === "mouse" && releaseGesture(e.clientX, e.clientY),
  };
}

const clamp = (v: number) => Math.max(0, Math.min(1, v));

/** The panel's content, which a sideways swipe moves (notifications.tsx's .panel-body). */
const panelBody = () => document.querySelector<HTMLElement>(".notif-panel .panel-body");
let lastDx = 0;

/** Towards the side there's nothing on (left of the notifications, right of the control center), it resists. */
function panelResist(dx: number) {
  const towardControl = dx < 0;
  const hasNext = panel.value === "notifications" ? towardControl : !towardControl;
  return hasNext ? dx : dx / 4;
}

/**
 * Let go: a flick or a quarter of the width switches the panel - the other one comes in from the side it was swiped
 * towards - otherwise the content springs back.
 */
function settlePanel(dx: number, v: number) {
  const body = panelBody();
  const width = body?.clientWidth || innerWidth;
  const to = dx < -width / 4 || v < -FLICK ? "control" : dx > width / 4 || v > FLICK ? "notifications" : panel.value;
  const switched = to !== panel.value;
  lastDx = 0;
  if (!body) return;
  if (!switched) {
    body.classList.add("settling");
    body.style.setProperty("--panel-dx", "0px");
    window.setTimeout(() => body.classList.remove("settling"), PANEL_MS);
    return;
  }
  panel.value = to;
  // The new content starts where the swipe left off, on the far side, and slides in.
  requestAnimationFrame(() => {
    const b = panelBody();
    if (!b) return;
    b.classList.remove("settling");
    b.style.setProperty("--panel-dx", `${to === "control" ? width * 0.35 : -width * 0.35}px`);
    void b.offsetWidth;
    b.classList.add("settling");
    b.style.setProperty("--panel-dx", "0px");
    window.setTimeout(() => b.classList.remove("settling"), PANEL_MS);
  });
}

const PANEL_MS = 220;
