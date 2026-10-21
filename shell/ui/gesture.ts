/**
 * Home's swipes, following the finger like a stock launcher's:
 *
 * - Up anywhere on home: the drawer slides up under the finger; released past 15% of the way, or flicked up (even a
 *   short flick), it opens, else it falls back.
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
import { carry, closeDrawer, dockDrag, drawer, editing, menu, notif, page, pages, panel, pullKind, pullPanels, selected } from "../state.ts";

const SLOP = 10;
/** px per ms: a flick, whatever the distance. */
const FLICK = 0.45;
/** Up, opening the drawer: a short flick is enough (px per ms), or past this much of the way. */
const OPEN_FLICK = 0.2;
const OPEN_AT = 0.15;
/** The drawer moves this much faster than the finger (clamped at the top): its edge covers the screen in 2/3 of the swipe. */
const GAIN = 1.5;
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
  const key = `${innerWidth}x${innerHeight} ${el.offsetWidth}x${el.offsetHeight} ${el.closest(".home")?.classList.contains("pill-below")}`;
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
  el?.style.setProperty("--p", String(drawerShown()));
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
  mode: "open" | "close" | "pages" | "notifClose" | "panel" | null;
  open: boolean;
  /** The notification panel was down when it started. */
  notif: boolean;
  inList: boolean;
  /** On the recent apps row: sideways, it scrolls rather than turning the page. */
  inStrip: boolean;
  listTop: boolean;
  /** The list under the finger is scrolled to its end (the notification list: up from there drags the panel shut). */
  listBottom: boolean;
  /** Where it started: a tap closes the launcher unless it was on something that takes taps. */
  target: Element;
  own: boolean;
  height: number;
  /** The drawer's edge's way, closed to open: the launcher's height. */
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
  drawerDrag.value = null;
  notifDrag.value = null;
  pageDrag.value = null;
}

