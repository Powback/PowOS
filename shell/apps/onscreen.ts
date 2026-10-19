/**
 * What an island needs to stop all work when nobody can see it (apps/stdb.ts IslandHost): whether its element is on
 * screen, as the shell knows it - the element in the viewport (not on another home page), the page shown, and nothing
 * of the shell's own over home (the launcher, a widget's full-size screen, a session opened over it).
 *
 * The page's own visibility misses one case: a WebView that isn't drawn can still say it's visible. An island that
 * animates should also tie its work to requestAnimationFrame - each frame, or a heartbeat a second (apps/stickman's
 * widget) - which only comes while the WebView is really drawn: this signal plus that is a full stop.
 *
 * And opening a link from an island (the browser, or the app that handles it).
 */
import { useEffect, useState } from "preact/hooks";
import { drawerOpen } from "../ui/gesture.ts";
import { screen, sessionView } from "../state.ts";
import { powos } from "../bridge.ts";
import { openLink, still } from "./native.ts";
import { computed, signal } from "@preact/signals";

export function useOnScreen(ref: { current: Element | null }): boolean {
  const [inView, setInView] = useState(false);
  const [shown, setShown] = useState(!document.hidden);
  useEffect(() => {
    const io = new IntersectionObserver((e) => setInView(e[e.length - 1].isIntersecting));
    if (ref.current) io.observe(ref.current);
    const vis = () => setShown(!document.hidden);
    document.addEventListener("visibilitychange", vis);
    return () => {
      io.disconnect();
      document.removeEventListener("visibilitychange", vis);
    };
  }, []);
  // Read in render: the signals re-render the island as they change.
  const covered = drawerOpen.value || screen.value.key !== null || sessionView.value !== null;
  return inView && shown && !covered;
}

/**
 * Opens [url] outside the shell (the browser, or the app that handles it): through the page's own port to the app
 * (apps/native.ts, origin-scoped). HACK, for an APK without that port: the licenses screen's "open" action, the old
 * bridge's only way to hand a URL to Android - goes once every phone runs an APK with ShellNative.
 */
export function openUrl(url: string) {
  if (openLink(url)) return Promise.resolve();
  return powos.screens.act("licenses", "open", url);
}

/**
 * The battery for islands that should rest on a low one: its level (0-100, null unknown), whether it's charging, and
 * whether Android's battery saver is on. Both from the bridge as it is: system.battery, and the control center's
 * battery saver tile (qs.state; null when the phone's tile order has none).
 */
export async function power(): Promise<{ level: number | null; charging: boolean; saver: boolean | null }> {
  const [b, q] = await Promise.all([powos.system.battery(), powos.qs.state().catch(() => null)]);
  const tile = q?.tiles.find((t) => t.id === "battery");
  return { level: b.level, charging: b.charging, saver: tile ? tile.on : null };
}

/**
 * An island's own size in CSS px, as laid out - not getBoundingClientRect, which includes home's transforms (a page
 * sliding, home scaling back in after the switcher) and so read a transient size right after a reload. Measured again
 * whenever the page comes back (a reload or a clear-all brings home back mid-animation) and on every layout change.
 */
export function useLayoutSize(ref: { current: HTMLElement | null }): { width: number; height: number } {
  const [size, setSize] = useState({ width: 0, height: 0 });
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const measure = () =>
      setSize((s) => (s.width === el.clientWidth && s.height === el.clientHeight ? s : { width: el.clientWidth, height: el.clientHeight }));
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    const vis = () => !document.hidden && measure();
    document.addEventListener("visibilitychange", vis);
    window.addEventListener("pageshow", measure);
    measure();
    return () => {
      ro.disconnect();
      document.removeEventListener("visibilitychange", vis);
      window.removeEventListener("pageshow", measure);
    };
  }, []);
  return size;
}

/**
 * Home is quiet: nothing else of PowOS's is open or moving, and the page isn't struggling. An island that animates
 * (apps/stickman) runs only while it is - UI input, scrolling and the other surfaces always win over a widget's frames:
 *   - no finger on home, no page turn, no switcher (native.ts still), no launcher, widget screen or session over home;
 *   - the page's window has focus: the shade, the control center and the assistant are windows of their own over home,
 *     and take it (blur) - a touch on home or focus back clears that;
 *   - no long frame on the page's main thread lately (PerformanceObserver "long-animation-frame": >50 ms - home
 *     starved by something, the CPU busy or hot).
 * It turns quiet again only after QUIET_MS of all that.
 */
const QUIET_MS = 2000;
const blurred = signal(false);
const strained = signal(false);
addEventListener("blur", () => (blurred.value = true));
addEventListener("focus", () => (blurred.value = false));
addEventListener("pointerdown", () => (blurred.value = false), { capture: true });
let strainTimer = 0;
try {
  new PerformanceObserver(() => {
    strained.value = true;
    clearTimeout(strainTimer);
    strainTimer = window.setTimeout(() => (strained.value = false), QUIET_MS);
  }).observe({ type: "long-animation-frame", buffered: false });
} catch {}
const busyNow = computed(
  () => !still.value || drawerOpen.value || screen.value.key !== null || sessionView.value !== null || blurred.value || strained.value,
);
/** Quiet, as above (settles QUIET_MS after the last busy moment; goes busy at once). */
export const quiet = signal(true);
let quietTimer = 0;
busyNow.subscribe((busy) => {
  clearTimeout(quietTimer);
  if (busy) quiet.value = false;
  else quietTimer = window.setTimeout(() => (quiet.value = true), QUIET_MS);
});
export const useQuiet = () => quiet.value;
