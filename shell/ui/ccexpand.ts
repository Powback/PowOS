/**
 * The control center's whole view, in the one panel (notifications.tsx, together): the panel open, a further pull down
 * shows the rest; up, or scrolling the notifications, folds it back. gesture.ts follows the finger ([stretch]) and lets
 * go with [settle]: past EXPAND_AT or a flick it's committed, else it goes back.
 *
 * v3 (control.tsx Controls): the whole panel follows the finger. The pull's first move lays the rest out once (the
 * grid's "cc-peek" class: every toggle shown, as "whole"), and what's under the list (the notifications' header and list)
 * is put back up by the rest's height H with a translate - nothing moved on screen. Then per frame only that translate
 * and the list's --cc-k (0..1, registered inherits:false; the rest's toggles read it by name) change: the notifications
 * slide down under the finger and the rest's rows fade in a row at a time as they're uncovered; past H a rubber band.
 * The panel's own edge, its handle and its frost follow too: laid out whole the panel is taller by its growth G, so it's
 * lifted by G - shown (--cc-lift on the panel, registered inherits:false; shell.css moves the panel up and its body
 * back down by it - its bottom edge, the grip with it, sits under the notifications, no empty slab).
 * Let go, the same values ease to the end state, which is then laid out once (no jump: the translate was exactly
 * the layout's difference). Nothing runs at rest.
 *
 * Classic (Categories): the rows below spread apart (a rubber band, translates only) and a commit lays the new state
 * out once, each row played from where the finger left it (a FLIP).
 */
import { signal } from "@preact/signals";

/** Every category's members shown (only in the one panel, only while it's open). */
/** Desktop mode (wide) opens expanded; the phone opens folded, its quick launchers still shown (the user, 2026-10-28). */
export const expandedByDefault = () => typeof innerWidth === "number" && innerWidth >= 700;
export const ccExpanded = signal(expandedByDefault());
/**
 * v3 pull under way: "open" (stacks are shown unfolded for the pull, their rest driven by the finger) or "fold" (the
 * open ones are driven back down). null at rest. notifications.tsx's Stack reads it and hands its elements to
 * [attachPeek], so the groups unfold with the finger exactly as the control center's rest does.
 */
export const ccPeeking = signal<null | "open" | "fold">(null);
/** The paused animations tied to the finger (a stack's rest, head, top card, what follows it), by the pull's progress k. */
const peekAnims = new Set<Animation>();
/** The stacks already tied in this pull (a re-render hands them again). */
const peeked = new Set<HTMLElement>();
let peekK = 0;
/** One paused, finger-driven animation on [el] (or its [pseudo]); [add]: summed with the others on it (the offsets). */
function peekAnim(el: Element | null | undefined, frames: Keyframe[], o: { pseudo?: string; add?: boolean } = {}) {
  if (!el) return;
  let a: Animation;
  try {
    a = el.animate(frames, { duration: MS, fill: "both", easing: "linear", id: "ccpeek", pseudoElement: o.pseudo, composite: o.add ? "add" : "replace" });
  } catch {
    return; // (A host without pseudo-element animations: those peeking cards switch at the settle.)
  }
  a.pause();
  a.currentTime = peekK * MS;
  peekAnims.add(a);
}
/**
 * [stack] tied to the pull's progress k (0 folded .. 1 unfolded): one paused Web Animation per part, no style per frame.
 * Both ways the top card morphs with k: its "+N" badge shrinks away, the peeking cards under it (the stack's pseudos,
 * notifications.css "peek") retract into the rest - no card fades, none narrows. Opening, the rest unfolds in place
 * (its layout grows: it can't clamp a scroll). Folding, nothing is laid out until the settle - a shrinking list would clamp the scroll under the finger: the
 * head, top card and rest slide up (the rest clipped under the card) by transforms only, and everything after the stack
 * comes up with it by the same running offset (composited "add", so each stack before one adds its own); at the settle
 * the folded layout is committed in the same frame the animations are cancelled - the k=0 frame is that layout.
 */
export function attachPeek(stack: HTMLElement) {
  if (!pull?.grid || peeked.has(stack)) return;
  peeked.add(stack);
  const card = stack.querySelector<HTMLElement>(":scope > .notif");
  peekAnim(card?.querySelector(".notif-more"), [{ opacity: 1, transform: "scale(1)" }, { opacity: 0, transform: "scale(0.6)" }]);
  (pull.was ? foldPeek : openPeek)(stack, card);
}