/** Handlers for home's root element. */
export function homeGestures() {
  const start = (x: number, y: number, target: Element) => {
    // A new touch while one is under way: the old one's end was lost.
    if (g) abandon();
    if (carry.value || selected.value || menu.value) return;
    // The scrolling list under the finger - the drawer's, PowOS AI's chat, the notifications: it scrolls until its end.
    const list = target.closest?.(".drawer-list, .ai-panel, .chat, .notif-list") ?? null;
    g = {
      x0: x,
      y0: y,
      last: [x, y, performance.now()],
      v: 0,
      mode: null,
      open: drawer.value > 0,
      notif: notif.value,
      inList: !!list,
      // A strip that scrolls sideways itself (the recent apps, the dock's pages): sideways is its own.
      inStrip: !!target.closest?.(".strip, .dock-pages, .cc-subs"),
      listTop: !list || list.scrollTop <= 0,
      listBottom: !list || list.scrollTop + list.clientHeight >= list.scrollHeight - 1,
      target,
      // The A-Z bar, a slider, a widget's drag, the control center's edit mode (its tiles are dragged), an Android
      // widget's list (appwidget.tsx): theirs. Any widget's slider or drag control too - a range, role=slider, or
      // anything marked data-owns-gesture: its sideways drag is its own (a pill dimming a light), never a page swipe.
      // (Home's swipes are touch events on .home: a control's pointerdown stopPropagation doesn't reach them.)
      own: !!target.closest?.(
        ".letter-bar, input[type=range], [role=slider], [data-owns-gesture], .resize-handle, .menu, .mic, .cc-editing, .aw-face.scrolls",
      ),
      height: document.querySelector(".home")?.clientHeight || innerHeight,
      travel: document.querySelector(".launcher")?.clientHeight || innerHeight,
    };
  };

  const move = (x: number, y: number, e: Event | null) => {
    if (!g || g.own) return;
    // An app picked up (onto home, or along the dock) has the finger now.
    if (carry.value || dockDrag.value) return abandon();
    const dx = x - g.x0;
    const dy = y - g.y0;
    const now = performance.now();
    const [lx, ly, lt] = g.last;
    if (now > lt) g.v = g.mode === "pages" || g.mode === "panel" ? (x - lx) / (now - lt) : (y - ly) / (now - lt);
    g.last = [x, y, now];
    if (!g.mode) {
      if (Math.hypot(dx, dy) < SLOP) return;
      if (g.notif) {
        // The notification panel down: up drags it shut (the list scrolls until its end); sideways is a card's.
        if (dy < 0 && Math.abs(dy) > Math.abs(dx) && (!g.inList || g.listBottom)) g.mode = "notifClose";
        // Sideways, not on a notification (a card slides away by itself): between the notifications and the
        // control center, as OnePlus's panels.
        else if (Math.abs(dx) > Math.abs(dy) && !g.inStrip && !g.target.closest?.(".notif.tile:not(.notif-access)")) g.mode = "panel";
        else return (g = null);
      } else if (Math.abs(dy) > Math.abs(dx) && page.value === -1) {
        // PowOS AI's page: up and down are its own (it scrolls).
        return (g = null);
      } else if (Math.abs(dy) > Math.abs(dx)) {
        // Editing home, up isn't the launcher: the sheet has the bottom.
        if (!g.open && dy < 0 && !editing.value) {
          g.mode = "open";
          // The pull-up corners (state.ts pullPanels): from the left half PowOS AI's panel, from the right the apps.
          pullKind.value = pullPanels.value === "on" && g.x0 < innerWidth / 2 ? "ai" : "apps";
        }
        else if (g.open && dy > 0 && (!g.inList || g.listTop)) g.mode = "close";
        // Down on home: the shade's - the host's own pull (it takes the finger); without it, the shade is asked for.
        else if (!g.open && dy > 0 && !editing.value) {
          if (!shadeTakesHome.value && document.documentElement.dataset.mode === "home") void powos.shade.open();
          return (g = null);
        } else return (g = null); // the list scrolls
      } else if (!g.open && !g.inStrip) {
        g.mode = "pages";
      } else {
        return (g = null);
      }
      // A page swipe or an overlay change takes the keyboard down as it starts, not once it settles.
      dropKeyboard();
    }
    if (e?.cancelable) e.preventDefault();
    if (g.mode === "panel") {
      lastDx = dx;
      return panelBody()?.style.setProperty("--panel-dx", `${panelResist(dx)}px`);
    }
    if (g.mode === "notifClose") notifDrag.value = clamp(1 + dy / (g.height * 0.6));
    else if (g.mode === "open") drawerDrag.value = clamp((-dy * GAIN) / g.travel);
    else if (g.mode === "close") drawerDrag.value = clamp(1 - (dy * GAIN) / g.travel);
    else {
      // Past the first and last page it resists.
      const last = pages.value.length - 1;
      const edge = (page.value === -1 && dx > 0) || (page.value === last && dx < 0);
      pageDrag.value = edge ? dx / 3 : dx;
    }
  };

  const end = () => {
    if (!g) return;
    const { mode, v, open, target, own, notif: wasNotif } = g;
    g = null;
    // A clean tap (no gesture claimed) on the notification panel's or the control center's empty space: it closes,
    // with its own animation - as a tap beside the open launcher closes it.
    if (!mode && wasNotif && notif.value && !own && !target.closest?.(`${TAPPABLE}, .notif, .cc-tile`)) {
      notif.value = false;
      return;
    }
    // A tap on the open launcher's empty space (not an app, a message, a control): it closes, as tapping outside does.
    if (!mode && open && !own && target.closest?.(".launcher") && !target.closest(TAPPABLE)) return closeDrawer();
    if (mode === "open" || mode === "close") {
      const p = drawerDrag.value ?? 0;
      drawerDrag.value = null;
      // A flick decides; otherwise where it was let go.
      const open = v < -(mode === "open" ? OPEN_FLICK : FLICK) ? true : v > FLICK ? false : mode === "open" ? p > OPEN_AT : p > 0.67;
      if (open) drawer.value = 1;
      else closeDrawer();
    } else if (mode === "notifClose") {
      const q = notifDrag.value ?? 0;
      notifDrag.value = null;
      // A flick decides; otherwise where it was let go (as the drawer).
      notif.value = v > FLICK ? true : v < -FLICK ? false : q > 0.67;
    } else if (mode === "panel") {
      settlePanel(lastDx, v);
    } else if (mode === "pages") {
      const dx = pageDrag.value ?? 0;
      pageDrag.value = null;
      const width = document.querySelector(".pages")?.clientWidth || innerWidth;
      const step = v < -FLICK || dx < -width / 4 ? 1 : v > FLICK || dx > width / 4 ? -1 : 0;
      // -1: PowOS AI's page, left of the first (not while editing home: the empty page is to the right).
      page.value = Math.max(editing.value ? 0 : -1, Math.min(pages.value.length - 1, page.value + step));
    }
  };

  return {
    onTouchStart: (e: TouchEvent) =>
      e.touches.length === 1 ? start(e.touches[0].clientX, e.touches[0].clientY, e.target as Element) : abandon(),
    onTouchMove: (e: TouchEvent) => move(e.touches[0].clientX, e.touches[0].clientY, e),
    onTouchEnd: end,
    onTouchCancel: end,
    // A mouse (working on the shell in a desktop browser).
    onPointerDown: (e: PointerEvent) => e.pointerType === "mouse" && start(e.clientX, e.clientY, e.target as Element),
    onPointerMove: (e: PointerEvent) => e.pointerType === "mouse" && e.buttons && move(e.clientX, e.clientY, null),
    onPointerUp: (e: PointerEvent) => e.pointerType === "mouse" && end(),
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
