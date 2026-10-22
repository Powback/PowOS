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
 * Let go, the same two values ease to the end state, which is then laid out once (no jump: the translate was exactly
 * the layout's difference). Nothing runs at rest.
 *
 * Classic (Categories): the rows below spread apart (a rubber band, translates only) and a commit lays the new state
 * out once, each row played from where the finger left it (a FLIP).
 */
import { signal } from "@preact/signals";

/** Every category's members shown (only in the one panel, only while it's open). */
export const ccExpanded = signal(false);
/** The control center's edit mode (ui/reorder.ts, as home's): entered by a long press on a tile, left by its "done". */
export const ccEditing = signal(false);

/** The finger's travel (CSS px) to the classic rows' spread: easy at first, firmer the further it goes. */
const band = (d: number) => Math.sign(d) * 120 * (1 - Math.exp(-Math.abs(d) / 200));
/** Past the end (v3): a short rubber band, at most OVER px. */
const OVER = 40;
const over = (d: number) => OVER * (1 - Math.exp(-Math.max(0, d) / 100));
/** Pulled this far (CSS px, the finger's travel) it commits on its own; a flick (gesture.ts FLICK) does too. */
export const EXPAND_AT = 56;
const MS = 260;
const EASE = "cubic-bezier(0.2, 0.9, 0.3, 1)";

/** What the finger moves; [gain] of its spread (classic rows spread apart, the rest moves whole). */
type Mover = { el: HTMLElement; gain: number };
type Pull = {
  /** v3's list and its grid (laid out whole while the pull lasts: the grid's "cc-peek"), or null: classic. */
  list: HTMLElement | null;
  grid: HTMLElement | null;
  movers: Mover[];
  /** v3: the rest's height (px) - the row's bottom to the list's, laid out whole. */
  h: number;
  /** Shown whole when the pull began. */
  was: boolean;
  /** Let go: the state it's easing to. */
  to?: boolean;
};
let pull: Pull | null = null;
let doneTimer = 0;

/** What's under the control center: the notifications' header and list. */
const below = () => [...document.querySelectorAll<HTMLElement>(".panel-body.together .cc ~ *")];
const list3 = () => document.querySelector<HTMLElement>(".panel-body.together .cc3-list");

/** The rest's height in [list] laid out whole: from the first row's bottom to the list's. */
function restHeight(list: HTMLElement) {
  const cells = list.querySelectorAll<HTMLElement>(".cc3-cell");
  return cells.length > 6 ? Math.max(0, list.getBoundingClientRect().bottom - cells[5].getBoundingClientRect().bottom) : 0;
}

/** The pull under way, or a new one: v3's rest laid out (once), everything at where it is on screen. */
function begin(): Pull {
  if (pull && pull.to == null && pull.movers.every((m) => m.el.isConnected)) return pull;
  // Caught while easing (or left over): its end laid out at once, the new pull from there.
  clearTimeout(doneTimer);
  if (pull) finish(pull, pull.to ?? pull.was);
  const p = peekPull() ?? classicPull();
  for (const el of inline(p)) el.style.transition = "none";
  place(p, p.list && p.was ? p.h : 0);
  return (pull = p);
}

/** What a pull writes inline: its movers, v3's grid. */
const inline = (p: Pull) => [...p.movers.map((m) => m.el), ...(p.grid ? [p.grid] : [])];

/** v3: every toggle laid out (the cc-peek class on the grid, whose class preact never rewrites; the list's changes). */
function peekPull(): Pull | null {
  const list = list3();
  const grid = list?.querySelector<HTMLElement>(".cc3-grid");
  if (!list || !grid) return null;
  grid.classList.add("cc-peek");
  const n = grid.querySelectorAll(".cc3-cell").length;
  grid.style.setProperty("--cc-rows", String(Math.max(1, Math.ceil((n - 6) / 6))));
  return { list, grid, movers: below().map((el) => ({ el, gain: 1 })), h: restHeight(list), was: ccExpanded.value };
}

/** Classic: the rows spread apart from the third (its --i 3), what's under them with the last. */
function classicPull(): Pull {
  const grids = [...document.querySelectorAll<HTMLElement>(".panel-body.together .cc-main > .cc-grid")];
  const gain = (el: HTMLElement) => ((Number(el.style.getPropertyValue("--i")) || 3) - 3) / 2;
  const movers = [...grids.map((el) => ({ el, gain: gain(el) })), ...below().map((el) => ({ el, gain: 1 }))];
  return { list: null, grid: null, movers, h: 0, was: ccExpanded.value };
}

/** v3: [r] of the rest shown (px, 0..h, past h the rubber band). Classic: [r] the spread. */
function place(p: Pull, r: number) {
  if (p.grid) {
    const k = p.h > 0 ? Math.min(1, Math.max(0, r / p.h)) : 1;
    p.grid.style.setProperty("--cc-k", String(k));
    for (const m of p.movers) m.el.style.translate = `0 ${r - p.h}px`;
    return;
  }
  for (const m of p.movers) {
    m.el.style.translate = `0 ${r * m.gain}px`;
    m.el.style.setProperty("--cc-k", String(r / 120));
  }
}

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
  if (!p.list && commit) return setExpanded(!ccExpanded.value);
  const to = commit ? !p.was : p.was;
  ease(p, p.list && to ? p.h : 0, to);
}

/** From where it is to [r], then laid out in state [on]. */
function ease(p: Pull, r: number, on: boolean) {
  // The values the finger left are the transitions' start (one style pass before they change).
  void inline(p)[0]?.offsetWidth;
  for (const m of p.movers) m.el.style.transition = `translate ${MS}ms ${EASE}`;
  p.grid?.style.setProperty("transition", `--cc-k ${MS}ms ${EASE}`);
  p.to = on;
  place(p, r);
  clearTimeout(doneTimer);
  doneTimer = window.setTimeout(() => finish(p, on), MS + 40);
}

/** The end state laid out (the render) and the pull's inline values gone in the same frame: nothing jumps. */
function finish(p: Pull, on: boolean) {
  if (pull === p) pull = null;
  const scroller = p.list?.closest<HTMLElement>(".notif-list");
  const st = scroller?.scrollTop ?? 0;
  ccExpanded.value = on;
  // Laid out now, not at the render (a microtask away): a pull begun right after measures the right state.
  p.list?.classList.toggle("whole", on);
  for (const el of inline(p)) {
    el.style.transition = "";
    el.style.translate = "";
    el.style.removeProperty("--cc-k");
  }
  p.grid?.classList.remove("cc-peek");
  // Folded at the list's end: the list is shorter, its scroll clamped - what's in it eases down from where it was.
  if (scroller) slide([...scroller.children] as HTMLElement[], () => st - scroller.scrollTop);
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
  const items = anchor ? document.querySelector<HTMLElement>(".panel-body.together .cc ~ .notif-items") : null;
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
