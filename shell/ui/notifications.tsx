/**
 * The launcher's own notification panel: a swipe down on home brings it down under the finger (gesture.ts, as the
 * drawer comes up), in the theme's colors. A tap opens a notification; a card slid sideways is dismissed; "clear all"
 * clears what can be. A card's buttons are its notification's actions, a reply typed in place for one that takes it
 * (an agent's mail: Reply, Mark read). "controls" turns it into the control center (control.tsx). Its openness is --q
 * (data-q).
 */
import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";
import { effect, signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import { notif, panel, separatePanels } from "../state.ts";
import { alignOf, wideShade } from "./align.ts";
import { ControlCenter } from "./control.tsx";
import { Icon } from "./icons.tsx";
import { animateLayout, closeGap, foldAway } from "./notifmotion.ts";
import { followNotif, notifOpen, notifShown } from "./gesture.ts";
import { ago } from "./time.ts";
import type { NotificationList, PhoneNotification } from "../types.ts";

const list = signal<NotificationList>({ available: true, items: [] });
/** The list, read by the meter recording's snapshot (perfrec.ts). */
export { list as notifList };

/** Unfolded: two columns (ui/align.ts, where the theme's alignment reads it too). */
export { wideShade };

/**
 * Opening (pulled down from shut, until it's settled open): the cards ride on the sheet's bottom edge (shell.css
 * .notif-panel.riding). Closing - or a pull that started from open - they stay at their open place and go up with the
 * sheet. Decided per pull, so a pull that turns back keeps one rule all the way (no jump).
 */
const riding = signal(false);
let lastShown = 0;
let settleTimer = 0;
effect(() => {
  const q = notifShown();
  clearTimeout(settleTimer);
  if (lastShown === 0 && q > 0) riding.value = true;
  // Let go: --q eases the rest of the way (shell.css [data-q], 280 ms) - the ride ends once it's there.
  if (q >= 1 || q === 0) settleTimer = window.setTimeout(() => (riding.value = false), 320);
  lastShown = q;
});

/** The card whose reply field is open, and which of its actions takes the text (the shade's banner opens one too). */
export const replying = signal<{ key: string; index: number } | null>(null);

/** A card's (or the banner's) buttons: a touch on them is theirs, not the card's tap or slide. */
export function Actions({ n, onDone, onOpen }: { n: PhoneNotification; onDone?: (reply: boolean) => void; onOpen?: () => void }) {
  if (!n.actions?.length && !onOpen) return null;
  return (
    <div class="notif-buttons" onPointerDown={(e) => e.stopPropagation()}>
      {onOpen && (
        <button
          type="button"
          class="notif-open"
          onClick={(e) => {
            e.stopPropagation();
            onOpen();
          }}
        >
          Open
        </button>
      )}
      {(n.actions ?? []).map((a, i) => (
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

/** Opens [n]'s app (its tap action) and shuts the shade: only ever explicit - its icon, or an expanded card's Open. */
function openNotif(n: PhoneNotification) {
  powos.notifications.open(n.key);
  notif.value = false;
}

/**
 * The cards tapped open (the user, 11-01 17:03: "I should be able to tap them to expand them and see them"): a tap on
 * a card's body expands it in place - its whole text, its big picture, an Open button beside its actions - and a tap
 * again folds it; the body never opens the app (Android's expand-then-open). Shut, the shade starts folded next time.
 */
const openCards = signal<Set<string>>(new Set());
effect(() => {
  if (!notif.value && openCards.peek().size) openCards.value = new Set();
});
const toggleCard = (key: string) => {
  const s = new Set(openCards.value);
  if (s.has(key)) s.delete(key);
  else s.add(key);
  // Grown open (or folded) on the spring (notifmotion.ts), never in one frame.
  animateLayout(() => (openCards.value = s));
};

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
// A new list: what arrived slides in at its place, what left closes up (notifmotion.ts).
powos.on("notifications.changed", (l: NotificationList) => animateLayout(() => (list.value = l)));
// A host without notifications yet (the desktop's powos-shell) rejects: an empty list, not an uncaught error.
powos.notifications.list().then((l) => (list.value = l), () => {});

/** Slid this far sideways (of its width), or flicked, a card is dismissed. */
const DISMISS = 0.35;
const FLICK = 0.6;
const SLOP = 10;

/** PowOS's own: the sender is the group's name already ("PowOS · coder") - not again as its title. */
function titleIsName(n: PhoneNotification, name?: string): boolean {
  const t = n.title.trim().toLowerCase();
  return !!name && (name.toLowerCase().endsWith(`· ${t}`) || (name === UPDATES && t === "deploy"));
}

interface CardProps {
  n: PhoneNotification;
  /** Its head's name (a group's, "PowOS · updates") and the count of the others under it. */
  name?: string;
  more?: number;
  class?: string;
  /** One of the singles: its app's small icon beside its name (SmallIcon). */
  small?: boolean;
}

type Drag = { x: number; y: number; t: number; dx: number; sideways: boolean | null };

/** A card's touch: slid sideways (a clearable one) it's dismissed, a tap toggles it expanded. */
function useCardGesture(n: PhoneNotification) {
  const el = useRef<HTMLDivElement>(null);
  const drag = useRef<Drag | null>(null);
  const settle = (dx: number) => {
    const card = el.current!;
    card.style.transition = "transform var(--spring-fast-ms) var(--spring-fast), opacity var(--spring-fast-ms) var(--spring-fast)";
    card.style.transform = `translateX(${dx}px)`;
    card.style.opacity = dx ? "0" : "";
  };
  const release = (d: Drag) => {
    const w = el.current!.clientWidth;
    const v = d.dx / Math.max(1, performance.now() - d.t);
    if (Math.abs(d.dx) <= w * DISMISS && Math.abs(v) <= FLICK) return settle(0);
    settle(Math.sign(d.dx) * w);
    // Slid out, then its gap closes on the spring before it's dismissed (the cards around it move into its place).
    setTimeout(() => closeGap(el.current!, () => powos.notifications.dismiss(n.key)), 180);
  };
  const handlers = {
    onPointerDown: (e: PointerEvent) => {
      drag.current = { x: e.clientX, y: e.clientY, t: performance.now(), dx: 0, sideways: null };
      el.current!.style.transition = "none";
    },
    onPointerMove: (e: PointerEvent) => {
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
    },
    onPointerUp: (e: PointerEvent) => {
      const d = drag.current;
      drag.current = null;
      if (!d) return;
      if (d.sideways) release(d);
      else if (d.sideways == null && Math.hypot(e.clientX - d.x, e.clientY - d.y) <= SLOP) toggleCard(n.key);
    },
    onPointerCancel: () => {
      drag.current = null;
      settle(0);
    },
  };
  return { el, handlers };
}

/**
 * A single's icon (the user, 11-01: "There is no icon for these notifications" - System UI, Google Play services,
 * Android System have no drawer icon): the notification's small icon (the host's URL; a monochrome glyph, so a mask
 * in its app's color), else [fallback] (the app's icon). A tap opens the app, as the icon does on any card.
 */
export function SmallIcon({ n, fallback }: { n: GroupedNotification; fallback: string | null }) {
  const on = {
    onPointerDown: (e: PointerEvent) => e.stopPropagation(),
    onClick: (e: MouseEvent) => (e.stopPropagation(), openNotif(n)),
  };
  return <NotifGlyph n={n} fallback={fallback} role="button" aria-label="open" {...on} />;
}

/** The icon itself, SmallIcon's without its tap: the lock face's cards (lock.tsx), where the face's swipe is the gesture. */
export function NotifGlyph({ n, fallback, ...attrs }: { n: GroupedNotification; fallback: string | null } & preact.JSX.HTMLAttributes<HTMLElement>) {
  if (!n.smallIcon) return fallback ? <img class="notif-icon" src={fallback} alt="" {...(attrs as preact.JSX.HTMLAttributes<HTMLImageElement>)} /> : null;
  const mask = `url("${n.smallIcon}") center / contain no-repeat`;
  const style = { ...(n.color ? { "--tint": n.color } : {}), mask, WebkitMask: mask } as preact.JSX.CSSProperties;
  return <span class="notif-icon notif-small" style={style} {...(attrs as preact.JSX.HTMLAttributes<HTMLSpanElement>)} />;
}

function Card({ n, name, more = 0, class: cls = "", small = false }: CardProps) {
  const { el, handlers } = useCardGesture(n);
  const open = openCards.value.has(n.key);
  const icon = notifIconSrc(n);
  const picture = (n as GroupedNotification).picture;
  return (
    <div ref={el} class={`notif tile ${cls}${open ? " expanded" : ""}`} aria-expanded={open} {...handlers}>
      <div class="notif-head">
        {/* PowOS's own (its app isn't in the drawer, no icon from the host): PowOS's mark; another without one: none. */}
        {/* The icon opens the app (a tap on the body only expands it). */}
        {small ? (
          <SmallIcon n={n} fallback={icon} />
        ) : icon && (
          <img
            class="notif-icon"
            src={icon}
            alt=""
            role="button"
            aria-label="open"
            onPointerDown={(e) => e.stopPropagation()}
            onClick={(e) => {
              e.stopPropagation();
              openNotif(n);
            }}
          />
        )}
        <span class="notif-app">{name ?? n.app}</span>
        {more > 0 && <span class="notif-more">+{more}</span>}
        <span class="notif-time muted">{ago(n.time)}</span>
      </div>
      {/* PowOS's own: the sender is the group's name already ("PowOS · coder") - not again as its title. */}
      {n.title && !titleIsName(n, name) && <div class="notif-title">{n.title}</div>}
      {n.text && <div class={`notif-text${n.text.includes("\n") ? " lines" : ""}`}>{n.text}</div>}
      {open && picture && <img class="notif-picture" src={picture} alt="" />}
      <Actions n={n} onOpen={open ? () => openNotif(n) : undefined} />
      {replying.value?.key === n.key && <Reply n={n} index={replying.value.index} />}
    </div>
  );
}

/**
 * What grouping reads besides the basics (types.ts PhoneNotification has them; spelled out here too, so this file
 * type-checks against an installed APK's older types.ts).
 */
export type GroupedNotification = PhoneNotification & {
  pkg?: string;
  group?: string | null;
  conversation?: boolean;
  /** Its big picture (BigPictureStyle), shown when the card is expanded - a host that sends none: none. */
  picture?: string | null;
  /** Its small icon's URL (the status bar's glyph, a mask), and its app's tint for it (null: none set). */
  smallIcon?: string | null;
  color?: string | null;
};

/** PowOS's deploy notes, one group. */
const UPDATES = "PowOS · updates";
/** PowOS's own notifications (the app's agent mail and deploy notes): grouped by who sent them, not as one app. */
const POWOS = new Set(["com.powos.app", "PowOS AI", "PowOS"]);
/** A notification's icon: the host's app icon, PowOS's mark for its own (no drawer icon), else none. The lock uses it too. */
export function notifIconSrc(n: { icon?: string | null; app: string; pkg?: string }): string | null {
  return n.icon || (POWOS.has(n.pkg ?? "") || POWOS.has(n.app) ? "./icons/powos.svg" : null);
}

interface Group {
  id: string;
  name: string;
  items: PhoneNotification[];
}

/**
 * The list as the panel shows it: conversations each on their own at the top (newest first); then the singles - every
 * app with just one notification, one compact list newest first, no head of their own (the user, 11-01 17:04: "If
 * there's just one notification for something, group those together at the top: the single notifications first");
 * then one group per app with several - Android's group key when it has one (its bundle), PowOS's own per sender
 * (deploy notes: "PowOS · updates") - the groups by their newest.
 */
function grouped(items: GroupedNotification[]): { convos: Group[]; singles: Group[]; groups: Group[] } {
  const own = (n: GroupedNotification) => POWOS.has(n.pkg ?? "") || POWOS.has(n.app);
  const convos = items.filter((n) => n.conversation && !own(n)).sort((a, b) => b.time - a.time);
  const map = new Map<string, Group>();
  for (const n of items) {
    if (n.conversation && !own(n)) continue;
    let id: string;
    let name = n.app;
    if (own(n)) {
      const from = n.title.trim().toLowerCase();
      id = `powos:${from}`;
      name = from === "deploy" ? UPDATES : `PowOS · ${n.title}`;
    } else id = n.group ? `g:${n.pkg ?? n.app}:${n.group}` : `a:${n.pkg ?? n.app}`;
    const g = map.get(id) ?? { id, name, items: [] };
    g.items.push(n);
    map.set(id, g);
  }
  const groups = [...map.values()];
  for (const g of groups) g.items.sort((a, b) => b.time - a.time);
  groups.sort((a, b) => b.items[0].time - a.items[0].time);
  return {
    convos: convos.map((n) => ({ id: `c:${n.key}`, name: n.app, items: [n] })),
    singles: groups.filter((g) => g.items.length === 1),
    groups: groups.filter((g) => g.items.length > 1),
  };
}

/**
 * The cards as the cascade's rows from --i [from]: the conversations each a row, the singles one row (a compact list of
 * full cards, each with its app's icon and name), then each group a row. Bottom-aligned the list flips (shell.css), so
 * the singles sit nearest the thumb, newest lowest.
 */
function rows(items: GroupedNotification[], from: number) {
  const { convos, singles, groups } = grouped(items);
  const row = (key: string, i: number, body: preact.ComponentChildren) => (
    <div key={key} class="cascade" data-q ref={followNotif} style={{ "--i": from + i }}>
      {body}
    </div>
  );
  const one = (g: Group) => <Card key={g.id} n={g.items[0]} name={g.name !== g.items[0].app ? g.name : undefined} small />;
  return [
    ...convos.map((g, i) => row(g.id, i, <Stack g={g} />)),
    ...(singles.length ? [row("singles", convos.length, <div class="notif-singles">{singles.map(one)}</div>)] : []),
    ...groups.map((g, i) => row(g.id, convos.length + (singles.length ? 1 : 0) + i, <Stack g={g} />)),
  ];
}

/**
 * The groups tapped open: at rest every group shows at most three cards (then "+N more"), so every app fits on the
 * screen at once - folded or unfolded, whatever the
 * control center shows (the user, 2026-10-30: "Maybe group to notification sold that I can see all the types at once
 * ... Max 3 in one In one stack"; unfolded, ccExpanded opened every stack and PowOS's ten deploy cards pushed every other app off).
 * A tap on a group's "+N more" opens that one only; a tap on its head folds it again. Shut, the shade starts folded next time.
 */
const expanded = signal<Set<string>>(new Set());
effect(() => {
  if (!notif.value && expanded.peek().size) expanded.value = new Set();
});
/** [id]'s group unfolded on the spring, or folded: its rest ([stack]'s) fades out and shrinks first (notifmotion.ts). */
const toggle = (id: string, stack?: Element | null) => {
  const s = new Set(expanded.value);
  const set = () => animateLayout(() => (expanded.value = s));
  if (!s.has(id)) return s.add(id), set();
  s.delete(id);
  foldAway(stack?.querySelector<HTMLElement>(":scope > .notif-rest"), set);
};

/**
 * One group: a single notification is its card. More than one: its head (the group's name, its count) then up to three
 * of its cards in full, one after another - each readable, with its own actions, dismissal and reply (the user, 11-01
 * 16:39: "no, just show like 3 cards and then an 'x more' hint") - and past three a "+N more" line: a tap unfolds the
 * rest of that group in place (grown on the spring, its cards fading in: notifmotion.ts), its head folds it again. Every
 * group shows at once. Bottom-aligned the order flips (notifications.css): the newest nearest the thumb, "+N more"
 * on the far side.
 */
const SHOWN = 3;
function Stack({ g }: { g: Group }) {
  const [top, ...others] = g.items;
  if (!others.length) return <Card n={top} name={g.name !== top.app ? g.name : undefined} />;
  const more = g.items.length - SHOWN;
  const open = more > 0 && expanded.value.has(g.id);
  return (
    <div class={`notif-stack ${open ? "open" : ""}`} data-depth={Math.min(2, others.length)}>
      <button type="button" class="notif-group-head" aria-expanded={open} onClick={(e) => more > 0 && toggle(g.id, e.currentTarget.parentElement)}>
        {notifIconSrc(top) && <img class="notif-icon" src={notifIconSrc(top)!} alt="" />}
        <span class="notif-app">{g.name}</span>
        <span class="notif-more">{g.items.length}</span>
        {more > 0 && (
          <span class="notif-fold" aria-label={open ? "collapse" : "expand"}>
            ⌃
          </span>
        )}
      </button>
      <div class="notif-shown">
        {g.items.slice(0, SHOWN).map((n) => (
          <Card key={n.key} n={n} name={g.name} class="in-group" />
        ))}
      </div>
      <div class="notif-rest" inert={!open}>
        <div>
          {g.items.slice(SHOWN).map((n) => (
            <Card key={n.key} n={n} name={g.name} class="in-group" />
          ))}
        </div>
      </div>
      {more > 0 && !open && (
        <button type="button" class="notif-show-more muted" onClick={(e) => toggle(g.id, e.currentTarget.parentElement)}>
          +{more} more
        </button>
      )}
    </div>
  );
}

/** The notifications' head in the two columns: how many, and clear all. */
function notifBar(count: number, clearable: boolean) {
  return (
    <div class="notif-bar cascade" data-q ref={followNotif} style={{ "--i": 0 }}>
      <span class="muted">{count ? `${count} notification${count > 1 ? "s" : ""}` : "notifications"}</span>
      {clearable && (
        <span class="notif-actions icons">
          <button type="button" aria-label="clear all" onClick={() => powos.notifications.clearAll()}>
            <Icon name="notificationClearAll" />
          </button>
        </span>
      )}
    </div>
  );
}

/**
 * The sticky collapse's geometry (NotificationPanel), measured once as a scroll starts: the control center's header row
 * (date, edit, settings: .cc > .notif-bar) stays put; what's under it (sliders, media) slides up under it by [up] px,
 * clipped at its bottom, until the toggle row (.cc3-list) sits right under the header; the card's bottom edge comes up
 * by [room] px in all, to the first toggle row's bottom (the compact card: header + one row; a whole grid's further
 * rows and the launchers are clipped under it). Each moved element is given --d (its distance below the header's
 * bottom: shell.css clips it there). Nothing to collapse (no toggle row, or already compact): room 0.
 */
function stickyRoom(card: HTMLElement): { room: number; up: number; moved: HTMLElement[] } {
  const head = card.querySelector<HTMLElement>(":scope > .notif-bar");
  const row = card.querySelector<HTMLElement>(":scope > .cc3-list");
  const moved = [...card.children].filter((el): el is HTMLElement => el !== head && el instanceof HTMLElement);
  if (!head || !row || !moved.length) return { room: 0, up: 0, moved: [] };
  const hb = head.getBoundingClientRect().bottom;
  const up = Math.max(0, Math.round(row.getBoundingClientRect().top - moved[0].getBoundingClientRect().top));
  const rowEnd = (row.querySelector(".cc3-cell") ?? row).getBoundingClientRect().bottom;
  const pad = parseFloat(getComputedStyle(card).paddingBottom) || 0;
  const room = Math.round(card.getBoundingClientRect().bottom - (rowEnd + pad) + up);
  if (room <= 0) return { room: 0, up: 0, moved: [] };
  for (const el of moved) el.style.setProperty("--d", `${Math.round(el.getBoundingClientRect().top - hb)}px`);
  return { room, up, moved };
}

export function NotificationPanel() {
  const shown = notifOpen.value;
  // The notifications and the control center: one panel (the default), or apart (settings -> style); unfolded, side
  // by side.
  const two = wideShade.value;
  const together = two || separatePanels.value !== "on";
  // Shut: no reply left half-typed in it.
  useEffect(() => {
    if (!shown) replying.value = null;
  }, [shown]);
  const { available, items } = list.value;
  const clearable = items.some((n) => n.clearable);
  // The pull's ride (shell.css .notif-items): the room left under the cards and the panel's height, measured when they
  // change size - never per frame (the finger moves --q only).
  const listEl = useRef<HTMLDivElement>(null);
  const itemsEl = useRef<HTMLDivElement>(null);
  const panelEl = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const p = panelEl.current;
    // The notifications: their list and its cards; the control center: the panel's body and its content - the same ride.
    const control = !together && panel.value === "control";
    const l = control ? p?.querySelector<HTMLElement>(".panel-body") : listEl.current;
    const c = control ? p?.querySelector<HTMLElement>(".cc") : itemsEl.current;
    if (!l || !c || !p) return;
    const measure = () => {
      p.style.setProperty("--free", `${Math.max(0, l.clientHeight - c.offsetHeight)}px`);
      p.style.setProperty("--ph", `${p.offsetHeight}px`);
    };
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(l);
    ro.observe(c);
    return () => ro.disconnect();
  }, [panel.value, together, two]);
  // The control center stays at the top and collapses as the notifications scroll (the user, 2026-10-30: "the control
  // center should be sticky at the top and just be able to like collapse"; it used to slide away with them, 7c1166ce -
  // two things moving under one finger). ONE scroller, the list: its scroll drives the card's collapse 1:1 - its bottom
  // edge comes up by exactly what the list scrolled, to the compact card (header + the toggle row, stickyRoom), then
  // stays, sticky, the notifications scrolling on under it. Back at the top it is all there again. Folded, one panel
  // only (unfolded the two are columns side by side). At rest NOTHING is written: the card and the list are laid out by
  // CSS alone (ccexpand.ts's pull and fold run at the list's top only, and own the card's inline styles; this writes
  // vars on the panel body and --d on the card's rows, never their inline transforms). Only while scrollTop > 0,
  // .cc-sticky goes on the body (shell.css): the list's box reaches up under the card by the room (translated, padded
  // and grown by as much: its cards stay where they were, so its scroll moves them 1:1), its top clipped at the card's
  // bottom edge, which comes up by --sc-a = min(scroll, room).
  useLayoutEffect(() => {
    const l = listEl.current;
    const body = l?.closest<HTMLElement>(".panel-body");
    if (!together || two || !l || !body) return;
    let room = 0;
    let fold: ReturnType<typeof stickyRoom> = { room: 0, up: 0, moved: [] };
    const off = () => {
      room = 0;
      body.classList.remove("cc-sticky");
      for (const k of ["--sc-room", "--sc-a", "--sc-up"]) body.style.removeProperty(k);
      for (const el of fold.moved) el.style.removeProperty("--d");
      fold = { room: 0, up: 0, moved: [] };
    };
    const follow = () => {
      const s = l.scrollTop;
      if (s <= 0) return off();
      if (!room) {
        const card = body.querySelector<HTMLElement>(":scope > .cc");
        fold = card ? stickyRoom(card) : fold;
        room = fold.room;
        if (room <= 0) return off();
        body.style.setProperty("--sc-room", `${room}px`);
        body.classList.add("cc-sticky");
      }
      const a = Math.min(s, room);
      body.style.setProperty("--sc-a", `${a}px`);
      body.style.setProperty("--sc-up", `${Math.min(a, fold.up)}px`);
    };
    l.addEventListener("scroll", follow, { passive: true });
    // Shut: the list back at its top, so the control center is all there on the next open.
    if (!shown && l.scrollTop) l.scrollTop = 0;
    follow();
    return () => (l.removeEventListener("scroll", follow), off());
  }, [together, two, shown]);
  // Bottom-aligned (ui/align.ts): the newest card nearest the thumb, so a list taller than its column opens scrolled to
  // its foot (newest in view) and scrolls up for more - folded too (its scroll there compacts the control center's card,
  // the sticky ride above). The cards still lay out after the open (the cascade, a group unfolding, more arriving), so
  // the list stays at its foot while it grows until the user scrolls away from it.
  const bottom = alignOf("shade") === "bottom";
  useLayoutEffect(() => {
    const l = listEl.current;
    const c = itemsEl.current;
    if (!shown || !bottom || !l || !c) return;
    let pinned = true;
    const toEnd = () => pinned && (l.scrollTop = l.scrollHeight);
    const away = () => (pinned = l.scrollHeight - l.clientHeight - l.scrollTop < 2);
    toEnd();
    const ro = new ResizeObserver(toEnd);
    ro.observe(c);
    ro.observe(l);
    l.addEventListener("scroll", away, { passive: true });
    return () => (ro.disconnect(), l.removeEventListener("scroll", away));
  }, [shown, bottom, two, together, items.length]);
  // The cards, newest first, each group a row of the cascade (shell.css .cascade) from --i [from], after the rows above.
  const items$ = (from: number) => (
    <div class="notif-items" ref={itemsEl}>
      {!available ? (
        <button type="button" class="notif tile notif-access" onClick={() => powos.notifications.access()}>
          allow the launcher to show your notifications here →
        </button>
      ) : items.length ? (
        rows(items, from)
      ) : (
        <div class="notif-empty muted cascade" data-q ref={followNotif} style={{ "--i": from }}>
          {together ? "no notifications" : "nothing new"}
        </div>
      )}
    </div>
  );
  return (
    <>
      <div
        class={`notif-scrim ${shown ? "shown" : ""}`}
        data-q
        ref={followNotif}
        onClick={() => (notif.value = false)}
      />
      <div
        class={`notif-panel ${shown ? "shown" : ""} ${riding.value ? "riding" : ""}`}
        data-q
        ref={(n) => {
          panelEl.current = n;
          followNotif(n);
        }}
        aria-hidden={!shown}
      >
        <div class={`panel-body ${together ? "together" : ""} ${two ? "two" : ""}`} data-from={two ? panel.value : undefined}>
          {two ? (
            // Side by side: the notifications left, the controls right, each scrolling on its own. The column the pull
            // came from (the status bar's half: shade.tsx) cascades first.
            <>
              <div class="notif-list notif-col" ref={listEl}>
                {notifBar(items.length, clearable)}
                {items$(1)}
              </div>
              <div class="notif-list cc-col">
                <ControlCenter />
              </div>
            </>
          ) : together ? (
            // One panel: the controls a floating card on top, the notifications under it on a panel of their own that
            // runs down to the screen's bottom (ccexpand.ts moves them as two: .notif-own is what follows the card).
            <>
              <ControlCenter />
              <div class="notif-own">
                <div class="notif-list" ref={listEl}>
                  {available && items.length > 0 && (
                    <div class="notif-bar cascade" data-q ref={followNotif} style={{ "--i": 5 }}>
                      <span class="muted">{`${items.length} notification${items.length > 1 ? "s" : ""}`}</span>
                      {clearable && (
                        <span class="notif-actions icons">
                          <button type="button" aria-label="clear all" onClick={() => powos.notifications.clearAll()}>
                            <Icon name="notificationClearAll" />
                          </button>
                        </span>
                      )}
                    </div>
                  )}
                  {items$(6)}
                </div>
              </div>
            </>
          ) : panel.value === "control" ? (
            <ControlCenter />
          ) : (
            <>
              <div class="notif-bar" data-q ref={followNotif}>
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
              <div class="notif-list" ref={listEl}>
                {items$(1)}
              </div>
            </>
          )}
        </div>
      </div>
    </>
  );
}
