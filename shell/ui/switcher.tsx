/**
 * A task's card in the switcher (recents.tsx, a layer of home): its app and its last frame. A tap opens it (from the
 * card's frame, which the host grows the app out of); a swipe up removes it; sideways the row scrolls.
 */
import { useRef } from "preact/hooks";
import type { RecentTask } from "../types.ts";

/** Slid up this far (of its height), or flicked (px/ms), a card is removed. */
const REMOVE = 0.3;
const FLICK = 0.6;
const SLOP = 10;

export interface Rect {
  left: number;
  top: number;
  width: number;
  height: number;
}

export function TaskCard({
  t,
  current,
  onOpen,
  onRemove,
}: {
  t: RecentTask;
  /** The first card: where the window of the app the switcher was opened over lands (recents.tsx). */
  current?: boolean;
  onOpen: (id: number, from: Rect) => void;
  onRemove: (id: number) => void;
}) {
  const el = useRef<HTMLDivElement>(null);
  const shot = useRef<HTMLImageElement>(null);
  const drag = useRef<{ x: number; y: number; t: number; dy: number; up: boolean | null } | null>(null);
  const settle = (dy: number) => {
    const card = el.current!;
    card.style.transition = "transform 180ms ease, opacity 180ms ease";
    card.style.transform = dy ? `translateY(${dy}px)` : "";
    card.style.opacity = dy ? "0" : "";
  };
  return (
    <div
      ref={el}
      class={`task ${current ? "current" : ""}`}
      data-task={t.id}
      onPointerDown={(e) => {
        drag.current = { x: e.clientX, y: e.clientY, t: performance.now(), dy: 0, up: null };
        el.current!.style.transition = "none";
      }}
      onPointerMove={(e) => {
        const d = drag.current;
        if (!d) return;
        const dx = e.clientX - d.x;
        const dy = e.clientY - d.y;
        if (d.up == null && Math.hypot(dx, dy) > SLOP) {
          // Up: the card's (removing it); sideways: the row scrolls (the browser has it, touch-action pan-x).
          d.up = dy < 0 && Math.abs(dy) > Math.abs(dx);
          if (d.up) el.current!.setPointerCapture(e.pointerId);
        }
        if (!d.up) return;
        d.dy = Math.min(0, dy);
        el.current!.style.transform = `translateY(${d.dy}px)`;
        el.current!.style.opacity = String(1 - Math.min(1, -d.dy / el.current!.clientHeight));
      }}
      onPointerUp={(e) => {
        const d = drag.current;
        drag.current = null;
        if (!d) return;
        if (d.up) {
          const h = el.current!.clientHeight;
          const v = d.dy / Math.max(1, performance.now() - d.t);
          if (-d.dy > h * REMOVE || v < -FLICK) {
            settle(-h);
            el.current!.addEventListener("transitionend", () => onRemove(t.id), { once: true });
          } else settle(0);
        } else if (d.up == null && Math.hypot(e.clientX - d.x, e.clientY - d.y) <= SLOP) {
          const r = shot.current!.getBoundingClientRect();
          onOpen(t.id, { left: r.left, top: r.top, width: r.width, height: r.height });
        }
      }}
      onPointerCancel={() => {
        drag.current = null;
        settle(0);
      }}
    >
      <div class="task-head">
        {t.icon ? <img class="task-icon" src={t.icon} alt="" /> : <span class="task-icon blank" />}
        <span class="task-label">{t.label}</span>
      </div>
      <img
        ref={shot}
        class="task-shot"
        src={t.snapshot}
        alt=""
        draggable={false}
        // The first card's at once (a window lands on it); the rest as they scroll into view.
        loading={current ? "eager" : "lazy"}
        onLoad={(e) => ((e.currentTarget as HTMLImageElement).style.visibility = "")}
        onError={(e) => ((e.currentTarget as HTMLImageElement).style.visibility = "hidden")}
      />
    </div>
  );
}
