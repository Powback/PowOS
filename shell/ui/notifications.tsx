/**
 * The launcher's own notification panel: a swipe down on home brings it down under the finger (gesture.ts, as the
 * drawer comes up), in the theme's colors. A tap opens a notification; a card slid sideways is dismissed; "clear all"
 * clears what can be. A card's buttons are its notification's actions, a reply typed in place for one that takes it
 * (an agent's mail: Reply, Mark read). "controls" turns it into the control center (control.tsx). Its openness is --q
 * (data-q).
 */
import { useEffect, useRef, useState } from "preact/hooks";
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import { notif, panel } from "../state.ts";
import { ControlCenter } from "./control.tsx";
import { Icon } from "./icons.tsx";
import { followNotif, notifOpen } from "./gesture.ts";
import { ago } from "./time.ts";
import type { NotificationList, PhoneNotification } from "../types.ts";

const list = signal<NotificationList>({ available: true, items: [] });

/** The card whose reply field is open, and which of its actions takes the text (the shade's banner opens one too). */
export const replying = signal<{ key: string; index: number } | null>(null);

/** A card's (or the banner's) buttons: a touch on them is theirs, not the card's tap or slide. */
export function Actions({ n, onDone }: { n: PhoneNotification; onDone?: (reply: boolean) => void }) {
  if (!n.actions?.length) return null;
  return (
    <div class="notif-buttons" onPointerDown={(e) => e.stopPropagation()}>
      {n.actions.map((a, i) => (
        <button
          type="button"
          key={i}
          onClick={(e) => {
            e.stopPropagation();
            if (a.input) replying.value = { key: n.key, index: i };
            else powos.notifications.action(n.key, i);
            onDone?.(a.input);
          }}
        >
          {a.title}
        </button>
      ))}
    </div>
  );
}

/** The reply typed in place: sent into the notification's action as its inline reply. */
function Reply({ n, index }: { n: PhoneNotification; index: number }) {
  const [text, setText] = useState("");
  const input = useRef<HTMLInputElement>(null);
  useEffect(() => {
    // The shade's window takes focus a moment after it's pulled (or the banner expanded): then the keyboard.
    const t = window.setTimeout(() => {
      input.current?.focus();
      powos.keyboard.show();
    }, 150);
    return () => clearTimeout(t);
  }, []);
  const send = () => {
    const t = text.trim();
    if (!t) return;
    powos.notifications.action(n.key, index, t);
    replying.value = null;
  };
  return (
    <form
      class="notif-reply"
      onPointerDown={(e) => e.stopPropagation()}
      onSubmit={(e) => {
        e.preventDefault();
        send();
      }}
    >
      <input
        ref={input}
        value={text}
        placeholder={n.actions?.[index]?.title ?? "Reply"}
        onInput={(e) => setText((e.target as HTMLInputElement).value)}
        enterKeyHint="send"
      />
      <button type="submit" aria-label="send" disabled={!text.trim()}>
        ↑
      </button>
    </form>
  );
}
powos.on("notifications.changed", (l: NotificationList) => (list.value = l));
powos.notifications.list().then((l) => (list.value = l));

/** Slid this far sideways (of its width), or flicked, a card is dismissed. */
const DISMISS = 0.35;
const FLICK = 0.6;
const SLOP = 10;

function Card({ n }: { n: PhoneNotification }) {
  const el = useRef<HTMLDivElement>(null);
  const drag = useRef<{
    x: number;
    y: number;
    t: number;
    dx: number;
    sideways: boolean | null;
  } | null>(null);
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
        drag.current = {
          x: e.clientX,
          y: e.clientY,
          t: performance.now(),
          dx: 0,
          sideways: null,
        };
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
      <Actions n={n} />
      {replying.value?.key === n.key && <Reply n={n} index={replying.value.index} />}
    </div>
  );
}

export function NotificationPanel() {
  const shown = notifOpen.value;
  // Shut: no reply left half-typed in it.
  useEffect(() => {
    if (!shown) replying.value = null;
  }, [shown]);
  const { available, items } = list.value;
  const clearable = items.some((n) => n.clearable);
  return (
    <>
      <div
        class={`notif-scrim ${shown ? "shown" : ""}`}
        data-q
        ref={followNotif}
        onClick={() => (notif.value = false)}
      />
      <div class={`notif-panel ${shown ? "shown" : ""}`} data-q ref={followNotif} aria-hidden={!shown}>
        <div class="panel-body">
          {panel.value === "control" ? (
            <ControlCenter />
          ) : (
            <>
              <div class="notif-bar">
                <span class="muted">
                  {items.length ? `${items.length} notification${items.length > 1 ? "s" : ""}` : "notifications"}
                </span>
                <span class="notif-actions icons">
                  {clearable && (
                    <button type="button" aria-label="clear all" onClick={() => powos.notifications.clearAll()}>
                      <Icon name="notificationClearAll" />
                    </button>
                  )}
                  <button type="button" aria-label="controls" onClick={() => (panel.value = "control")}>
                    <Icon name="tuneVariant" />
                  </button>
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
            </>
          )}
        </div>
        <div class="notif-grip" />
      </div>
    </>
  );
}
