/**
 * The page's own port to the app (ShellNative.kt): a MessagePort the app gives only to this page's top frame at its
 * origin, so an iframe on the page can't use it. Asked for once at load with PowosNative.postMessage("connect") (an older
 * APK: PowosNative.connect()); an APK without it leaves `native` null and callers fall back.
 *
 * What goes through it: opening links (openLink), and surface tiles (useSurface) - a native surface under the page
 * at an island's place, drawn by the app from display lists, so a moving picture on home costs no WebView composite
 * per frame.
 */
import { useEffect, useRef, useState } from "preact/hooks";
import { signal } from "@preact/signals";
import { page } from "../state.ts";
import { powos } from "../bridge.ts";

export { fromNative, native, nextFrameId, send } from "./port.ts";
import { native, send } from "./port.ts";

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
export const still = signal(true);
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
 * whenever the element's box can have moved - its own size (ResizeObserver), the window's or the visual viewport's, the
 * insets; a page turn or the switcher makes home not still, which takes the surface down and places it anew when it
 * settles), and destroyed with the island. Showing it is the island's call (Surface.show); it keeps its last frame
 * while shown. No timer: nothing runs while it's up and nothing moves (it was a 1 s poll - a wake-up a second on an
 * idle home), and nothing at all while no surface is active.
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
    // Its place can change with no change of its own size: the window, the visual viewport (the keyboard), the insets.
    const later = () => requestAnimationFrame(place);
    const vv = window.visualViewport;
    addEventListener("resize", later);
    vv?.addEventListener("resize", later);
    vv?.addEventListener("scroll", later);
    const offInsets = powos.on("system.insets", later);
    return () => {
      ro.disconnect();
      removeEventListener("resize", later);
      vv?.removeEventListener("resize", later);
      vv?.removeEventListener("scroll", later);
      offInsets();
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
