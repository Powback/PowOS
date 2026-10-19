/**
 * The lock screen's face (index.html?mode=lock; PowosLockActivity over Android's lock screen): the time, the date,
 * the battery and what's new, in the theme's colors. Swiping up hands over to Android's unlock - its PIN pad, the
 * fingerprint - which keeps the phone's lock; the face only shows it.
 */
import { useEffect, useRef, useState } from "preact/hooks";
import { powos } from "../bridge.ts";
import { ago } from "./time.ts";
import type { NotificationList } from "../types.ts";

/** Dragged up this far (of the height), or flicked, it unlocks. */
const UNLOCK = 0.25;
const FLICK = 0.5;
/** What's new, at most. */
const SHOWN = 5;

const two = (n: number) => String(n).padStart(2, "0");

export function Lock() {
  const [now, setNow] = useState(new Date());
  const [battery, setBattery] = useState<{ level: number | null; charging: boolean }>({ level: null, charging: false });
  const [list, setList] = useState<NotificationList>({ available: true, items: [] });
  const [dy, setDy] = useState(0);
  const drag = useRef<{ y: number; t: number } | null>(null);
  useEffect(() => {
    const refresh = () => {
      setNow(new Date());
      setDy(0);
      powos.system.battery().then(setBattery);
      powos.notifications.list().then(setList);
    };
    refresh();
    const offShown = powos.on("lock.shown", refresh);
    const offList = powos.on("notifications.changed", setList);
    const timer = window.setInterval(() => setNow(new Date()), 10_000);
    return () => (offShown(), offList(), clearInterval(timer));
  }, []);
  const up = Math.max(0, -dy);
  return (
    <div
      class="lock"
      style={{ transform: `translateY(${-up}px)`, opacity: String(1 - Math.min(1, up / innerHeight) * 1.4) }}
      onPointerDown={(e) => {
        (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
        drag.current = { y: e.clientY, t: performance.now() };
      }}
      onPointerMove={(e) => drag.current && setDy(e.clientY - drag.current.y)}
      onPointerUp={(e) => {
        const d = drag.current;
        drag.current = null;
        if (!d) return;
        const moved = d.y - e.clientY;
        const v = moved / Math.max(1, performance.now() - d.t);
        if (moved > innerHeight * UNLOCK || v > FLICK) powos.lock.unlock();
        setDy(0);
      }}
    >
      <div class="lock-time">
        {two(now.getHours())}:{two(now.getMinutes())}
      </div>
      <div class="lock-date">
        {now.toLocaleDateString(undefined, { weekday: "long", day: "numeric", month: "long" }).toLowerCase()}
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
