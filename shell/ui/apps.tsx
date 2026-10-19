/**
 * An app: its icon and label; a tap opens it, a long press shows its menu (AppMenu, one for the whole shell, drawn
 * over everything so no scrolling list clips it). In the drawer, holding an app and moving it drags it onto home.
 */
import { useRef } from "preact/hooks";
import { closeDrawer, dock, launch, menu, setDocked } from "../state.ts";
import { startCarry } from "./grid.tsx";
import { powos } from "../bridge.ts";
import type { App } from "../types.ts";

const LONG_PRESS_MS = 420;
const SLOP = 10;

/**
 * Press-and-hold without a move opens the menu; a tap launches. Held and then moved ([onDrag]): the menu gives way to
 * dragging the app. A move before the hold is a scroll or a swipe, not the app's.
 */
function usePress(onTap: () => void, onLong: (el: HTMLElement) => void, onDrag: ((e: PointerEvent) => void) | null) {
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
}

export function AppCell({ app, labels = true, draggable = false }: CellProps) {
  const press = usePress(
    () => launch(app.key),
    (el) => (menu.value = { app, at: el.getBoundingClientRect() }),
    draggable
      ? (e) => {
          menu.value = null;
          closeDrawer();
          startCarry({ app: app.key }, e, { x: 30, y: 30 });
        }
      : null,
  );
  return (
    <div class="app" {...press}>
      <img class="app-icon" src={app.icon} alt="" draggable={false} />
      {labels && <div class="app-label">{app.label}</div>}
    </div>
  );
}

/** The open app menu, under (or, near the bottom, over) the app it belongs to. */
export function AppMenu() {
  const m = menu.value;
  if (!m) return null;
  const { app, at } = m;
  const docked = dock.value.includes(app.key);
  const items: [string, () => void][] = [
    [docked ? "unpin from dock" : "pin to dock", () => setDocked(app.key, !docked)],
    ...(app.kind === "android" ? ([["app info", () => powos.apps.info(app.key)]] as [string, () => void][]) : []),
    ...(app.kind === "android" && !app.system ? ([["uninstall", () => powos.apps.uninstall(app.key)]] as [string, () => void][]) : []),
  ];
  const below = at.bottom + 48 * items.length + 16 < innerHeight;
  const left = Math.max(8, Math.min(innerWidth - 188, at.left + at.width / 2 - 90));
  const close = () => (menu.value = null);
  return (
    <>
      <div class="menu-scrim" onPointerDown={close} />
      <div class="menu tile" style={{ left: `${left}px`, ...(below ? { top: `${at.bottom + 4}px` } : { bottom: `${innerHeight - at.top + 4}px` }) }}>
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