/**
 * The peeking slices (notifications.css: 12 px tall, their top under the stack's last card) retract into it: clipped from
 * the top down to nothing, never faded (the cards' material is translucent - a slice moved under one would show through).
 */
const TUCKED = "inset(100% 0px 0px 0px)";

/** The stack's parts, and the room its folded peeking cards leave under it (notifications.css; open has none). */
function parts(stack: HTMLElement) {
  return {
    rest: stack.querySelector<HTMLElement>(":scope > .notif-rest"),
    head: stack.querySelector<HTMLElement>(":scope > .notif-group-head"),
    gap: Number(stack.dataset.depth) === 2 ? 10 : 5,
  };
}

/** Opening: the rest unfolds in place, the head fades in, the peeking cards fade into the rest. */
function openPeek(stack: HTMLElement, card: HTMLElement | null) {
  const { rest, head, gap } = parts(stack);
  peekAnim(stack, [{ marginBottom: `${gap}px` }, { marginBottom: "0px" }]);
  // The rest is revealed by its own growing row (clipped by its box), never faded: each card opaque at every k. The
  // peeking slices ride the stack's bottom and retract into its last card instead of fading out.
  peekAnim(rest, [{ gridTemplateRows: "0fr" }, { gridTemplateRows: "1fr" }]);
  peekAnim(head, [{ opacity: 0 }, { opacity: 1 }]);
  for (const pseudo of ["::before", "::after"]) peekAnim(stack, [{ clipPath: "inset(0px)" }, { clipPath: TUCKED }], { pseudo });
  headMorph(card, head);
}

/**
 * The top card's group-header look, folded .. group (k 0..1), both ways, no layout: while "peek" the card lays out its
 * header row (icon, name, time) and the group head is out of flow over the same band (notifications.css), both as tall
 * as the head row the group look puts above the card - so the settle moves nothing. The icon and name fade, the card's
 * top edge slides down past the band (clip-path), the time slides from its row to the corner (measured once, now).
 */
function headMorph(card: HTMLElement | null, head: HTMLElement | null) {
  if (!card) return;
  const band = head?.offsetHeight ?? 0;
  const time = card.querySelector<HTMLElement>(".notif-time");
  peekAnim(card.querySelector(".notif-icon"), [{ opacity: 1 }, { opacity: 0 }]);
  // The group's name is drawn twice while it morphs - the card's (fading out) and the head's (fading in) - and the two
  // sit apart (the card's row is under its padding, after its icon; the head's at the band's edge): crossfaded in
  // place they read as one header doubled a few px off (the user, 2026-10-28 "notifications still borked during
  // transition"). Both ride the same path instead, card's to head's, so at every k they cover each other exactly.
  const app = card.querySelector<HTMLElement>(".notif-app");
  const headApp = head?.querySelector<HTMLElement>(".notif-app");
  if (app && headApp) {
    const a = app.getBoundingClientRect(), h = headApp.getBoundingClientRect();
    const dx = h.left - a.left, dy = h.top + h.height / 2 - (a.top + a.height / 2);
    peekAnim(app, [{ opacity: 1, transform: "none" }, { opacity: 0, transform: `translate(${dx}px, ${dy}px)` }]);
    peekAnim(headApp, [{ transform: `translate(${-dx}px, ${-dy}px)` }, { transform: "none" }]);
  } else peekAnim(app, [{ opacity: 1 }, { opacity: 0 }]);
  // The clip keeps the card's own top corners (its sides at the card's: a rounded inset past the box rounds nothing):
  // a square-cut top mid-pull read as a different, sliced box than either rest.
  const rad = getComputedStyle(card).borderTopLeftRadius || "0px";
  peekAnim(card, [{ clipPath: `inset(0px 0px -60px 0px round ${rad} ${rad} 0px 0px)` }, { clipPath: `inset(${band}px 0px -60px 0px round ${rad} ${rad} 0px 0px)` }]);
  if (time) {
    const dy = band + 9 - (time.getBoundingClientRect().top - card.getBoundingClientRect().top);
    peekAnim(time, [{ transform: "none" }, { transform: `translateY(${dy}px)` }]);
  }
}

