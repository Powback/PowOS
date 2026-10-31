/**
 * An app: its icon and label; a tap opens it, a long press shows its menu (AppMenu, one for the whole shell, drawn
 * over everything so no scrolling list clips it). In the drawer, holding an app and moving it drags it onto home.
 */
import { tinted } from "./icontint.ts";
import { placement, shapeOf, type Shape } from "./iconshape.ts";
import { running } from "./running.ts";
import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";
import { closeDrawer, dock, launch, menu, setDocked, shownHomePage } from "../state.ts";
import { startCarry } from "./grid.tsx";
import { closeApp, windowsOf } from "./desktops.ts";
import { inLaunchers, toggleLauncher } from "./launchers.tsx";
import { powos } from "../bridge.ts";
import { memo } from "./memo.ts";
import type { App, AppWindow } from "../types.ts";

const LONG_PRESS_MS = 420;
const SLOP = 10;

/**
 * Press-and-hold without a move opens the menu; a tap launches. Held and then moved ([onDrag]): the menu gives way to
 * dragging the app. A move before the hold is a scroll or a swipe, not the app's.
 */
export function usePress(onTap: () => void, onLong: (el: HTMLElement) => void, onDrag: ((e: PointerEvent) => void) | null) {
  const s = useRef<{ x: number; y: number; long: boolean; timer: number; el: HTMLElement } | null>(null);
  const cancel = () => {
    if (s.current) clearTimeout(s.current.timer);
    s.current = null;
  };
  return {
    onPointerDown: (e: PointerEvent) => {
      if (e.button) return;
      const el = e.currentTarget as HTMLElement;
      const state = { x: e.clientX, y: e.clientY, long: false, timer: 0, el };
      state.timer = window.setTimeout(() => {
        state.long = true;
        navigator.vibrate?.(10);
        // Its moves stay its own from here: the menu's scrim comes up under the finger, the app can still be dragged.
        try {
          el.setPointerCapture(e.pointerId);
        } catch {
          // the pointer is gone already
        }
        onLong(el);
      }, LONG_PRESS_MS);
      s.current = state;
    },
    onPointerMove: (e: PointerEvent) => {
      const state = s.current;
      if (!state) return;
      if (Math.hypot(e.clientX - state.x, e.clientY - state.y) <= SLOP) return;
      if (!state.long) return cancel();
      if (onDrag) {
        cancel();
        onDrag(e);
      }
    },
    onPointerUp: (e: PointerEvent) => {
      const state = s.current;
      cancel();
      if (state && !state.long && Math.hypot(e.clientX - state.x, e.clientY - state.y) <= SLOP) onTap();
    },
    onPointerCancel: cancel,
  };
}

interface CellProps {
  app: App;
  /** A drawer cell: its name under it, and it can be dragged onto home. */
  labels?: boolean;
  draggable?: boolean;
  /** Held and moved: this instead of dragging it onto home (the dock reorders its own). */
  onDrag?: (e: PointerEvent, el: HTMLElement, app: App) => void;
  class?: string;
  style?: Record<string, string>;
  /** A tap: this instead of launching it (the dock's taskbar taps, ui/desktops.ts dockTap). */
  onTap?: (app: App) => void;
}

/** Holding [key] and moving: the menu gives way, the launcher closes, and the app follows the finger onto home. */
export function dragHome(key: string, e: PointerEvent) {
  menu.value = null;
  closeDrawer();
  startCarry({ app: key }, e, { x: 30, y: 30 });
}

/**
 * Memoised: [onTap] / [onDrag] take the app, so a parent passes one stable handler for all its cells (never a closure per
 * render - a new one each dock render re-rendered every cell, 152x in perf-1793456386286).
 */
export const AppCell = memo(function AppCell({ app, labels = true, draggable = false, onDrag, class: cls = "", style, onTap }: CellProps) {
  const press = usePress(
    onTap ? () => onTap(app) : () => launch(app.key),
    (el) => (menu.value = { app, at: el.getBoundingClientRect() }),
    onDrag ? (e) => onDrag(e, e.currentTarget as HTMLElement, app) : draggable ? (e) => dragHome(app.key, e) : null,
  );
  return (
    <div class={`app ${cls}`} style={style} data-key={app.key} data-run={running.value[app.key]} {...press}>
      <AppIcon src={app.icon} label={app.label} />
      {labels && <div class="app-label">{app.label}</div>}
    </div>
  );
});

/**
 * How long an icon URL that failed may stay unanswered before the app gets its initial instead. The host draws icons
 * in the background and sends the list again (a new URL) when one is in - well within this on the phone.
 */
const ICON_GIVE_UP_MS = 4000;

/**
 * An app's icon. One the page has already (the WebView keeps each icon's file - its URL names its pixels, ShellIcons)
 * shows in the first frame, as it is; only one still on its way is a softly pulsing tile until the picture is in.
 * The host draws icons in the background, so an icon asked for early may not be there yet (a 404); the list comes
 * again when it is (its URL changes), and loads it then. One that fails and stays failed (no new URL within
 * ICON_GIVE_UP_MS) ends as the app's initial, never as a tile loading forever; a new URL tries the picture again.
 */
