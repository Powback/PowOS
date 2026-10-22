/**
 * The widget detail sheet (apps/sheet.ts DetailSheet - host.DetailSheet for PowOS apps' islands): a frosted popover
 * (.tile.sheet.pop: the menus' material, home stays in place under it) anchored to the widget - under it when there's
 * room, else over it. A tap outside, a swipe down on it (not on a slider: those own their drags) or Back closes it.
 * The scrim takes every touch outside, so nothing reaches home (no page swipe, no edit mode) while it's open.
 */
import { useEffect, useRef } from "preact/hooks";
import { detailSheet } from "../apps/sheet.ts";
import { topBack } from "../state.ts";

const EDGE = 12;
/** A drag this far down closes it. */
const CLOSE_PX = 70;

export function WidgetSheet() {
  const d = detailSheet.value;
  const close = useRef(() => {});
  close.current = () => d?.onClose();
  const panel = useRef<HTMLDivElement>(null);
  const drag = useRef<{ y: number; id: number; dy: number } | null>(null);
  useEffect(() => {
    if (!d) return;
    const back = () => close.current();
    topBack.value = back;
    return () => {
      if (topBack.peek() === back) topBack.value = null;
    };
  }, [d?.id]);
  // The body scrolls up and down only when it's longer than the sheet; else a vertical drag anywhere is the swipe down.
  useEffect(() => {
    const b = panel.current?.querySelector<HTMLElement>(".wsheet-body");
    if (b) b.classList.toggle("scrolls", b.scrollHeight > b.clientHeight + 1);
  });
  if (!d) return null;

  const vw = innerWidth;
  const vh = innerHeight;
  const a = d.anchor;
  const w = Math.min(vw - 2 * EDGE, Math.max(a.width, 320), 460);
  const left = Math.max(EDGE, Math.min(vw - w - EDGE, a.left + a.width / 2 - w / 2));
  const below = vh - a.bottom - EDGE;
  const above = a.top - EDGE;
  const under = below >= 300 || below >= above;
  const place = under
    ? { top: `${Math.round(a.bottom + 8)}px`, maxHeight: `${Math.round(below - 8)}px` }
    : { bottom: `${Math.round(vh - a.top + 8)}px`, maxHeight: `${Math.round(above - 8)}px` };

  const mine = (t: EventTarget | null) => !(t instanceof Element && t.closest("input, [role=slider], .wsheet-body [data-owns-gesture]"));
  const move = (dy: number) => {
    const el = panel.current;
    if (el) el.style.transform = dy > 0 ? `translateY(${dy}px)` : "";
  };

  return (
    <div
      class="wsheet-scrim"
      data-owns-gesture
      onPointerDown={(e) => e.stopPropagation()}
      onTouchStart={(e) => e.stopPropagation()}
      onClick={(e) => {
        if (e.target === e.currentTarget) close.current();
      }}
    >
      <div
        ref={panel}
        class="wsheet tile sheet pop"
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
          if (g.dy > 8) move(g.dy);
        }}
        onPointerUp={() => {
          const g = drag.current;
          drag.current = null;
          move(0);
          if (g && g.dy > CLOSE_PX) close.current();
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
