/**
 * The page's own port to the app (ShellNative.kt): a MessagePort the app gives only to this page's top frame at its
 * origin, so an iframe on the page can't use it (the PowosHost bridge, a JavaScript interface, reaches every frame).
 * Asked for once at load with PowosNative.connect(); an APK without it leaves `native` null and callers fall back.
 *
 * What goes through it: opening links (openLink), and surface tiles (useSurface) - a native surface under the page
 * at an island's place, drawn by the app from display lists, so a moving picture on home costs no WebView composite
 * per frame.
 */
import { useEffect, useRef, useState } from "preact/hooks";
import { signal } from "@preact/signals";
import { page } from "../state.ts";
import { powos } from "../bridge.ts";

declare global {
  interface Window {
    PowosNative?: { connect(): void };
  }
}

/** The port, once the app has handed it over (null: an APK without ShellNative, or not yet). */
export const native = signal<MessagePort | null>(null);

addEventListener("message", (e: MessageEvent) => {
  if (e.data !== "powos-native" || !e.ports?.[0]) return;
  native.value?.close();
  const p = e.ports[0];
  // A page that reloaded leaves the last one's tiles behind: they go first.
  p.postMessage("s.reset");
  native.value = p;
});
try {
  window.PowosNative?.connect();
} catch {}

export const send = (command: string) => native.value?.postMessage(command);

/** Opens a link in the app that handles it (http(s), mailto, tel, geo, market). False when there's no port. */
export function openLink(url: string): boolean {
  if (!native.value) return false;
  send(`open ${url}`);
  return true;
}

// ---- surface tiles ----------------------------------------------------------------------------------------------------

/**
 * Home is still: no finger on it, no switcher, no page turn for SETTLE_MS. A surface tile follows its element only
 * while home is still (the page moves it with transforms the app doesn't see); otherwise the island draws in the page.
 */
const SETTLE_MS = 450;
const still = signal(true);
let fingers = 0;
let settle = 0;
function stir() {
  still.value = false;
  clearTimeout(settle);
  settle = window.setTimeout(() => (still.value = fingers === 0), SETTLE_MS);
}
addEventListener("pointerdown", () => (fingers++, stir()), { capture: true });
addEventListener("pointerup", () => ((fingers = Math.max(0, fingers - 1)), stir()), { capture: true });
addEventListener("pointercancel", () => ((fingers = Math.max(0, fingers - 1)), stir()), { capture: true });
for (const ev of ["recents.begin", "recents.drag", "recents.show", "recents.hide", "recents.end"]) powos.on(ev, stir);
page.subscribe(stir);

let nextId = 1;

export interface Surface {
  /** The surface is up and placed: the island may move its frames to it (show(true), then draw()). */
  want: boolean;
  /** A frame: "<w> <h> <ops...>" (ShellNative.kt Tile.draw). */
  draw(frame: string): void;
  /**
   * Shown or not. The island decides when, so a handover is seamless: it shows the surface before its first native
   * frame, and hides it only once its own canvas has the current frame again (home starting to move).
   */
  show(on: boolean): void;
}

/**
 * A native surface at [ref]'s place while [wanted] (the island on screen) and home is still: created, placed (again
 * whenever the element's box changes - checked once a second while it's up, and on every resize), and destroyed with
 * the island. Showing it is the island's call (Surface.show); it keeps its last frame while shown.
 */
export function useSurface(ref: { current: Element | null }, wanted: boolean): Surface {
  const id = useRef(0);
  const [up, setUp] = useState(false);
  const port = native.value;
  const active = !!port && wanted && still.value;
  useEffect(() => {
    if (!active) return;
    const el = ref.current;
    if (!el) return;
    if (!id.current) {
      id.current = nextId++;
      send(`s.create ${id.current}`);
    }
    const n = id.current;
    let last = "";
    const place = () => {
      const r = el.getBoundingClientRect();
      const k = `${r.left.toFixed(1)} ${r.top.toFixed(1)} ${r.width.toFixed(1)} ${r.height.toFixed(1)} ${devicePixelRatio}`;
      if (k !== last) send(`s.place ${n} ${k}`);
      last = k;
    };
    place();
    setUp(true);
    const ro = new ResizeObserver(place);
    ro.observe(el);
    const t = window.setInterval(place, 1000);
    return () => {
      ro.disconnect();
      clearInterval(t);
      setUp(false);
    };
  }, [active, port]);
  useEffect(() => () => void (id.current && send(`s.destroy ${id.current}`)), []);
  return {
    want: up && active,
    draw: (frame) => void (id.current && send(`s.draw ${id.current} ${frame}`)),
    show: (on) => void (id.current && send(`s.show ${id.current} ${on ? 1 : 0}`)),
  };
}
