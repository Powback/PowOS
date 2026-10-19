/**
 * The switcher (index.html?mode=switcher): Android's recents screen, PowOS's when it's the recents provider (the
 * native host is SwitcherActivity, the overview button brings it up). The recent tasks side by side, newest first, each
 * its app and its last frame: a tap switches to it, a swipe up removes it, "clear all" removes them all. A tap beside
 * the cards goes home; Back (and the overview button again, to the task before) goes back.
 */
import { useEffect, useRef } from "preact/hooks";
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import type { RecentTask } from "../types.ts";

const tasks = signal<RecentTask[]>([]);
/** The task the switcher was opened over (null: home). */
const from = signal<number | null>(null);

const refresh = () => powos.tasks.list().then((t) => (tasks.value = t));

/** The host's events, while the switcher is the page (app.tsx loads this module in every mode). */
function listen(row: () => HTMLElement | null) {
  const offs = [
    powos.on("switcher.shown", (e: { from: number | null }) => {
      from.value = e.from;
      refresh();
      // Each time it comes up, the newest card first in view.
      row()?.scrollTo({ left: 0 });
    }),
    // The overview button again: the task before the one it was opened over (or the newest, from home), as Android's.
    powos.on("switcher.toggle", () => {
      const list = tasks.value;
      const next = list[0]?.id === from.value ? list[1] : list[0];
      if (next) open(next.id);
      else powos.switcher.close();
    }),
    // Back: what was under it, the app or home.
    powos.on("system.back", () => powos.switcher.close()),
  ];
  refresh();
  return () => offs.forEach((off) => off());
}

/** Slid up this far (of its height), or flicked (px/ms), a card is removed. */
const REMOVE = 0.3;
const FLICK = 0.6;
const SLOP = 10;

function open(id: number) {
  powos.tasks.open(id).then((ok) => void (ok || refresh()));
}

function remove(id: number) {
  powos.tasks.remove(id).then(refresh);
  tasks.value = tasks.value.filter((t) => t.id !== id);
}

function Card({ t }: { t: RecentTask }) {
  const el = useRef<HTMLDivElement>(null);
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
      class="task"
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
            setTimeout(() => remove(t.id), 180);
          } else settle(0);
        } else if (d.up == null && Math.hypot(e.clientX - d.x, e.clientY - d.y) <= SLOP) {
          open(t.id);
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
      <img class="task-shot" src={t.snapshot} alt="" draggable={false} onError={(e) => ((e.currentTarget as HTMLImageElement).style.visibility = "hidden")} />
    </div>
  );
}

export function Switcher() {
  const row = useRef<HTMLDivElement>(null);
  const list = tasks.value;
  useEffect(() => listen(() => row.current), []);
  return (
    <div
      class="switcher"
      style={{ "--screen-ratio": `${innerWidth} / ${innerHeight}` }}
      onClick={(e) => e.target === e.currentTarget && powos.switcher.home()}
    >
      {list.length ? (
        <>
          <div class="task-row" ref={row} onClick={(e) => e.target === e.currentTarget && powos.switcher.home()}>
            {list.map((t) => (
              <Card key={t.id} t={t} />
            ))}
          </div>
          <button type="button" class="task-clear" onClick={() => list.forEach((t) => remove(t.id))}>
            clear all
          </button>
        </>
      ) : (
        <div class="task-empty muted">no recent apps</div>
      )}
    </div>
  );
}
