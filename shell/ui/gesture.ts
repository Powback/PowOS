/**
 * Home's swipes, following the finger like a stock launcher's:
 *
 * - Up anywhere on home: the drawer slides up under the finger; released past a third of the way, or flicked up, it
 *   opens, else it falls back.
 * - Down on the open drawer - from the top of its list, or anywhere outside the list - drags it closed the same way.
 *   A list that's scrolled down just scrolls.
 * - Sideways on home: the pages slide under the finger and snap to the next one past a quarter of the width or a flick.
 *
 * A gesture is only claimed once its direction is clear (SLOP), so taps, long presses (moving and resizing tiles),
 * the drawer's scrolling and the A-Z bar keep their touches. Touch events, not pointer events: those end in a
 * pointercancel once the browser scrolls something.
 */
import { computed, effect, signal } from "@preact/signals";
import { carry, closeDrawer, drawer, menu, page, pages, selected } from "../state.ts";

const SLOP = 10;
/** px per ms: a flick, whatever the distance. */
const FLICK = 0.45;

/** While a finger drags the drawer: its openness, 0..1; null otherwise (then the drawer signal decides). */
export const drawerDrag = signal<number | null>(null);
/** While a finger drags the pages: their offset in px; null otherwise. */
export const pageDrag = signal<number | null>(null);

/** The drawer's openness on screen: dragged, or settled. */
export const drawerShown = () => drawerDrag.value ?? (drawer.value > 0 ? 1 : 0);

/**
 * What rendering reads - whether the drawer shows at all, whether a finger holds it or the pages - changes a few
 * times a gesture. The openness itself changes every frame of it, and goes straight to the elements that follow it
 * (data-p: their --p; .page-track: its transform), never through a render: a render per frame of a swipe rebuilt the
 * drawer's every app and home's every tile.
 */
export const drawerOpen = computed(() => drawerShown() > 0);
export const drawerDragging = computed(() => drawerDrag.value != null);
export const pagesDragging = computed(() => pageDrag.value != null);

effect(() => {
  const p = String(drawerShown());
  for (const el of document.querySelectorAll<HTMLElement>("[data-p]")) el.style.setProperty("--p", p);
});
effect(() => {
  // Read first: an effect subscribes to what it reads, and the track may not be there yet on its first run.
  const transform = `translateX(calc(${-page.value * 100}% + ${pageDrag.value ?? 0}px))`;
  const track = document.querySelector<HTMLElement>(".page-track");
  if (track) track.style.transform = transform;
});

/** Elements that follow the openness, newly mounted: given its current value. */
export function followOpenness(el: HTMLElement | null) {
  el?.style.setProperty("--p", String(drawerShown()));
}

interface Gesture {
  x0: number;
  y0: number;
  last: [number, number, number];
  /** Velocity along the gesture's axis, px/ms. */
  v: number;
  mode: "open" | "close" | "pages" | null;
  open: boolean;
  inList: boolean;
  listTop: boolean;
  own: boolean;
  height: number;
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
  pageDrag.value = null;
}

/** Handlers for home's root element. */
export function homeGestures() {

  const start = (x: number, y: number, target: Element) => {
    // A new touch while one is under way: the old one's end was lost.
    if (g) abandon();
    if (carry.value || selected.value || menu.value) return;
    const list = document.querySelector(".drawer-list");
    g = {
      x0: x,
      y0: y,
      last: [x, y, performance.now()],
      v: 0,
      mode: null,
      open: drawer.value > 0,
      inList: !!(list && list.contains(target)),
      listTop: !list || list.scrollTop <= 0,
      // The A-Z bar, a slider, a widget's drag: theirs.
      own: !!target.closest?.(".letter-bar, input[type=range], .resize-handle, .menu"),
      height: document.querySelector(".home")?.clientHeight || innerHeight,
    };
  };

  const move = (x: number, y: number, e: Event | null) => {
    if (!g || g.own) return;
    if (carry.value) return abandon();
    const dx = x - g.x0;
    const dy = y - g.y0;
    const now = performance.now();
    const [lx, ly, lt] = g.last;
    if (now > lt) g.v = g.mode === "pages" ? (x - lx) / (now - lt) : (y - ly) / (now - lt);
    g.last = [x, y, now];
    if (!g.mode) {
      if (Math.hypot(dx, dy) < SLOP) return;
      if (Math.abs(dy) > Math.abs(dx)) {
        if (!g.open && dy < 0) g.mode = "open";
        else if (g.open && dy > 0 && (!g.inList || g.listTop)) g.mode = "close";
        else return (g = null); // the list scrolls
      } else if (!g.open) {
        g.mode = "pages";
      } else {
        return (g = null);
      }
    }
    if (e?.cancelable) e.preventDefault();
    if (g.mode === "open") drawerDrag.value = clamp(-dy / (g.height * 0.6));
    else if (g.mode === "close") drawerDrag.value = clamp(1 - dy / (g.height * 0.6));
    else {
      // Past the first and last page it resists.
      const last = pages.value.length - 1;
      const edge = (page.value === 0 && dx > 0) || (page.value === last && dx < 0);
      pageDrag.value = edge ? dx / 3 : dx;
    }
  };

  const end = () => {
    if (!g) return;
    const { mode, v } = g;
    g = null;
    if (mode === "open" || mode === "close") {
      const p = drawerDrag.value ?? 0;
      drawerDrag.value = null;
      // A flick decides; otherwise where it was let go.
      const open = v < -FLICK ? true : v > FLICK ? false : mode === "open" ? p > 0.33 : p > 0.67;
      if (open) drawer.value = 1;
      else closeDrawer();
    } else if (mode === "pages") {
      const dx = pageDrag.value ?? 0;
      pageDrag.value = null;
      const width = document.querySelector(".pages")?.clientWidth || innerWidth;
      const step = v < -FLICK || dx < -width / 4 ? 1 : v > FLICK || dx > width / 4 ? -1 : 0;
      page.value = Math.max(0, Math.min(pages.value.length - 1, page.value + step));
    }
  };

  return {
    onTouchStart: (e: TouchEvent) => (e.touches.length === 1 ? start(e.touches[0].clientX, e.touches[0].clientY, e.target as Element) : abandon()),
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
