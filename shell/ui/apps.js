/** An app: its icon and label; a tap opens it, a long press shows its actions. */
import { useRef, useState } from "preact/hooks";
import { html } from "./html.js";
import { dock, drawer, launch, query, setDocked } from "../state.js";
import { startCarry } from "./grid.js";
import { powos } from "../bridge.js";

const LONG_PRESS_MS = 450;

/**
 * Press-and-hold without a move opens the menu; a tap launches. Held and then moved ([onDrag], the drawer's cells):
 * the menu gives way to dragging the app onto home.
 */
function usePress(onTap, onLong, onDrag) {
  const timer = useRef(0);
  const start = useRef(null);
  const longed = useRef(false);
  return {
    onPointerDown: (e) => {
      // Its moves stay its own once the menu's scrim is under the finger: a held app can still be dragged out.
      e.currentTarget.setPointerCapture?.(e.pointerId);
      start.current = [e.clientX, e.clientY];
      longed.current = false;
      timer.current = setTimeout(() => {
        longed.current = true;
        navigator.vibrate?.(10);
        onLong();
      }, LONG_PRESS_MS);
    },
    onPointerMove: (e) => {
      if (!start.current) return;
      const [x, y] = start.current;
      const far = Math.hypot(e.clientX - x, e.clientY - y) > 10;
      if (far && !longed.current) clearTimeout(timer.current);
      if (far && longed.current && onDrag) {
        start.current = null;
        onDrag(e);
      }
    },
    onPointerUp: () => {
      clearTimeout(timer.current);
      if (start.current && !longed.current) onTap();
      start.current = null;
    },
    onPointerCancel: () => {
      clearTimeout(timer.current);
      start.current = null;
    },
  };
}

function Menu({ app, onClose }) {
  const docked = dock.value.includes(app.key);
  const items = [
    [docked ? "unpin from dock" : "pin to dock", () => setDocked(app.key, !docked)],
    ...(app.kind === "android" ? [["app info", () => powos.apps.info(app.key)]] : []),
    ...(app.kind === "android" && !app.system ? [["uninstall", () => powos.apps.uninstall(app.key)]] : []),
  ];
  // The scrim takes a press anywhere else and closes; the menu hangs under the app it belongs to.
  return html`
    <div class="menu-scrim" onPointerDown=${(e) => { e.stopPropagation(); onClose(); }}></div>
    <div class="menu tile" onPointerDown=${(e) => e.stopPropagation()} onPointerUp=${(e) => e.stopPropagation()}>
      ${items.map(([label, run]) => html`<button class="menu-item" onClick=${() => { onClose(); run(); }}>${label}</button>`)}
    </div>
  `;
}

/** [labels]: a drawer cell has its name under it; the strip and the dock show icons alone. */
export function AppCell({ app, labels = true, size = "var(--icon)", drawerCell = false }) {
  const [menu, setMenu] = useState(false);
  const press = usePress(
    () => launch(app.key),
    () => setMenu(true),
    // From the drawer: the drawer closes under the finger and the app goes where it's dropped on home.
    drawerCell
      ? (e) => {
          setMenu(false);
          drawer.value = 0;
          query.value = "";
          startCarry({ app: app.key }, e, { x: 30, y: 30 });
        }
      : null,
  );
  return html`
    <div class="app" ...${press}>
      <img class="app-icon" src=${app.icon} alt="" draggable="false" style=${{ width: size, height: size }} />
      ${labels && html`<div class="app-label">${app.label}</div>`}
      ${menu && html`<${Menu} app=${app} onClose=${() => setMenu(false)} />`}
    </div>
  `;
}
