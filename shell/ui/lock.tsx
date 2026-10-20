/**
 * The lock screen's face (index.html?mode=lock; PowosLockActivity over Android's lock screen): the time, the date,
 * the battery and what's new, in the theme's colors. Swiping up hands over to Android's unlock - its PIN pad, the
 * fingerprint - which keeps the phone's lock; the face only shows it.
 *
 * The swipe follows the finger as home's drawer and notification panel do (gesture.ts): how far the face is lifted,
 * 0..1, goes straight onto the page as --lift on every move, never through a render (a render per move was the
 * stutter); let go past a third of the way, or flicked up, it slides the rest of the way and only then unlocks, else
 * it falls back.
 */
import { useEffect, useRef, useState } from "preact/hooks";
import { powos } from "../bridge.ts";
import { ago, useMinuteClock } from "./time.ts";
import type { NotificationList } from "../types.ts";

/** Lifted this far (of the height) when let go, it unlocks. */
const UNLOCK = 0.33;
/** px per ms: a flick, whatever the distance (as home's). */
const FLICK = 0.45;
/** ms without a move before the release: the finger was held still. */
const STILL = 80;
/** The face sliding the rest of the way, or back: as long as the drawer's settle. */
const SETTLE = 220;
/** What's new, at most. */
const SHOWN = 5;

const two = (n: number) => String(n).padStart(2, "0");

/** The face's lift, 0..1, on the root (the dimming behind the face fades with it); settling: eased there. */
function lift(p: number, settling: boolean) {
  const root = document.documentElement;
  root.classList.toggle("lock-settling", settling);
  root.style.setProperty("--lift", String(p));
}

export function Lock() {
  // On the minute's turn, nothing while the face is hidden (it was every 10 s, put away or not).
  const now = useMinuteClock();
  const [battery, setBattery] = useState<{
    level: number | null;
    charging: boolean;
  }>({ level: null, charging: false });
  const [list, setList] = useState<NotificationList>({
    available: true,
    items: [],
  });
  /** The finger on the face: where it went down, its last sample and its velocity up (px/ms). */
  const drag = useRef<{
    id: number;
    y0: number;
    last: [number, number];
    v: number;
  } | null>(null);
  /** The face on its way out (unlock asked at the end of the slide). */
  const going = useRef<number | null>(null);
  useEffect(() => {
    const refresh = () => {
      // Shown again (the screen back on, the PIN pad backed out of): the face whole, wherever it was left.
      if (going.current != null) clearTimeout(going.current);
      going.current = null;
      drag.current = null;
      lift(0, false);
      powos.system.battery().then(setBattery);
      powos.notifications.list().then(setList);
    };
    refresh();
    const offShown = powos.on("lock.shown", refresh);
    const offList = powos.on("notifications.changed", setList);
    return () => (offShown(), offList());
  }, []);

  const end = (e: PointerEvent, cancelled = false) => {
    const d = drag.current;
    if (!d || d.id !== e.pointerId) return;
    drag.current = null;
    const p = Math.max(0, (d.y0 - d.last[0]) / innerHeight);
    // Held still before letting go: no flick. A finger at rest sends no moves, so the last one's speed is stale.
    const v = performance.now() - d.last[1] > STILL ? 0 : d.v;
    // A flick decides; otherwise where it was let go. Taken away (a system gesture had the finger): it falls back.
    const open = !cancelled && (v > FLICK ? true : v < -FLICK ? false : p > UNLOCK);
    lift(open ? 1 : 0, true);
    if (!open) return;
    // Unlocked once the face is out of the way: asked at once, Android's own unlock cut the slide short.
    going.current = window.setTimeout(() => {
      going.current = null;
      powos.lock.unlock();
    }, SETTLE);
  };

  return (
    <div
      class="lock"
      onPointerDown={(e) => {
        if (drag.current || going.current != null) return;
        (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
        drag.current = {
          id: e.pointerId,
          y0: e.clientY,
          last: [e.clientY, performance.now()],
          v: 0,
        };
        lift(0, false);
      }}
      onPointerMove={(e) => {
        const d = drag.current;
        if (!d || d.id !== e.pointerId) return;
        const t = performance.now();
        const [ly, lt] = d.last;
        if (t > lt) d.v = (ly - e.clientY) / (t - lt);
        d.last = [e.clientY, t];
        lift(Math.max(0, Math.min(1, (d.y0 - e.clientY) / innerHeight)), false);
      }}
      onPointerUp={end}
      onPointerCancel={(e) => end(e, true)}
    >
      <div class="lock-time">
        {two(now.getHours())}:{two(now.getMinutes())}
      </div>
      <div class="lock-date">
        {now
          .toLocaleDateString(undefined, {
            weekday: "long",
            day: "numeric",
            month: "long",
          })
          .toLowerCase()}
        {battery.level != null && ` · ${battery.charging ? "⚡" : ""}${battery.level}%`}
      </div>
      <div class="lock-notes">
        {list.items.slice(0, SHOWN).map((n) => (
          <div key={n.key} class="lock-note tile">
            {n.icon ? <img src={n.icon} alt="" /> : <span class="blank" />}
            <span class="lock-note-main">
              <span class="lock-note-title">{n.title || n.app}</span>
              <span class="lock-note-text muted">{n.text}</span>
            </span>
            <span class="muted lock-note-time">{ago(n.time)}</span>
          </div>
        ))}
      </div>
      <div class="lock-hint muted">swipe up to unlock</div>
    </div>
  );
}