export function AppIcon({ src, label }: { src: string; label?: string }) {
  const [missing, setMissing] = useState(false);
  // In the theme's colours when that's on and its copy is made (ui/icontint.ts), else as the app draws it.
  const shown = tinted(src) ?? src;
  // In the one shape at the one visual size (ui/iconshape.ts): placed in the squircle face, on the plate if it needs one.
  const shape = shapeOf(src);
  const timer = useRef(0);
  const img = useRef<HTMLImageElement>(null);
  useEffect(() => {
    setMissing(false);
    return () => clearTimeout(timer.current);
  }, [src]);
  // Before the frame is drawn: an image not decoded yet gets the pulsing tile - one that is shows as it is, with no
  // fade-in (a page reload, home recreated, a fold: every icon is in the WebView's cache by then).
  useLayoutEffect(() => {
    const i = img.current;
    if (i && !(i.complete && i.naturalWidth)) i.closest(".app-icon")!.classList.add("loading");
  }, [src]);
  return (
    <span class={missing ? "app-icon initials" : "app-icon"}>
      {missing && (label ?? "?")[0]}
      <span class={faceClass(shape, missing)}>
      <img
        ref={img}
        src={shown}
        alt=""
        draggable={false}
        decoding="sync"
        style={missing ? { display: "none" } : placement(shape)}
        onLoad={(e) => {
          clearTimeout(timer.current);
          setMissing(false);
          e.currentTarget.closest(".app-icon")!.classList.remove("loading");
        }}
        onError={(e) => {
          e.currentTarget.closest(".app-icon")!.classList.add("loading");
          // HACK: a 404 can't tell "not drawn yet" from "this app has no icon", so a failure that lasts is taken as
          // the latter. Real fix: the host sends icon: null for an app whose lookup failed (ShellBridge.apps(), with
          // Runtime.refreshApps recording the failures) - not done here while ShellBridge has another change in flight.
          // On PowOS (rooted) powos-apps-export now draws every app a picture, so this is only the backstop.
          clearTimeout(timer.current);
          timer.current = window.setTimeout(() => setMissing(true), ICON_GIVE_UP_MS);
        }}
      />
      </span>
    </span>
  );
}

/** The face's classes: placed by its measure, on the plate when it needs one (ui/iconshape.ts). */
const faceClass = (shape: Shape | null | undefined, missing: boolean) =>
  `app-icon-face${shape ? " placed" : ""}${shape?.kind === "plate" && !missing ? " plate" : ""}`;

type Item = [string, () => void];

/**
 * A running app's window actions, first in its menu: close (the app ended: closeApp), minimise or restore its top-most
 * window, and with two or more windows each of them, a tap bringing it to the front (the host's restore).
 */
function windowItems(key: string): Item[] {
  const wins = windowsOf(key);
  if (!running.value[key] && !wins.length) return [];
  return [["close", () => void closeApp(key)], ...stateItem(wins[0]), ...(wins.length > 1 ? listItems(wins) : [])];
}

/** Restore for a window out of sight (minimised, on another page), else minimise; none without a window. */
function stateItem(w: AppWindow | undefined): Item[] {
  const f = powos.floating;
  if (!f || !w) return [];
  if (w.minimised || w.away) return [["restore", () => void f.restore(w.id)]];
  return f.minimise ? [["minimise", () => void f.minimise!(w.id)]] : [];
}

/** Each window by its name (numbered when two share one); a tap brings it to the front. */
function listItems(wins: AppWindow[]): Item[] {
  const seen: Record<string, number> = {};
  return wins.map((w) => {
    const n = (seen[w.label] = (seen[w.label] ?? 0) + 1);
    return [n > 1 ? `${w.label} ${n}` : w.label, () => void powos.floating?.restore(w.id)];
  });
}

/** The open app menu, under (or, near the bottom, over) the app it belongs to. */
export function AppMenu() {
  const m = menu.value;
  if (!m) return null;
  const { app, at } = m;
  const docked = dock.value.includes(app.key);
  const quick = inLaunchers(app.key);
  const items: Item[] = [
    ...windowItems(app.key),
    [docked ? "unpin from dock" : "pin to dock", () => setDocked(app.key, !docked)],
    // The control center's quick-launch row, at its end (launchers.tsx: the row's own add/remove).
    [quick ? "remove from quick launch" : "add to quick launch", () => void toggleLauncher(app.key)],
    // On the page home shows (also from the launcher overlay's own page: state.ts shownHomePage), in its first free cell.
    ["add to home", () => shownHomePage().then((p) => powos.home.add(app.key, p))],
    ...(app.kind === "android" ? ([["app info", () => powos.apps.info(app.key)]] as Item[]) : []),
    ...(app.kind === "android" && !app.system ? ([["uninstall", () => powos.apps.uninstall(app.key)]] as Item[]) : []),
  ];
  const below = at.bottom + 48 * items.length + 16 < innerHeight;
  const left = Math.max(8, Math.min(innerWidth - 188, at.left + at.width / 2 - 90));
  const close = () => (menu.value = null);
  return (
    <>
      <div class="menu-scrim" onPointerDown={close} />
      <div class="menu tile sheet pop" style={{ left: `${left}px`, ...(below ? { top: `${at.bottom + 4}px` } : { bottom: `${innerHeight - at.top + 4}px` }) }}>
        <div class="menu-title">{app.label}</div>
        {items.map(([label, run]) => (
          <button
            class="menu-item"
            onClick={() => {
              close();
              run();
            }}
          >
            {label}
          </button>
        ))}
      </div>
    </>
  );
}
