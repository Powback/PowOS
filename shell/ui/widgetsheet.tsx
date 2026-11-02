/**
 * The widget detail sheet (apps/sheet.ts DetailSheet - host.DetailSheet for PowOS apps' islands): a frosted popover
 * (.tile.sheet.pop: the menus' material, home stays in place under it) anchored to the widget - under it when there's
 * room, else over it. A tap outside, a swipe down on it (not on a slider: those own their drags) or Back closes it.
 * The scrim takes every touch outside, so nothing reaches home (no page swipe, no edit mode) while it's open.
 * Closing never pops out (docs/DESIGN-LANGUAGE.md §6): the last sheet stays mounted, `.leaving`, while it fades and
 * shrinks (ui/reveal.tsx usePresence); a swipe down follows the finger (`translate`) and closes from where it let go.
 */
import { useEffect, useRef } from "preact/hooks";
import { detailSheet, type OpenSheet } from "../apps/sheet.ts";
import { usePresence } from "./reveal.tsx";
import { topBack } from "../state.ts";

/** The gutter: theme.css --edge (16 dp, docs/DESIGN-LANGUAGE.md §3), read where it is used. */
const edge = () => parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--edge")) || 16;
/** A drag this far down closes it. */
const CLOSE_PX = 70;

/**
 * The screen space a sheet may take: below the status bar, above home's foot (the search pill and the dock, wherever
 * they are shown) and the navigation bar.
 */
function room() {
  const css = getComputedStyle(document.documentElement);
  const inset = (n: string) => parseFloat(css.getPropertyValue(n)) || 0;
  const EDGE = edge();
  let floor = innerHeight - Math.max(EDGE, inset("--inset-bottom") + EDGE);
  for (const el of document.querySelectorAll<HTMLElement>(".home > .bar .bar-pill, .home .dock")) {
    const r = el.getBoundingClientRect();
    if (r.height > 0 && r.width > 0 && getComputedStyle(el).visibility !== "hidden") floor = Math.min(floor, r.top - EDGE);
  }
  return { top: Math.max(EDGE, inset("--inset-top") + EDGE), floor };
}

/** The open sheet ([live]), else the last one while it leaves ([leaving]), else null. */
function useShown() {
  const live = detailSheet.value;
  const last = useRef<OpenSheet | null>(null);
  if (live) last.current = live;
  const { on, leaving } = usePresence(!!live);
  return { live, leaving, d: live ?? (on ? last.current : null) };
}

export function WidgetSheet() {
  const { live, leaving, d } = useShown();
  const close = useRef(() => {});
  close.current = () => live?.onClose();
  const panel = useRef<HTMLDivElement>(null);
  const drag = useRef<{ y: number; id: number; dy: number } | null>(null);
  useEffect(() => {
    if (!live) return;
    const back = () => close.current();
    topBack.value = back;
    return () => {
      if (topBack.peek() === back) topBack.value = null;
    };
  }, [live?.id]);
  // The body scrolls up and down only when it's longer than the sheet; else a vertical drag anywhere is the swipe down.
  useEffect(() => {
    const b = panel.current?.querySelector<HTMLElement>(".wsheet-body");
    if (b) b.classList.toggle("scrolls", b.scrollHeight > b.clientHeight + 1);
  });
  if (!d) return null;

  const vw = innerWidth;
  const EDGE = edge();
  const a = d.anchor;
  const w = Math.min(vw - 2 * EDGE, Math.max(a.width, 320), 460);
  const left = Math.max(EDGE, Math.min(vw - w - EDGE, a.left + a.width / 2 - w / 2));
  const { top, floor } = room();
  const below = floor - a.bottom - 8;
  const above = a.top - top - 8;
  // Under the widget when there's room for most of it there, else over it (a widget low on the page); never over the
  // status bar, the search pill or the dock - the body scrolls inside when the controls are longer than that.
  const under = below >= 300 || below >= above;
  const place = under
    ? { top: `${Math.round(a.bottom + 8)}px`, maxHeight: `${Math.round(below)}px` }
    : { bottom: `${Math.round(innerHeight - a.top + 8)}px`, maxHeight: `${Math.round(above)}px` };

  const mine = (t: EventTarget | null) => !(t instanceof Element && t.closest("input, [role=slider], .wsheet-body [data-owns-gesture]"));
  // Finger-tied: `translate` under the finger (no transition while .dragging), the spring back on release.
  const move = (dy: number, held = false) => {
    const el = panel.current;
    if (!el) return;
    el.classList.toggle("dragging", held);
    el.style.translate = dy > 0 ? `0 ${dy}px` : "";
  };

  return (
    <div
      class={`wsheet-scrim${leaving ? " leaving" : ""}`}
      data-owns-gesture
      onPointerDown={(e) => e.stopPropagation()}
      onTouchStart={(e) => e.stopPropagation()}
      onClick={(e) => {
        if (e.target === e.currentTarget) close.current();
      }}
    >
      <div
        ref={panel}
        key={d.id}
        class={`wsheet tile sheet pop${leaving ? " leaving" : ""}`}
        role="dialog"
        aria-label={d.title}
        style={{ left: `${Math.round(left)}px`, width: `${Math.round(w)}px`, ...place }}
        onPointerDown={(e) => {
          const body = panel.current?.querySelector(".wsheet-body");
          if (!mine(e.target) || (body && body.scrollTop > 0 && body.contains(e.target as Node))) return;
          drag.current = { y: e.clientY, id: e.pointerId, dy: 0 };
        }}
        onPointerMove={(e) => {
          const g = drag.current;
          if (!g || g.id !== e.pointerId) return;
          g.dy = e.clientY - g.y;
          if (g.dy > 8) move(g.dy, true);
        }}
        onPointerUp={() => {
          const g = drag.current;
          drag.current = null;
          // Past the line it leaves from where the finger let go; short of it, springs back.
          if (g && g.dy > CLOSE_PX) (panel.current?.classList.remove("dragging"), close.current());
          else move(0);
        }}
        onPointerCancel={() => ((drag.current = null), move(0))}
      >
        <div class="wsheet-head">
          <span class="wsheet-grab" />
          {d.title && <span class="wsheet-title">{d.title}</span>}
        </div>
        <div class="wsheet-body">{d.children}</div>
      </div>
    </div>
  );
}
