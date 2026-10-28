/**
 * The shade (index.html?mode=shade): PowOS's notification panel (notifications.tsx, the same as home's) in the system
 * window the native shade host puts over everything - the stock shade's place. The host follows the finger on the top
 * edge ("shade.drag", "shade.settle"); on the panel, swipes are the page's own (gesture.ts: up drags it shut, cards
 * slide away). Once it's shut the host hides the window (shade.closed).
 *
 * Heads-up banners show here too, as SystemUI shows none while PowOS's shade has its own off: "shade.peek" brings a
 * notification that would have had one (the host decides as SystemUI does) with the window a strip at the top. A tap
 * opens it, its buttons are its actions (a reply opens the whole shade with the field), up puts the banner away, down
 * pulls the whole shade. It goes by itself after a few seconds - an alarm's or a call's later - not while touched.
 */
import { effect, signal } from "@preact/signals";
import { useEffect, useLayoutEffect, useRef } from "preact/hooks";
import { powos } from "../bridge.ts";
import { notif, panel, separatePanels } from "../state.ts";
import type { PhoneNotification } from "../types.ts";
import { homeGestures, notifDrag, notifOpen, notifShown } from "./gesture.ts";
import { Actions, NotificationPanel, wideShade } from "./notifications.tsx";

// Which panel the pull brings: the status bar's right half the control center, the rest the notifications - when
// they're apart (settings); together, it's the one panel wherever the pull starts. Unfolded both show side by side;
// the half it came from cascades first.
powos.on(
  "shade.panel",
  ({ panel: p }: { panel: "notifications" | "control" }) =>
    (panel.value = separatePanels.value === "on" || wideShade.value ? p : "notifications"),
);
powos.on(
  "shade.drag",
  ({ q }: { q: number }) => (notifDrag.value = Math.max(0, Math.min(1, q))),
);
powos.on("shade.settle", ({ open }: { open: boolean }) => {
  notifDrag.value = null;
  notif.value = open;
});

/**
 * One strong frost under the panel: what's behind it (home's widgets, the search pill, the dock) can't be read. The
 * compositor's radius at full openness, dp - its blur is only ~0.15-0.3 of it (the native-blur expert's measure).
 */
const BLUR_DP = parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--shade-blur-native")) || 160;

/**
 * The blur behind follows the panel as it's drawn: each frame the panel's openness moves (the host's pull, the page's
 * own swipe shut, a tap beside it, the 280 ms settle either way), the --q this frame renders goes to the host, which
 * puts the blur on the window's draw that carries this frame. The host used to set the blur itself, at touch time -
 * a frame or two ahead of the page's panel (2026-10-28: "the blur isn't in the same frame as the content") - and a
 * swipe shut on the page never reached it at all: the blur stayed until the window went, then snapped off.
 */
let sentQ = -1;
let following = false;
/**
 * A host without "shade.behind" (an APK older than 245a67af rejects the call): the blur is scaled by its radius instead
 * (shade.blur(dp * q), which that host applies to the window as it is), so a swipe shut on the page still eases the
 * blur away instead of leaving it until the window goes. The full radius is put back when the window is shut.
 */
