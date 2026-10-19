/**
 * The launcher's own notification panel: a swipe down on home brings it down under the finger (gesture.ts, as the
 * drawer comes up), in the theme's colors. A tap opens a notification; a card slid sideways is dismissed; "clear all"
 * clears what can be. The system's shade is still a tap away (its quick settings). Its openness is --q (data-q).
 */
import { useRef } from "preact/hooks";
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import { notif } from "../state.ts";
import { followNotif, notifOpen } from "./gesture.ts";
import type { NotificationList, PhoneNotification } from "../types.ts";

const list = signal<NotificationList>({ available: true, items: [] });
powos.on("notifications.changed", (l: NotificationList) => (list.value = l));
powos.notifications.list().then((l) => (list.value = l));

/** "now", "5m", "3h", "2d": how long ago, as a shade shows it. */
function ago(time: number) {
  const s = Date.now() / 1000 - time;
  if (s < 60) return "now";
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86400) return `${Math.floor(s / 3600)}h`;
  return `${Math.floor(s / 86400)}d`;
}

/** Slid this far sideways (of its width), or flicked, a card is dismissed. */
const DISMISS = 0.35;
const FLICK = 0.6;
const SLOP = 10;

function Card({ n }: { n: PhoneNotification }) {
  const el = useRef<HTMLDivElement>(null);
  const drag = useRef<{ x: number; y: number; t: number; dx: number; sideways: boolean | null } | null>(null);
  const settle = (dx: number) => {
    const card = el.current!;
    card.style.transition = "transform 180ms ease, opacity 180ms ease";
    card.style.transform = `translateX(${dx}px)`;
    card.style.opacity = dx ? "0" : "";
  };
  return (
    <div
      ref={el}
      class="notif tile"
      onPointerDown={(e) => {
        drag.current = { x: e.clientX, y: e.clientY, t: performance.now(), dx: 0, sideways: null };
        el.current!.style.transition = "none";
      }}
      onPointerMove={(e) => {
        const d = drag.current;
        if (!d) return;
        const dx = e.clientX - d.x;
        const dy = e.clientY - d.y;
        if (d.sideways == null && Math.hypot(dx, dy) > SLOP) {
          d.sideways = Math.abs(dx) > Math.abs(dy) && n.clearable;
          if (d.sideways) el.current!.setPointerCapture(e.pointerId);
        }
        if (!d.sideways) return;
        d.dx = dx;
        el.current!.style.transform = `translateX(${dx}px)`;
        el.current!.style.opacity = String(1 - Math.min(1, Math.abs(dx) / el.current!.clientWidth));
      }}
      onPointerUp={(e) => {
        const d = drag.current;
        drag.current = null;
        if (!d) return;
        if (d.sideways) {
          const w = el.current!.clientWidth;
          const v = d.dx / Math.max(1, performance.now() - d.t);
          if (Math.abs(d.dx) > w * DISMISS || Math.abs(v) > FLICK) {
            settle(Math.sign(d.dx) * w);
            setTimeout(() => powos.notifications.dismiss(n.key), 180);
          } else settle(0);
        } else if (d.sideways == null && Math.hypot(e.clientX - d.x, e.clientY - d.y) <= SLOP) {
          powos.notifications.open(n.key);
          notif.value = false;
        }
      }}
      onPointerCancel={() => {
        drag.current = null;
        settle(0);
      }}
    >
      <div class="notif-head">
        {n.icon ? <img class="notif-icon" src={n.icon} alt="" /> : <span class="notif-icon blank" />}
        <span class="notif-app">{n.app}</span>
        <span class="notif-time muted">{ago(n.time)}</span>
      </div>
      {n.title && <div class="notif-title">{n.title}</div>}
      {n.text && <div class="notif-text">{n.text}</div>}
    </div>
  );
}

export function NotificationPanel() {
  const shown = notifOpen.value;
  const { available, items } = list.value;
  const clearable = items.some((n) => n.clearable);
  return (
    <>
      <div class={`notif-scrim ${shown ? "shown" : ""}`} data-q ref={followNotif} onClick={() => (notif.value = false)} />
      <div class={`notif-panel ${shown ? "shown" : ""}`} data-q ref={followNotif} aria-hidden={!shown}>
        <div class="notif-bar">
          <span class="muted">{items.length ? `${items.length} notification${items.length > 1 ? "s" : ""}` : "notifications"}</span>
          <span class="notif-actions">
            {/* The system's shade: its quick settings (wifi, bluetooth...), which a launcher can't show. */}
            <button type="button" onClick={() => powos.system.notifications(true)}>
              quick settings
            </button>
            {clearable && (
              <button type="button" onClick={() => powos.notifications.clearAll()}>
                clear all
              </button>
            )}
          </span>
        </div>
        <div class="notif-list">
          {!available ? (
            <button type="button" class="notif tile notif-access" onClick={() => powos.notifications.access()}>
              allow the launcher to show your notifications here →
            </button>
          ) : items.length ? (
            items.map((n) => <Card key={n.key} n={n} />)
          ) : (
            <div class="notif-empty muted">nothing new</div>
          )}
        </div>
        <div class="notif-grip" />
      </div>
    </>
  );
}
