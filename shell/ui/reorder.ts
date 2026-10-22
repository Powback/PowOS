/**
 * Edit mode's press, lift and drag, as home's (grid.tsx): a long press (LONG_PRESS_MS, a light haptic) puts the
 * container in edit mode and lifts what was pressed - its place stays as a faint ghost (.lifted, home's 25%), a copy
 * of it follows the finger (.carried: home's scale and drop shadow) - and let go it lands (the haptic again). Edit mode
 * stays until [editing] is set false (its "done", a tap beside, the panel shut); in it, a tap on an item is nothing (it
 * selects it: [onSelect]), every move is a long press away, as on home.
 *
 * This module is for ordered containers (the control center's eight, a category's members): an item's place is its
 * index, and while one is carried the others make room live - each eased from where it was (a FLIP), nothing laid out
 * by hand. Home places tiles on free cells instead (grid.tsx aim/startCarry); it shares the press timing and the lift.
 *
 * Items are the container's descendants with data-key (directly or in rows) whose nearest [data-reorder] is this one:
 * a container inside an item (a category's members inside its tile) is its own.
 */
import type { Signal } from "@preact/signals";
import { useLayoutEffect, useRef, useState } from "preact/hooks";

/** Home's long press (grid.tsx, apps.tsx): held this long (ms), a tile lifts. */
export const LONG_PRESS_MS = 420;
/** Moved this far (CSS px) before the hold, it's a scroll or a swipe, not a lift. */
const SLOP = 10;

interface Press {
  key: string;
  pointer: number;
  x0: number;
  y0: number;
  x: number;
  y: number;
  /** Where the finger holds the item, from its top left. */
  gx: number;
  gy: number;
  lifted: boolean;
  moved: boolean;
  timer: number;
  ghost: HTMLElement | null;
}

export interface Reorder {
  /** The order to render: the live one while an item is carried. */
  order: string[];
  /** The container's props. */
  handlers: Record<string, unknown>;
  /** An item is being carried. */
  carrying: boolean;
}

/**
 * [keys] in their order; [done] gets the new order when a carried item lands somewhere else. [editing]: the edit
 * mode it enters (shared by every container that edits together). [onLift]: an item lifted (another container's open
 * row to close, the page's own gestures to hold off). [onSelect]: a tap in edit mode, or a lift let go where it was.
 */