/** Folding: transforms only (heights measured once, now - laid out open), what follows up by the running offset. */
function foldPeek(stack: HTMLElement, card: HTMLElement | null) {
  const { rest, head, gap } = parts(stack);
  const hr = rest?.offsetHeight ?? 0;
  const up = (px: number) => `translateY(${-px}px)`;
  peekAnim(head, [{ opacity: 0 }, { opacity: 1 }]);
  headMorph(card, head);
  // The rest slides up under the top card - translate only, clipped at the card's bottom edge (the clip's sides past the
  // box, so the cards keep their full width and shadow) - fully opaque at every k: no fade, no inset box. (It used to
  // fade 0..1 with the pull: a translucent ghost of the rest over the list; the user, 2026-10-28 18:10 "not".)
  peekAnim(rest, [
    { transform: up(hr), clipPath: `inset(${hr}px -60px -60px -60px)` },
    { transform: "none", clipPath: "inset(0px -60px -60px -60px)" },
  ]);
  // The peeking slices ride the rest's bottom (up with it), drawn out of its last card as it folds - clipped, not faded.
  for (const pseudo of ["::before", "::after"]) {
    peekAnim(stack, [{ transform: up(hr), clipPath: "inset(0px)" }, { transform: "none", clipPath: TUCKED }], { pseudo });
  }
  for (let el = stack.nextElementSibling; el; el = el.nextElementSibling) {
    peekAnim(el, [{ translate: `0px ${gap - hr}px` }, { translate: "0px 0px" }], { add: true });
  }
}

/** The peek's progress k on every tied animation. */
function peekTo(k: number) {
  peekK = k;
  for (const a of peekAnims) a.currentTime = k * MS;
}

/** A cubic bezier ([pts], EASE's by default) as a function of time (0..1): solved for x (bisection). */
function eased(t: number, pts: Curve = EASE_PTS) {
  const [x1, y1, x2, y2] = pts;
  const bz = (s: number, a: number, b: number) => 3 * a * s * (1 - s) ** 2 + 3 * b * s * s * (1 - s) + s ** 3;
  let lo = 0, hi = 1, s = t;
  for (let i = 0; i < 20; i++) {
    const x = bz(s, x1, x2) - t;
    if (Math.abs(x) < 1e-5) break;
    if (x > 0) hi = s;
    else lo = s;
    s = (lo + hi) / 2;
  }
  return bz(s, y1, y2);
}
let rideFrame = 0;
/** The tied animations from k [from] to [to] on the translate's own curve and duration (one currentTime a frame). */
function ride(from: number, to: number, ms = MS, pts: Curve = EASE_PTS) {
  cancelAnimationFrame(rideFrame);
  const t0 = performance.now();
  const step = (now: number) => {
    const t = Math.min(1, Math.max(0, (now - t0) / ms));
    peekTo(from + (to - from) * eased(t, pts));
    if (t < 1) rideFrame = requestAnimationFrame(step);
  };
  rideFrame = requestAnimationFrame(step);
}

/** The control center's edit mode (ui/reorder.ts, as home's): entered by a long press on a tile, left by its "done". */
export const ccEditing = signal(false);

/** The finger's travel (CSS px) to the classic rows' spread: easy at first, firmer the further it goes. */
const band = (d: number) => Math.sign(d) * 120 * (1 - Math.exp(-Math.abs(d) / 200));
/** Past the end (v3, only a drag on the card itself - gesture.ts ccAllWay): a subtle rubber band, at most OVER px. */
const OVER = 20;
const over = (d: number) => OVER * (1 - Math.exp(-Math.max(0, d) / 100));
/** Pulled this far (CSS px, the finger's travel) it commits on its own; a flick (gesture.ts FLICK) does too. */
export const EXPAND_AT = 56;
/** Folding is easier than showing (the user: "can't properly collapse"): a short swipe up on the card folds it, no half state. */
export const FOLD_AT = 24;
const MS = 260;
const EASE = "cubic-bezier(0.2, 0.9, 0.3, 1)";
/** Folding: a clean, quick fold (height and opacity, ease-out) - no stretch or spring frames. */
const FOLD_MS = 200;
const FOLD_EASE = "cubic-bezier(0.25, 1, 0.5, 1)";
type Curve = [number, number, number, number];
const EASE_PTS: Curve = [0.2, 0.9, 0.3, 1];
const FOLD_PTS: Curve = [0.25, 1, 0.5, 1];

