/**
 * A task's card in the switcher (recents.tsx, a layer of home): its app's icon and label above its last frame. A tap
 * opens it (the card grows to the screen, then the app is there); flung or pushed up it's removed, carried on at the
 * finger's speed; let go short of that it springs back; sideways the row scrolls (the browser's, with momentum). The
 * icon (or a long press) opens its menu.
 */
import { useRef } from "preact/hooks";
import type { RecentTask } from "../types.ts";
import { spring } from "./spring.ts";

/** Pushed up this far (of its height), or flicked up (px/ms), a card is removed. */
const REMOVE = 0.4;
const FLICK = 0.5;
const SLOP = 10;
/** Held this long without moving: the card's menu (Android's long-press timeout). */
const LONG_PRESS = 450;

export interface Rect {
  left: number;
  top: number;
  width: number;
  height: number;
}

export function TaskCard({
  t,
  current,
  eager,
  pinned,
  picked,
  load = true,
  onOpen,
  onRemove,
  onMenu,
}: {
  t: RecentTask;
  /** The first card: where the window of the app the switcher was opened over lands (recents.tsx). */
  current?: boolean;
  /** Its snapshot loaded at once (the cards in view), not when scrolled to. */
  eager?: boolean;
  /** Kept on "clear all" (a pin on its head). */
  pinned?: boolean;
  /** Picked as split screen's first app (the second is being picked). */
  picked?: boolean;
  /**
   * Its snapshot in the page: off while the switcher is closed - a hidden layer of decoded snapshots took the page's
   * GPU memory from home's own tiles (hosted widgets blanked mid-swipe). They're in the HTTP cache for the next time.
   */
  load?: boolean;
  onOpen: (id: number, shot: HTMLElement) => void;
  /** False: it stays (the card springs back). */
  onRemove: (id: number) => boolean | void;
  onMenu: (id: number, card: HTMLElement) => void;
}) {
  const el = useRef<HTMLDivElement>(null);
  const shot = useRef<HTMLImageElement>(null);
  const drag = useRef<{
    x: number;
    y: number;
    dy: number;
    up: boolean | null;
    samples: { y: number; t: number }[];
    press: number;
  } | null>(null);
  const gone = useRef(false);

  /** Back to its place, as a spring from where the finger left it. */
  const springBack = (dy: number) => {
    const card = el.current!;
    card.style.transform = "";
    card.style.opacity = "";
    card.animate(
      [
        { transform: `translateY(${dy}px)`, opacity: String(1 - Math.min(1, -dy / card.clientHeight)) },
        { transform: "none", opacity: "1" },
      ],
      { duration: spring.ms, easing: spring.easing },
    );
  };

  /** Removed: on up and out at the finger's speed (at least a brisk one), then gone from the list. */
  const flingAway = (dy: number, v: number) => {
    const card = el.current!;
    if (t.kept) {
      onRemove(t.id);
      return springBack(dy);
    }
    gone.current = true;
    const to = -(card.getBoundingClientRect().bottom + 40);
    const speed = Math.max(Math.abs(v), 1.6); // px/ms
    const ms = Math.min(260, Math.max(120, (dy - to) / speed));
    card.style.transform = "";
    card.animate(
      [
        { transform: `translateY(${dy}px)`, opacity: String(1 - Math.min(1, -dy / card.clientHeight)) },
        { transform: `translateY(${to}px)`, opacity: "0" },
      ],
      { duration: ms, easing: "cubic-bezier(0.3, 0.6, 0.6, 1)", fill: "forwards" },
    ).onfinish = () => onRemove(t.id);
  };

  const cancelPress = () => {
    const d = drag.current;
    if (d?.press) clearTimeout(d.press);
    if (d) d.press = 0;
  };

  return (
    <div
      ref={el}
      class={`task ${current ? "current" : ""} ${pinned ? "pinned" : ""} ${picked ? "picked" : ""}`}
      data-task={t.id}
      onPointerDown={(e) => {
        if (gone.current) return;
        const press = window.setTimeout(() => {
          // Held still: its menu, and the touch is the menu's now.
          drag.current = null;
          navigator.vibrate?.(10);
          onMenu(t.id, el.current!);
        }, LONG_PRESS);
        drag.current = { x: e.clientX, y: e.clientY, dy: 0, up: null, samples: [{ y: e.clientY, t: e.timeStamp }], press };
      }}
      onPointerMove={(e) => {
        const d = drag.current;
        if (!d) return;
        const dx = e.clientX - d.x;
        const dy = e.clientY - d.y;
        if (d.up == null && Math.hypot(dx, dy) > SLOP) {
          cancelPress();
          // Up: the card's (removing it); sideways: the row scrolls (the browser has it, touch-action pan-x).
          d.up = dy < 0 && Math.abs(dy) > Math.abs(dx);
          if (d.up) el.current!.setPointerCapture(e.pointerId);
          else drag.current = null;
        }
        if (!d.up) return;
        // Down past its place it barely moves (a rubber band), up it follows the finger.
        d.dy = dy < 0 ? dy : dy * 0.15;
        d.samples.push({ y: e.clientY, t: e.timeStamp });
        while (d.samples.length > 2 && e.timeStamp - d.samples[0].t > 80) d.samples.shift();
        el.current!.style.transform = `translateY(${d.dy}px)`;
        el.current!.style.opacity = String(1 - Math.min(1, Math.max(0, -d.dy) / el.current!.clientHeight));
      }}
      onPointerUp={(e) => {
        const d = drag.current;
        cancelPress();
        drag.current = null;
        if (!d || gone.current) return;
        const mx = e.clientX - d.x;
        const my = e.clientY - d.y;
        // Moved without the moves coming in (a quick swipe whose moves the page got coalesced into the release): what
        // it was is decided now, from where it ended - up a long way is a removal, not a tap.
        if (d.up == null && Math.hypot(mx, my) > SLOP) {
          if (my < 0 && Math.abs(my) > Math.abs(mx)) {
            d.up = true;
            d.dy = my;
            d.samples.push({ y: e.clientY, t: e.timeStamp });
          } else return; // sideways: the row's scroll
        }
        if (d.up) {
          // The click this release makes (on whatever is under it now - the layer beside the cards, which closes the
          // switcher) isn't one: swallowed.
          // (Only the click of this release: one that never came is no longer waited for at the next touch.)
          const swallow = (c: MouseEvent) => c.stopPropagation();
          window.addEventListener("click", swallow, { capture: true, once: true });
          window.addEventListener("pointerdown", () => window.removeEventListener("click", swallow, true), { capture: true, once: true });
          const first = d.samples[0];
          const v = (e.clientY - first.y) / Math.max(1, e.timeStamp - first.t);
          const h = el.current!.clientHeight;
          if (v < -FLICK || (-d.dy > h * REMOVE && v < 0.3)) flingAway(d.dy, v);
          else springBack(d.dy);
        } else if (d.up == null) {
          // A tap: on the icon, its menu; elsewhere, the app.
          if ((e.target as HTMLElement).closest(".task-icon")) onMenu(t.id, el.current!);
          else onOpen(t.id, shot.current!);
        }
      }}
      onPointerCancel={() => {
        const d = drag.current;
        cancelPress();
        drag.current = null;
        if (d?.up) springBack(d.dy);
      }}
      onContextMenu={(e) => e.preventDefault()}
    >
      <div class="task-head">
        {t.icon ? <img class="task-icon" src={t.icon} alt="" draggable={false} /> : <span class="task-icon blank" />}
        <span class="task-label">{t.label}</span>
      </div>
      <img
        ref={shot}
        class="task-shot"
        src={load ? t.snapshot : undefined}
        alt=""
        draggable={false}
        decoding="async"
        loading={eager || current ? "eager" : "lazy"}
        onLoad={(e) => ((e.currentTarget as HTMLImageElement).style.visibility = "")}
        onError={(e) => ((e.currentTarget as HTMLImageElement).style.visibility = "hidden")}
      />
    </div>
  );
}
