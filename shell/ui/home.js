/**
 * Home: the pages (widgets and pinned apps - phase 3), the recent apps strip and the bar. A swipe up anywhere opens
 * the drawer; a swipe down on the drawer's top, or a tap outside it, closes it.
 */
import { useRef } from "preact/hooks";
import { html } from "./html.js";
import { AppCell } from "./apps.js";
import { Bar } from "./bar.js";
import { Drawer } from "./drawer.js";
import { byKey, drawer, query, recent } from "../state.js";
import { powos } from "../bridge.js";

const SWIPE = 48;

function RecentStrip() {
  const shown = recent.value.map((k) => byKey.value.get(k)).filter(Boolean);
  return html`
    <div class="strip tile">
      ${shown.map((app) => html`<${AppCell} key=${app.key} app=${app} labels=${false} size="var(--strip-icon)" />`)}
    </div>
  `;
}

/** Vertical swipes on [el]'s background: up opens the drawer, down closes it. */
function useSwipe() {
  const from = useRef(null);
  return {
    onPointerDown: (e) => (from.current = [e.clientX, e.clientY]),
    onPointerUp: (e) => {
      if (!from.current) return;
      const dx = e.clientX - from.current[0];
      const dy = e.clientY - from.current[1];
      from.current = null;
      if (Math.abs(dy) < SWIPE || Math.abs(dx) > Math.abs(dy)) return;
      if (dy < 0) drawer.value = 1;
      else close();
    },
  };
}

function close() {
  drawer.value = 0;
  query.value = "";
  document.activeElement?.blur();
  powos.keyboard.hide();
}

export function Home() {
  const swipe = useSwipe();
  const open = drawer.value > 0;
  return html`
    <div class="home" ...${swipe}>
      ${!open && html`<div class="pages"></div>`}
      ${open && html`<div class="scrim" onClick=${close}></div>`}
      ${open && html`<${Drawer} />`}
      ${!open && html`<${RecentStrip} />`}
      <${Bar} />
    </div>
  `;
}