/** What the finger moves; [gain] of its spread (classic rows spread apart, the rest moves whole). */
type Mover = { el: HTMLElement; gain: number };
type Pull = {
  /** v3's list and its grid (laid out whole while the pull lasts: the grid's "cc-peek"), or null: classic. */
  list: HTMLElement | null;
  grid: HTMLElement | null;
  /** v3: the control center's card, and the notifications' own panel under it (what follows the card). */
  card: HTMLElement | null;
  own: HTMLElement | null;
  movers: Mover[];
  /** v3: how much taller the card is laid out whole than folded (px): the rest of the toggles and the launchers. */
  h: number;
  /** Shown whole when the pull began. */
  was: boolean;
  /** Let go: the state it's easing to. */
  to?: boolean;
};
let pull: Pull | null = null;
let doneTimer = 0;

/**
 * What's under the toggle grid: the quick launchers (inside the card) and the notifications' own panel (a sibling under
 * the card, to the screen's bottom). The launchers ride with the rest: left out they stayed where the laid-out grid
 * pushed them, over the notifications, a gap above.
 */
const below = () => [...document.querySelectorAll<HTMLElement>(".panel-body.together .cc3-launchers, .panel-body.together > .notif-own")];
const list3 = () => document.querySelector<HTMLElement>(".panel-body.together .cc3-list");

/** The pull under way, or a new one: v3's rest laid out (once), everything at where it is on screen. */
function begin(): Pull {
  if (pull && pull.to == null && pull.movers.every((m) => m.el.isConnected)) return pull;
  // Caught while easing (or left over): its end laid out at once, the new pull from there.
  clearTimeout(doneTimer);
  if (pull) finish(pull, pull.to ?? pull.was);
  const p = peekPull() ?? classicPull();
  for (const el of inline(p)) el.style.transition = "none";
  place(p, p.list && p.was ? p.h : 0);
  return (pull = peeking(p));
}

/** v3: the notifications' stacks show what the pull unfolds (see [ccPeeking]). */
function peeking(p: Pull) {
  if (p.grid) ccPeeking.value = p.was ? "fold" : "open";
  return p;
}

/** What a pull writes inline: its movers, v3's grid and card. */
const inline = (p: Pull) => [...p.movers.map((m) => m.el), ...(p.grid ? [p.grid] : []), ...(p.card ? [p.card] : [])];

/** v3: every toggle laid out (the cc-peek class on the grid and the card, whose classes preact never rewrites; the list's changes). */
function peekPull(): Pull | null {
  const list = list3();
  const grid = list?.querySelector<HTMLElement>(".cc3-grid");
  const card = list?.closest<HTMLElement>(".cc") ?? null;
  if (!list || !grid || !card) return null;
  const h = growth(card, list, grid);
  const n = grid.querySelectorAll(".cc3-cell").length;
  // A row is the grid's own column count (--cc-cols: six, five unfolded where the sliders stand beside it).
  const cols = Number(getComputedStyle(grid).getPropertyValue("--cc-cols")) || 6;
  grid.style.setProperty("--cc-rows", String(Math.max(1, Math.ceil((n - cols) / cols))));
  const own = document.querySelector<HTMLElement>(".panel-body.together > .notif-own");
  return { list, grid, card, own, movers: below().map((el) => ({ el, gain: 1 })), h, was: ccExpanded.value };
}

/**
 * The card's height folded (one compact row: the first six toggles, no launchers), then with everything laid out (the
 * card and its grid "cc-peek"): the travel of its bottom edge, and so of the notifications under it. Once per pull,
 * two layouts; the state it was in put back after the measure.
 */
function growth(card: HTMLElement, list: HTMLElement, grid: HTMLElement) {
  const [whole, lw] = [card.classList.contains("whole"), list.classList.contains("whole")];
  card.classList.remove("whole", "cc-peek");
  list.classList.remove("whole");
  grid.classList.remove("cc-peek");
  const folded = card.offsetHeight;
  card.classList.add("cc-peek");
  grid.classList.add("cc-peek");
  const h = Math.max(0, card.offsetHeight - folded);
  card.classList.toggle("whole", whole);
  list.classList.toggle("whole", lw);
  return h;
}