let legacyHost = false;
/** The last radius sent: an unchanged one is not sent again (each send re-registers the blur and can stutter it). */
let sentRadius = -1;
function sendRadius(dp: number) {
  const d = Math.round(dp * 2) / 2;
  if (d === sentRadius) return;
  sentRadius = d;
  void powos.shade.blur?.(d).catch(() => {});
}
function sendBehind(q: number) {
  if (legacyHost) return void sendRadius(BLUR_DP * q);
  const p = powos.shade.behind?.(q);
  if (!p) return void (legacyHost = true);
  p.catch(() => {
    legacyHost = true;
    sendRadius(BLUR_DP * q);
  });
}
// Page-driven from before the first frame: pageDriven (behind) goes first, at 0, then the radius once - the host
// never runs its own blur ramp against the page's (the blur used to start, stop and start again on open).
if (document.documentElement.dataset.mode === "shade") {
  sentQ = 0;
  sendBehind(0);
  if (!legacyHost) void powos.shade.blur?.(BLUR_DP).catch(() => {});
}
/** The window is going: the old host's radius back to full for the next pull (no-op on a host with behind). */
function restoreRadius() {
  if (legacyHost) sendRadius(BLUR_DP);
}
const panelQ = () => {
  const el = document.querySelector<HTMLElement>(".shade-screen .notif-panel");
  // The registered --q, animated: at an animation frame it's this frame's value (the drag's, or the transition's).
  const q = el ? parseFloat(getComputedStyle(el).getPropertyValue("--q")) : NaN;
  return Number.isFinite(q) ? Math.max(0, Math.min(1, q)) : notifShown();
};
function followBehind() {
  // The shade's page only (home imports this module too; its mode is set after the imports run).
  if (following || document.documentElement.dataset.mode !== "shade") return;
  following = true;
  let still = 0;
  const tick = () => {
    const q = panelQ();
    if (Math.abs(q - sentQ) > 0.001) {
      sentQ = q;
      still = 0;
      sendBehind(q);
    } else if (++still > 3 && notifDrag.peek() == null) {
      following = false;
      return;
    }
    requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
}
effect(() => {
  notifShown();
  followBehind();
});

/** The heads-up banner showing, or null. */
const peek = signal<PhoneNotification | null>(null);
powos.on("shade.peek", (n: PhoneNotification | null) => (peek.value = n));

/** How long a banner stays (ms): an alarm's or a call's longer. */
const PEEK_MS = 6000;
const PEEK_LONG_MS = 15000;
/** Moved this far (CSS px) it's a swipe, not a tap; up this far puts it away, down this far pulls the shade. */
const SLOP = 10;
const AWAY = 24;
const PULL = 36;

/** The banner gone: the window too, unless the shade is coming down. */
function unpeek() {
  peek.value = null;
  if (notifShown() === 0) (restoreRadius(), powos.shade.closed());
}

/** The whole shade from the banner: the window grows, the panel comes down. */
function expand() {
  peek.value = null;
  powos.shade.expand();
}

function Peek() {
  const n = peek.value;
  const el = useRef<HTMLDivElement>(null);
  const timer = useRef(0);
  const drag = useRef<{ x: number; y: number; dy: number; moved: boolean } | null>(null);
  const long = n?.category === "alarm" || n?.category === "call";
  const arm = () => {
    clearTimeout(timer.current);
    timer.current = window.setTimeout(unpeek, long ? PEEK_LONG_MS : PEEK_MS);
  };
  // Each new banner (or the same one posted again) starts its time over.
  useEffect(() => {
    if (!n) return;
    arm();
    return () => clearTimeout(timer.current);
  }, [n?.key, n?.time, n?.text]);
  // The window as tall as the banner (and a little for its shadow).
  useLayoutEffect(() => {
    if (n && el.current) powos.shade.peekHeight(Math.ceil(el.current.getBoundingClientRect().bottom + 12));
  });
  if (!n) return null;
  const settle = (dy: number) => {
    const card = el.current;
    if (!card) return;
    card.style.transition = "transform 160ms ease, opacity 160ms ease";
    card.style.transform = `translateY(${Math.min(0, dy)}px)`;
    card.style.opacity = dy < 0 ? "0" : "";
  };
  return (
    <div
      ref={el}
      class="peek notif tile"
      // Its swipes are its own, not home's (gesture.ts would take a drag down for the shade's pull).
      onTouchStart={(e) => e.stopPropagation()}
      onPointerDown={(e) => {
        clearTimeout(timer.current);
        drag.current = { x: e.clientX, y: e.clientY, dy: 0, moved: false };
        el.current!.setPointerCapture(e.pointerId);
        el.current!.style.transition = "none";
      }}
      onPointerMove={(e) => {
        const d = drag.current;
        if (!d) return;
        d.dy = e.clientY - d.y;
        if (Math.hypot(e.clientX - d.x, d.dy) > SLOP) d.moved = true;
        if (d.dy > PULL) {
          drag.current = null;
          expand();
          return;
        }
        el.current!.style.transform = `translateY(${Math.min(0, d.dy)}px)`;
      }}
      onPointerUp={() => {
        const d = drag.current;
        drag.current = null;
        if (!d) return;
        if (!d.moved) {
          powos.notifications.open(n.key);
          unpeek();
        } else if (d.dy < -AWAY) {
          settle(-el.current!.offsetHeight);
          window.setTimeout(unpeek, 160);
        } else {
          settle(0);
          arm();
        }
      }}
      onPointerCancel={() => {
        drag.current = null;
        settle(0);
        arm();
      }}
    >
      <div class="notif-head">
        {n.icon ? <img class="notif-icon" src={n.icon} alt="" /> : <span class="notif-icon blank" />}
        <span class="notif-app">{n.app}</span>
      </div>
      {n.title && <div class="notif-title">{n.title}</div>}
      {n.text && <div class="notif-text">{n.text}</div>}
      <Actions n={n} onDone={(reply) => (reply ? expand() : unpeek())} />
    </div>
  );
}

export function Shade() {
  // Shut (and not being pulled, no banner): the window goes away until the next pull.
  const shut = notifShown() === 0;
  useEffect(() => {
    if (!shut) return;
    const t = window.setTimeout(
      () => notifShown() === 0 && !peek.value && (restoreRadius(), powos.shade.closed()),
      300,
    );
    return () => clearTimeout(t);
  }, [shut]);
  // The shade pulled down over a banner: the banner's in the list, it goes.
  const open = notifOpen.value;
  useEffect(() => {
    if (open) peek.value = null;
  }, [open]);
  return (
    <div class="home shade-screen" {...homeGestures()}>
      <NotificationPanel />
      {!open && <Peek />}
    </div>
  );
}