export function useReorder(
  keys: string[],
  done: (keys: string[]) => void,
  editing: Signal<boolean>,
  opts: {
    onLift?: (key: string) => void;
    onLand?: () => void;
    onSelect?: (key: string) => void;
    /** A long press lifts only in edit mode (entered some other way): outside it, the item's own long press is its. */
    onlyEditing?: boolean;
  } = {},
): Reorder {
  const box = useRef<HTMLElement>(null);
  const [live, setLiveState] = useState<string[] | null>(null);
  // The live order as of the last move, not the last render: moves come faster than renders on a busy phone, and one
  // computed from a render behind put the item a slot off (the gate's cc-reorder under load, 2026-10-22).
  const liveRef = useRef<string[] | null>(null);
  const setLive = (v: string[] | null) => ((liveRef.current = v), setLiveState(v));
  const press = useRef<Press | null>(null);
  const swallow = useRef(false);
  const order = live ?? keys;
  const ours = (el: Element | null) => !!el && el.closest("[data-reorder]") === box.current;
  const item = (k: string) =>
    [...(box.current?.querySelectorAll<HTMLElement>(`[data-key="${CSS.escape(k)}"]`) ?? [])].find((el) => ours(el) && !el.classList.contains("carried")) ?? null;

  /** The copy under the finger, in the item's own row (so the row's rules still dress it), placed from its offset. */
  const follow = () => {
    const p = press.current;
    const g = p?.ghost;
    const host = g?.offsetParent as HTMLElement | null;
    if (!p || !g || !host) return;
    // Absolute in its row: from the row's padding box, which a row that scrolls (the members' strip) has scrolled.
    const h = host.getBoundingClientRect();
    g.style.left = `${p.x - p.gx - h.left - host.clientLeft + host.scrollLeft}px`;
    g.style.top = `${p.y - p.gy - h.top - host.clientTop + host.scrollTop}px`;
  };

  // FLIP: every item that moved since the last order eases from its old place; the lifted one keeps its faint ghost.
  // Boxes relative to the container: the panel opening, scrolling or sliding under the finger moves them all at once,
  // which is no move of theirs (measured on screen, a slot was missed while the shade was still opening - the gate's
  // cc-reorder under load, 2026-10-22).
  const rects = useRef(new Map<string, DOMRect>());
  const rel = (r: DOMRect) => {
    const b = box.current?.getBoundingClientRect();
    return b ? new DOMRect(r.left - b.left, r.top - b.top, r.width, r.height) : r;
  };
  useLayoutEffect(() => {
    const next = new Map<string, DOMRect>();
    for (const k of order) {
      const el = item(k);
      if (!el) continue;
      if (press.current?.lifted && press.current.key === k) el.classList.add("lifted");
      // Its laid-out box, not where a FLIP still under way shows it.
      for (const an of el.getAnimations()) an.cancel();
      const r = rel(el.getBoundingClientRect());
      next.set(k, r);
      const was = rects.current.get(k);
      if (live && was && (Math.abs(was.left - r.left) > 0.5 || Math.abs(was.top - r.top) > 0.5))
        el.animate([{ transform: `translate(${was.left - r.left}px, ${was.top - r.top}px)` }, { transform: "none" }], {
          duration: 180,
          easing: "cubic-bezier(0.2, 0.9, 0.3, 1)",
        });
    }
    rects.current = next;
    follow();
  }, [order.join()]);

  // Gone while something was lifted (the panel shut mid-drag): no copy left behind, no faint item, no timer.
  useLayoutEffect(
    () => () => {
      const p = press.current;
      if (!p) return;
      clearTimeout(p.timer);
      p.ghost?.remove();
      item(p.key)?.classList.remove("lifted");
      if (p.lifted) opts.onLand?.();
      press.current = null;
    },
    [],
  );

  const lift = (p: Press) => {
    const el = item(p.key);
    if (!el) return;
    p.lifted = true;
    navigator.vibrate?.(10);
    editing.value = true;
    opts.onLift?.(p.key);
    try {
      box.current?.setPointerCapture(p.pointer);
    } catch {}
    // The copy: the item as it looks, in its row (absolute over it), carried; the item itself a faint ghost.
    const g = el.cloneNode(true) as HTMLElement;
    g.classList.add("carried");
    g.removeAttribute("data-key");
    g.setAttribute("aria-hidden", "true");
    const r = el.getBoundingClientRect();
    g.style.width = `${r.width}px`;
    g.style.height = `${r.height}px`;
    el.parentElement?.appendChild(g);
    p.ghost = g;
    el.classList.add("lifted");
    rects.current = new Map(order.map((k) => [k, item(k)]).filter((x): x is [string, HTMLElement] => !!x[1]).map(([k, e]) => [k, rel(e.getBoundingClientRect())]));
    follow();
    setLive([...order]);
  };

  /** Let go ([cancel]: the system took the pointer, the panel went - the lift is dropped, the order as it was). */
  const end = (cancel = false) => {
    const p = press.current;
    press.current = null;
    if (!p) return;
    clearTimeout(p.timer);
    if (!p.lifted) return;
    p.ghost?.remove();
    item(p.key)?.classList.remove("lifted");
    if (cancel) {
      opts.onLand?.();
      setLive(null);
      return;
    }
    // The release's own click (if any) is swallowed; one that never comes doesn't eat a later tap.
    swallow.current = true;
    window.setTimeout(() => (swallow.current = false), 0);
    const final = liveRef.current;
    if (p.moved && final && final.join() !== keys.join()) {
      navigator.vibrate?.(10);
      done(final);
    } else if (!p.moved) opts.onSelect?.(p.key);
    opts.onLand?.();
    setLive(null);
  };

  const handlers = {
    ref: box,
    "data-reorder": "",
    onPointerDown: (e: PointerEvent) => {
      if (e.button) return;
      const el = (e.target as Element).closest<HTMLElement>("[data-key]");
      if (!el || !ours(el) || (e.target as Element).closest("[data-no-lift]")) return;
      if (opts.onlyEditing && !editing.value) return;
      swallow.current = false;
      const r = el.getBoundingClientRect();
      const p: Press = {
        key: el.dataset.key!,
        pointer: e.pointerId,
        x0: e.clientX,
        y0: e.clientY,
        x: e.clientX,
        y: e.clientY,
        gx: e.clientX - r.left,
        gy: e.clientY - r.top,
        lifted: false,
        moved: false,
        timer: 0,
        ghost: null,
      };
      p.timer = window.setTimeout(() => press.current === p && lift(p), LONG_PRESS_MS);
      press.current = p;
    },
    onPointerMove: (e: PointerEvent) => {
      const p = press.current;
      if (!p || e.pointerId !== p.pointer) return;
      p.x = e.clientX;
      p.y = e.clientY;
      const far = Math.hypot(p.x - p.x0, p.y - p.y0) > SLOP;
      if (!p.lifted) {
        // Moved before the hold: a scroll, a swipe, a tap that slid - not a lift.
        if (far) {
          clearTimeout(p.timer);
          press.current = null;
        }
        return;
      }
      if (far) p.moved = true;
      // The slot whose middle is nearest the finger is where it goes - measured from the laid-out boxes (rects, taken
      // before each FLIP), not mid-ease, and only when it's nearer than the carried one's own slot by a tenth of an
      // item: near a boundary it doesn't flip back and forth.
      const now = liveRef.current ?? order;
      const b = box.current?.getBoundingClientRect();
      const fx = p.x - (b?.left ?? 0);
      const fy = p.y - (b?.top ?? 0);
      const mid = (r: DOMRect) => Math.hypot(r.left + r.width / 2 - fx, r.top + r.height / 2 - fy);
      let best = -1;
      let dist = Infinity;
      now.forEach((k, i) => {
        if (k === p.key) return;
        const r = rects.current.get(k);
        if (!r) return;
        const dd = mid(r);
        if (dd < dist) ((dist = dd), (best = i));
      });
      const from = now.indexOf(p.key);
      const r0 = best >= 0 ? rects.current.get(now[best]) : undefined;
      const own = rects.current.get(p.key);
      const size = r0 ? Math.max(r0.width, r0.height) : 0;
      if (best >= 0 && best !== from && r0 && dist < size * 0.6 && (!own || dist < mid(own) - size * 0.1)) {
        const next = now.filter((k) => k !== p.key);
        next.splice(best, 0, p.key);
        setLive(next);
      } else follow();
    },
    onPointerUp: () => end(),
    onPointerCancel: () => end(true),
    // Carried: the page under it doesn't scroll (and so doesn't cancel the pointer).
    onTouchMove: (e: TouchEvent) => press.current?.lifted && e.cancelable && e.preventDefault(),
    // A lift's release isn't also a tap; in edit mode a tap on an item selects it, it doesn't switch or open.
    onClickCapture: (e: Event) => {
      const t = e.target as Element;
      if (t.closest?.("[data-edit-ok]")) return;
      const el = t.closest?.<HTMLElement>("[data-key]");
      const lifted = swallow.current;
      if (!lifted && !(editing.value && el && ours(el))) return;
      swallow.current = false;
      e.stopPropagation();
      e.preventDefault();
      if (!lifted && el) opts.onSelect?.(el.dataset.key!);
    },
    onContextMenu: (e: Event) => e.preventDefault(),
  };
  return { order, handlers, carrying: live != null };
}