/** Classic: the rows spread apart from the third (its --i 3), what's under them with the last. */
function classicPull(): Pull {
  const grids = [...document.querySelectorAll<HTMLElement>(".panel-body.together .cc-main > .cc-grid")];
  const gain = (el: HTMLElement) => ((Number(el.style.getPropertyValue("--i")) || 3) - 3) / 2;
  const movers = [...grids.map((el) => ({ el, gain: gain(el) })), ...below().map((el) => ({ el, gain: 1 }))];
  return { list: null, grid: null, card: null, own: null, movers, h: 0, was: ccExpanded.value };
}

/**
 * v3: [r] of the rest shown (px, 0..h, past h the rubber band). Classic: [r] the spread. What's under the card is
 * carried by r - h: up while it's folded (the card is clipped to what's shown and the notifications' frost reaches on
 * down to the screen's bottom, --cc-ext), down past h (the card follows the finger too: the over-pull's stretch).
 */
function place(p: Pull, r: number) {
  if (p.grid) return placeV3(p as Pull & { grid: HTMLElement }, r);
  for (const m of p.movers) {
    m.el.style.translate = `0 ${r * m.gain}px`;
    m.el.style.setProperty("--cc-k", String(r / 120));
  }
}

function placeV3(p: Pull & { grid: HTMLElement }, r: number) {
  const k = p.h > 0 ? Math.min(1, Math.max(0, r / p.h)) : 1;
  const t = r - p.h;
  p.grid.style.setProperty("--cc-k", String(k));
  peekTo(k);
  for (const m of p.movers) m.el.style.translate = `0 ${m.el.closest(".cc") ? Math.min(0, t) : t}px`;
  p.card?.style.setProperty("translate", `0 ${Math.max(0, t)}px`);
  p.card?.style.setProperty("clip-path", `inset(0px 0px ${Math.max(0, -t)}px 0px round calc(var(--radius) * 1.5))`);
  p.own?.style.setProperty("--cc-ext", `${Math.max(0, -t)}px`);
  // Over-pulled (t > 0) the panel's own edge, grip and frost ride the band too: --cc-lift (shell.css) moves the panel
  // down by t and its body back up by t, so the card and notifications land where they did and the edge follows.
  panelOf(p)?.style.setProperty("--cc-lift", `${-Math.max(0, t)}px`);
}

/** The one panel the pull's card sits in (its --cc-lift moves the edge). */
const panelOf = (p: Pull) => p.card?.closest<HTMLElement>(".notif-panel") ?? null;

/** Following the finger: [dy] its travel, down to show (positive), up to fold (negative). */
export function stretch(dy: number) {
  const p = begin();
  if (!p.list) return place(p, band(dy));
  const { h } = p;
  const r = p.was ? (dy > 0 ? h + over(dy) : Math.max(0, h + dy)) : dy > h ? h + over(dy - h) : Math.max(0, dy);
  place(p, r);
}

/** Let go: [commit] to the other state, or back to this one. */
export function settle(commit: boolean) {
  const p = pull;
  if (!p) return;
  if (!p.list && commit) return setExpanded(expandedByDefault() || !ccExpanded.value);
  // Desktop mode never folds (the user, 2026-10-28): whatever the pull did, it settles whole.
  const to = expandedByDefault() || (commit ? !p.was : p.was);
  ease(p, p.list && to ? p.h : 0, to);
}

/** From where it is to [r], then laid out in state [on]. */
function ease(p: Pull, r: number, on: boolean) {
  // The values the finger left are the transitions' start (one style pass before they change).
  void inline(p)[0]?.offsetWidth;
  // Folding is its own quicker ease-out (no overshoot anywhere: the notifications' panel doesn't bounce).
  const [ms, ez, pts] = on ? [MS, EASE, EASE_PTS] : [FOLD_MS, FOLD_EASE, FOLD_PTS];
  for (const m of p.movers) m.el.style.transition = `translate ${ms}ms ${ez}`;
  p.grid?.style.setProperty("transition", `--cc-k ${ms}ms ${ez}`);
  p.card?.style.setProperty("transition", `translate ${ms}ms ${ez}, clip-path ${ms}ms ${ez}`);
  p.own?.style.setProperty("transition", `translate ${ms}ms ${ez}, --cc-ext ${ms}ms ${ez}`);
  // The panel keeps its own --q ease (shell.css [data-q]) beside the lift's.
  panelOf(p)?.style.setProperty("transition", `--q 280ms cubic-bezier(0.2, 0.9, 0.3, 1), --cc-lift ${ms}ms ${ez}`);
  p.to = on;
  // The groups ride the same ease, from where the finger left them to the end (at the translate's duration).
  const k0 = peekK;
  place(p, r);
  if (p.grid) {
    peekTo(k0);
    ride(k0, on ? 1 : 0, ms, pts);
  }
  clearTimeout(doneTimer);
  doneTimer = window.setTimeout(() => finish(p, on), ms + 40);
}

