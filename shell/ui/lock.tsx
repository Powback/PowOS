/**
 * The lock screen's face (index.html?mode=lock; PowosLockActivity over Android's lock screen): the time, the date,
 * the battery and what's new, in the theme's colors. Swiping up hands over to Android's unlock - its PIN pad, the
 * fingerprint - which keeps the phone's lock; the face only shows it.
 *
 * The swipe follows the finger as home's drawer and notification panel do (gesture.ts): how far the face is lifted,
 * 0..1, goes straight onto the page as --lock-lift on every move, never through a render (a render per move was the
 * stutter); let go past a third of the way, or flicked up, the unlock is asked that moment and the face slides the rest
 * of the way meanwhile, else it falls back. Asking only once the slide had ended (220 ms) was time the user waited for
 * nothing (2026-10-29 "far too long to transition from lock screen to unlocked").
 *
 * Every step is marked (powos.lock.mark: logcat PowosUnlock, with the phone's uptime, next to the native steps):
 * ready (the page shown and painting), swipe start, swipe commit.
 */
import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";
import { powos } from "../bridge.ts";
import { ago, useMinuteClock } from "./time.ts";
import type { NotificationList } from "../types.ts";
import { NotifGlyph, notifIconSrc, type GroupedNotification } from "./notifications.tsx";
import { arrive, leave } from "./notifmotion.ts";

/** Lifted this far (of the height) when let go, it unlocks. */
const UNLOCK = 0.33;
/** px per ms: a flick, whatever the distance (as home's). */
const FLICK = 0.45;
/** ms without a move before the release: the finger was held still. */
const STILL = 80;
/** What's new, at most. */
const SHOWN = 5;

const two = (n: number) => String(n).padStart(2, "0");

type Note = NotificationList["items"][number];
/** A card on the face: shown, or on its way out (gone from the list, fading as its gap closes: §6). */
type Row = { n: Note; leaving?: boolean };

/**
 * [prev]'s rows brought to [items]: the new list in its order, and every card that left it kept where it was, leaving -
 * it was dropped in one frame (the cards under it jumped up).
 */
export function lockRows(prev: Row[], items: Note[]): Row[] {
  const keys = new Set(items.map((n) => n.key));
  const out: Row[] = items.map((n) => ({ n }));
  prev.forEach((r, i) => keys.has(r.n.key) || out.splice(Math.min(i, out.length), 0, { n: r.n, leaving: true }));
  return out;
}

/**
 * The face's lift, 0..1, on the root (the dimming behind the face fades with it); settling: eased there (shell.css: a
 * transition of --lock-lift itself, so the cards' blur is measured on the frames that move them).
 */
function lift(p: number, settling: boolean) {
  const root = document.documentElement;
  root.classList.toggle("lock-settling", settling);
  root.style.setProperty("--lock-lift", String(p));
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
  /** The face on its way out (unlock asked): no new swipe until it is shown again. */
  const going = useRef(false);
  /** The cards already shown: a new one fades and slides in as every list's arrivals do (notifmotion.ts, §6), never
   * there in one frame - the first list too (the face shown with what's new). */
  const notes = useRef<HTMLDivElement>(null);
  const seen = useRef(new WeakSet<Element>());
  const [rows, setRows] = useState<Row[]>([]);
  useEffect(() => setRows((prev) => lockRows(prev, list.items.slice(0, SHOWN))), [list]);
  /** The cards leaving, by key: each one's cancel (it came back before it was gone). */
  const leaving = useRef(new Map<string, () => void>());
  useLayoutEffect(() => {
    const cards = [...(notes.current?.children ?? [])] as HTMLElement[];
    arrive(cards.filter((c) => !seen.current.has(c)));
    for (const c of cards) seen.current.add(c);
    const going = new Set(rows.filter((r) => r.leaving).map((r) => r.n.key));
    for (const [key, cancel] of leaving.current) if (!going.has(key)) (cancel(), leaving.current.delete(key));
    for (const c of cards) {
      const key = c.dataset.key!;
      if (!going.has(key) || leaving.current.has(key)) continue;
      leaving.current.set(key, leave(c, () => {
        leaving.current.delete(key);
        setRows((r) => r.filter((x) => !(x.leaving && x.n.key === key)));
      }));
    }
  });
  useEffect(() => {
    const refresh = () => {
      // Shown again (the screen back on, the PIN pad backed out of): the face whole, wherever it was left.
      going.current = false;
      drag.current = null;
      lift(0, false);
      // Painting again (a frame after being shown): from here the swipe is answered.
      requestAnimationFrame(() => void powos.lock.mark("ready"));
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
    if (!open) return void powos.lock.mark(`swipe fell back p=${p.toFixed(2)} v=${v.toFixed(2)}`);
    // Asked the moment the swipe commits; the face's slide out runs alongside (no wait for it to end).
    going.current = true;
    void powos.lock.mark(`swipe commit p=${p.toFixed(2)} v=${v.toFixed(2)}`);
    void powos.lock.unlock();
  };

  return (
    <div
      class="lock"
      onPointerDown={(e) => {
        if (drag.current || going.current) return;
        void powos.lock.mark("swipe start");
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
      <div class="lock-notes" ref={notes}>
        {rows.map(({ n, leaving: out }) => (
          <div key={n.key} data-key={n.key} class={`lock-note tile${out ? " leaving" : ""}`} inert={out || undefined}>
            {/* K2: the shade's own icon (notifications.tsx SmallIcon's NotifGlyph): the notification's small icon in its app's
                color, else the app's icon - System UI, Play services and the like have no drawer icon, and showed none. */}
            <NotifGlyph n={n as GroupedNotification} fallback={notifIconSrc(n)} />
            <span class="lock-note-main">
              <span class="lock-note-title">{n.title || n.app}</span>
              <span class={`lock-note-text muted${n.text.includes("\n") ? " lines" : ""}`}>{n.text}</span>
            </span>
            <span class="muted lock-note-time">{ago(n.time)}</span>
          </div>
        ))}
      </div>
      <div class="lock-hint muted">swipe up to unlock</div>
    </div>
  );
}
