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
 *
 * What's new is the shade's own cards and groups (notifications.tsx Card/Stack, locked: no actions, no opening, no
 * dismiss): a tap on a card expands it in place - its whole text, its picture - and a tap again folds it; a group's
 * "+N more" unfolds the rest and its head folds it again (the user, 11-24: "Update installed · 18 changes ... and 14
 * more" couldn't be opened). The face takes the finger only once it moves (SLOP): it used to capture every touch at
 * pointerdown, so no tap ever reached a card. Opening the app is still the unlock's.
 */
import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";
import { powos } from "../bridge.ts";
import { useMinuteClock } from "./time.ts";
import type { Battery, NotificationList } from "../types.ts";
import { chargeLine } from "./charge.ts";
import { foldAll, grouped, Stack, type Group, type GroupedNotification } from "./notifications.tsx";
import { arrive, leave } from "./notifmotion.ts";

/** Lifted this far (of the height) when let go, it unlocks. */
const UNLOCK = 0.33;
/** px per ms: a flick, whatever the distance (as home's). */
const FLICK = 0.45;
/** ms without a move before the release: the finger was held still. */
const STILL = 80;
/** What's new, at most: rows (a group, a single, a conversation). */
const SHOWN = 5;
/** px the finger moves before it's the face's swipe; less, and let go, it was a tap (a card's, a group's). */
const SLOP = 10;

const two = (n: number) => String(n).padStart(2, "0");

/** A row on the face (a group, a single, a conversation: the shade's): shown, or on its way out (gone from the list,
 * fading as its gap closes: §6). */
type Row = { g: Group; leaving?: boolean };

/**
 * [prev]'s rows brought to [items]: the new list in its order, and every row that left it kept where it was, leaving -
 * it was dropped in one frame (the rows under it jumped up).
 */
export function lockRows(prev: Row[], items: Group[]): Row[] {
  const keys = new Set(items.map((g) => g.id));
  const out: Row[] = items.map((g) => ({ g }));
  prev.forEach((r, i) => keys.has(r.g.id) || out.splice(Math.min(i, out.length), 0, { g: r.g, leaving: true }));
  return out;
}

/** The shade's grouping, one row each, in its order: the conversations, the singles, then the groups. */
function lockGroups(items: GroupedNotification[]): Group[] {
  const { convos, singles, groups } = grouped(items);
  return [...convos, ...singles, ...groups].slice(0, SHOWN);
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

/**
 * The finger moved past SLOP: the face's swipe from here on, wherever it goes (captured). Less: still maybe a tap - false.
 */
function claim(d: { x0: number; y0: number; moved: boolean }, e: PointerEvent): boolean {
  if (Math.hypot(e.clientX - d.x0, e.clientY - d.y0) <= SLOP) return false;
  d.moved = true;
  void powos.lock.mark("swipe start");
  try {
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
  } catch {
    // A pointer already up (or a synthetic one): nothing to capture.
  }
  return true;
}

/** A swipe let go: how far it lifted the face (p), its speed up (v) and whether it unlocks. */
function verdict(d: { y0: number; last: [number, number]; v: number }, cancelled: boolean) {
  const p = Math.max(0, (d.y0 - d.last[0]) / innerHeight);
  // Held still before letting go: no flick. A finger at rest sends no moves, so the last one's speed is stale.
  const v = performance.now() - d.last[1] > STILL ? 0 : d.v;
  // A flick decides; otherwise where it was let go. Taken away (a system gesture had the finger): it falls back.
  const open = !cancelled && (v > FLICK ? true : v < -FLICK ? false : p > UNLOCK);
  return { p, v, open };
}

export function Lock() {
  // On the minute's turn, nothing while the face is hidden (it was every 10 s, put away or not).
  const now = useMinuteClock();
  const [battery, setBattery] = useState<Battery>({ level: null, charging: false });
  const [list, setList] = useState<NotificationList>({
    available: true,
    items: [],
  });
  /** The finger on the face: where it went down, its last sample and its velocity up (px/ms). */
  const drag = useRef<{
    id: number;
    x0: number;
    y0: number;
    last: [number, number];
    v: number;
    /** Moved past SLOP: the face's swipe (captured); until then a tap may be a card's. */
    moved: boolean;
  } | null>(null);
  /** The face on its way out (unlock asked): no new swipe until it is shown again. */
  const going = useRef(false);
  /** The cards already shown: a new one fades and slides in as every list's arrivals do (notifmotion.ts, §6), never
   * there in one frame - the first list too (the face shown with what's new). */
  const notes = useRef<HTMLDivElement>(null);
  const seen = useRef(new WeakSet<Element>());
  const [rows, setRows] = useState<Row[]>([]);
  useEffect(() => setRows((prev) => lockRows(prev, lockGroups(list.items as GroupedNotification[]))), [list]);
  /** The cards leaving, by key: each one's cancel (it came back before it was gone). */
  const leaving = useRef(new Map<string, () => void>());
  useLayoutEffect(() => {
    const cards = [...(notes.current?.querySelector(".notif-items")?.children ?? [])] as HTMLElement[];
    arrive(cards.filter((c) => !seen.current.has(c)));
    for (const c of cards) seen.current.add(c);
    const going = new Set(rows.filter((r) => r.leaving).map((r) => r.g.id));
    for (const [key, cancel] of leaving.current) if (!going.has(key)) (cancel(), leaving.current.delete(key));
    for (const c of cards) {
      const key = c.dataset.key!;
      if (!going.has(key) || leaving.current.has(key)) continue;
      leaving.current.set(key, leave(c, () => {
        leaving.current.delete(key);
        setRows((r) => r.filter((x) => !(x.leaving && x.g.id === key)));
      }));
    }
  });
  // lockScroll: expanded past the room it has (a long group unfolded), the list scrolls - and only then: a swipe on the
  // cards is the face's unlock while everything fits (shell.css .lock-notes[data-scrolls]).
  useEffect(() => {
    const box = notes.current;
    const items = box?.firstElementChild;
    if (!box || !items || typeof ResizeObserver !== "function") return;
    const fit = () => box.toggleAttribute("data-scrolls", items.scrollHeight > box.clientHeight + 1);
    const ro = new ResizeObserver(fit);
    ro.observe(box);
    ro.observe(items);
    return () => ro.disconnect();
  }, []);
  useEffect(() => {
    const refresh = () => {
      // Shown again (the screen back on, the PIN pad backed out of): the face whole, wherever it was left.
      going.current = false;
      drag.current = null;
      lift(0, false);
      // Folded again, as a shut shade starts (notifications.tsx).
      foldAll();
      // Painting again (a frame after being shown): from here the swipe is answered.
      requestAnimationFrame(() => void powos.lock.mark("ready"));
      powos.system.battery().then(setBattery);
      powos.notifications.list().then(setList);
    };
    refresh();
    const offShown = powos.on("lock.shown", refresh);
    const offList = powos.on("notifications.changed", setList);
    // Plugged in, unplugged, the level or the time until full changed while the face is up (PowosLockActivity).
    const offBattery = powos.on("battery.changed", setBattery);
    return () => (offShown(), offList(), offBattery());
  }, []);

  const charge = chargeLine(battery);

  const end = (e: PointerEvent, cancelled = false) => {
    const d = drag.current;
    if (!d || d.id !== e.pointerId) return;
    drag.current = null;
    // Never moved: a tap (a card's own, handled there), not a swipe.
    if (!d.moved) return;
    const { p, v, open } = verdict(d, cancelled);
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
        // Not captured yet: a tap on a card or a group's head is theirs (captured here, no tap ever reached them).
        drag.current = {
          id: e.pointerId,
          x0: e.clientX,
          y0: e.clientY,
          last: [e.clientY, performance.now()],
          v: 0,
          moved: false,
        };
        lift(0, false);
      }}
      onPointerMove={(e) => {
        const d = drag.current;
        if (!d || d.id !== e.pointerId) return;
        if (!d.moved && !claim(d, e)) return;
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
      {/* The shade's cards, locked (notifications.tsx Stack/Card): K2's icons are the shade's (the small icon in its app's
          color, else the app's), each card wears THE backdrop (.lock-note, shell.css K3). It scrolls only once it's
          taller than the room it has (lockScroll); else a swipe on it is the face's. */}
      <div class="lock-notes" ref={notes}>
        <div class="notif-items">
          {rows.map(({ g, leaving: out }) => (
            <div key={g.id} data-key={g.id} class={`lock-row${out ? " leaving" : ""}`} inert={out || undefined}>
              <Stack g={g} locked class="lock-note" />
            </div>
          ))}
        </div>
      </div>
      {/* How it charges, as the stock lock screen says it: "Super fast charging · 1 h until full" (charge.ts). */}
      <div class="lock-foot">
        {charge && <div class="lock-charge">{charge}</div>}
        <div class="lock-hint muted">swipe up to unlock</div>
      </div>
    </div>
  );
}
