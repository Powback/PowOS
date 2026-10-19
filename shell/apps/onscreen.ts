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
 * Opens [url] outside the shell. HACK: through the licenses screen's "open" action, the bridge's only way to hand a URL
 * to Android (ShellScreens.kt: an ACTION_VIEW intent); the real fix is a bridge call of its own (powos.open(url)) in the
 * next APK.
 */
export function openUrl(url: string) {
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
