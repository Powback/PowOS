/**
 * Choosing several home tiles at once, in edit mode: a rectangle drawn on empty space (the marquee) or taps pick them;
 * picked, they move together (grid.tsx carries them as one) and 2+ apps make a folder.
 *
 * The marquee never fights home's page swipe: it starts only in edit mode, on empty space, when the finger was held
 * still for a moment first (MARQUEE_DWELL) or moves up/down first (edit mode has no up/down gesture of its own). A
 * quick sideways swipe is still the page turning.
 *
 * Nothing here draws a frame at rest: the rectangle exists only while a finger draws it.
 */
import { effect, signal } from "@preact/signals";
import { editing } from "../state.ts";
import { held } from "./gesture.ts";
import type { Cell, HomeItem } from "../types.ts";

export const MARQUEE_DWELL = 180;

/** The tiles picked together (keys), edit mode only. */
export const chosen = signal<string[]>([]);

/** The rectangle being drawn, in the page's coordinates (as carry's x/y); null when none is. */
export const marquee = signal<{ x0: number; y0: number; x1: number; y1: number } | null>(null);

// Leaving edit mode lets go of them.
effect(() => {
  if (!editing.value && chosen.peek().length) chosen.value = [];
});

export const isChosen = (key: string) => chosen.value.includes(key);

export function toggleChosen(key: string) {
  chosen.value = isChosen(key) ? chosen.value.filter((k) => k !== key) : [...chosen.value, key];
}

type Box = { left: number; top: number; width: number; height: number };

/** The tiles of [items] (boxes by [boxOf]) the rectangle touches, added to the ones picked when it started. */
function hits(items: HomeItem[], boxOf: (i: HomeItem) => Box, r: NonNullable<typeof marquee.value>, before: string[]) {
  const [l, t, rr, b] = [Math.min(r.x0, r.x1), Math.min(r.y0, r.y1), Math.max(r.x0, r.x1), Math.max(r.y0, r.y1)];
  const hit = items.filter((i) => {
    const x = boxOf(i);
    return x.left < rr && l < x.left + x.width && x.top < b && t < x.top + x.height;
  });
  return [...new Set([...before, ...hit.map((i) => i.key)])];
}

/**
 * Draws the rectangle from where the finger went down ([from], client px; [origin]: the page's corner) to [e0], then
 * with the window's pointer events until it lifts: the tiles it touches are picked as it goes. [items] and [boxOf]
 * are the page on screen's.
 */
export function startMarquee(e0: PointerEvent, from: { x: number; y: number }, page: { origin: { left: number; top: number }; items: () => HomeItem[]; boxOf: (i: HomeItem) => Box }) {
  const { origin, items, boxOf } = page;
  const before = chosen.value;
  const x0 = from.x - origin.left;
  const y0 = from.y - origin.top;
  held.value = true;
  const to = (ev: PointerEvent) => {
    const r = { x0, y0, x1: ev.clientX - origin.left, y1: ev.clientY - origin.top };
    marquee.value = r;
    const next = hits(items(), boxOf, r, before);
    if (next.length !== chosen.value.length) navigator.vibrate?.(5);
    chosen.value = next;
  };
  const move = (ev: PointerEvent) => ev.pointerId === e0.pointerId && to(ev);
  const up = (ev: PointerEvent) => {
    if (ev.pointerId !== e0.pointerId) return;
    removeEventListener("pointermove", move);
    removeEventListener("pointerup", up);
    removeEventListener("pointercancel", up);
    marquee.value = null;
    held.value = false;
  };
  addEventListener("pointermove", move);
  addEventListener("pointerup", up);
  addEventListener("pointercancel", up);
  to(e0);
}

/** The picked tiles that go with [lead] when it's carried (itself among them), or null when it goes alone. */
export function partyOf(lead: HomeItem | undefined, items: HomeItem[]): HomeItem[] | null {
  if (!lead || !isChosen(lead.key) || chosen.value.length < 2) return null;
  const party = items.filter((i) => i.cell && chosen.value.includes(i.key));
  return party.length > 1 ? party : null;
}

/**
 * Where the carried [party] lands when its lead tile goes to cell [to]: every tile moved by the same whole cells (the
 * group kept inside the grid), or null when one would land on a tile outside the party.
 */
export function partyCells(party: HomeItem[], to: { lead: HomeItem; cell: Cell }, others: Cell[], grid: { columns: number; rows: number; shown: (i: HomeItem) => Cell }) {
  const { lead, cell: leadCell } = to;
  const { shown } = grid;
  const cells = party.map((i) => [i, shown(i)] as const);
  const minX = Math.min(...cells.map(([, c]) => c.x));
  const minY = Math.min(...cells.map(([, c]) => c.y));
  const maxX = Math.max(...cells.map(([, c]) => c.x + c.w));
  const maxY = Math.max(...cells.map(([, c]) => c.y + c.h));
  const dx = Math.max(-minX, Math.min(grid.columns - maxX, leadCell.x - lead.cell!.x));
  const dy = Math.max(-minY, Math.min(grid.rows - maxY, leadCell.y - lead.cell!.y));
  const out = new Map<string, Cell>();
  for (const [i, c] of cells) {
    const at = { ...c, x: c.x + dx, y: c.y + dy };
    if (others.some((o) => o.x < at.x + at.w && at.x < o.x + o.w && o.y < at.y + at.h && at.y < o.y + o.h)) return null;
    // Apps and folders show 1x1 but keep their own cell's size.
    out.set(i.key, { ...i.cell!, x: at.x, y: at.y });
  }
  return out;
}