/** The end state laid out (the render) and the pull's inline values gone in the same frame: nothing jumps. */
function finish(p: Pull, on: boolean) {
  if (pull === p) pull = null;
  // The notifications' own list: when the card folds it grows, its scroll is unchanged (it is not in the card's scroll).
  ccExpanded.value = on;
  // Laid out now, not at the render (a microtask away): a pull begun right after measures the right state.
  p.list?.classList.toggle("whole", on);
  p.card?.classList.toggle("whole", on);
  clearInline(p);
}

/** What the pull wrote inline gone: the movers', the grid's (its peek too), the card's, the notifications' panel's. */
function clearInline(p: Pull) {
  for (const el of inline(p)) {
    el.style.transition = "";
    el.style.translate = "";
    el.style.removeProperty("--cc-k");
  }
  p.card?.style.removeProperty("clip-path");
  p.own?.style.removeProperty("--cc-ext");
  panelOf(p)?.style.removeProperty("--cc-lift");
  panelOf(p)?.style.removeProperty("transition");
  p.card?.classList.remove("cc-peek");
  p.grid?.classList.remove("cc-peek");
  cancelAnimationFrame(rideFrame);
  for (const a of peekAnims) a.cancel();
  peekAnims.clear();
  peeked.clear();
  peekK = 0;
  ccPeeking.value = null;
}

/** [els] shown [by] px higher than laid out (0: not moved), eased to their place. */
function slide(els: HTMLElement[], by: (el: HTMLElement) => number) {
  // Measured first, then written: one layout.
  const moved = els.map((el) => [el, by(el)] as const).filter(([, d]) => Math.abs(d) >= 0.5);
  for (const [el, d] of moved) {
    el.style.transition = "none";
    el.style.translate = `0 ${-d}px`;
  }
  void moved[0]?.[0].offsetWidth;
  for (const [el] of moved) {
    el.style.transition = `translate ${MS}ms ${EASE}`;
    el.style.translate = "";
  }
  window.setTimeout(() => moved.forEach(([el]) => (el.style.transition = "")), MS + 40);
}

/**
 * [on] shown whole, without the finger. v3: eased as a pull let go. Classic: laid out once in the new state, each mover
 * played from where it was on screen (the finger's spread included) to its place. [anchor] (scrolling folds it): the
 * notifications stay where they are on screen instead - the list's scroll takes up what the rows above gave back - and
 * nothing animates.
 */
export function setExpanded(on: boolean, anchor?: HTMLElement | null) {
  if (on === ccExpanded.value && !pull) return;
  if (!anchor && list3()) {
    const p = begin();
    return ease(p, on ? p.h : 0, on);
  }
  relayout(on, anchor);
}

/** Laid out once in state [on]: the movers played from where they were (or, [anchor], the notifications kept still). */
function relayout(on: boolean, anchor?: HTMLElement | null) {
  const before = new Map(movers().map((el) => [el, el.getBoundingClientRect().top]));
  const items = anchor ? document.querySelector<HTMLElement>(".panel-body.together > .notif-own .notif-items") : null;
  const itemsTop = items?.getBoundingClientRect().top ?? 0;
  clearTimeout(doneTimer);
  if (pull) finish(pull, on);
  ccExpanded.value = on;
  // After the render, before the paint.
  requestAnimationFrame(() => {
    if (anchor && items) anchor.scrollTop += items.getBoundingClientRect().top - itemsTop;
    else slide(movers(), (el) => el.getBoundingClientRect().top - (before.get(el) ?? el.getBoundingClientRect().top));
  });
}

/** Classic's movers: each row of tiles, and what's under the control center. */
const movers = () => [...document.querySelectorAll<HTMLElement>(".panel-body.together .cc-main > .cc-grid"), ...below()];
