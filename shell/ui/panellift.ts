/**
 * Home's panels over the floating windows (the user's rule, 2026-10-24: the drawer, its search and chat, and edit mode
 * are always above the windows, and a window under a panel is blurred as the home behind it is). Those panels draw in
 * home's own window, which Android stacks under every floating window; while one is open the host lifts home's window
 * over the windows (PanelLift.kt, "p.lift 1|0" over the native port), and its frost then blurs them like the
 * wallpaper.
 *
 * Lifted, home's own pages would draw over the windows too - they are behind the windows, so they're hidden while
 * windows show ("over-windows" on .home, shell.css): before the lift on the way up (the lift waits two frames), and only
 * after the host says it dropped the lift ("p.lifted 0") on the way down, so no frame shows home's tiles over a window.
 * Home only (the pull-up panel over apps has a drawer of its own, in its own window). A host without PanelLift never
 * answers "p.hello": nothing is hidden there.
 */
import { computed, effect, signal } from "@preact/signals";
import { fromNative, native, send } from "../apps/native.ts";
import { editing, windows } from "../state.ts";
import { drawerOpen } from "./gesture.ts";
import { overApps } from "./glasspath.ts";

const home = !new URLSearchParams(location.search).get("mode");

/** The host lifts home over the windows (it answered "p.hello"). */
const hostLifts = signal(false);
/** What the host last said it did: home is over the windows now. */
const hostLifted = signal(false);

/** A home panel is open: the drawer (search and chat are its states) or edit mode. */
const wanted = computed(() => home && (drawerOpen.value || editing.value));

const windowsShow = computed(() => windows.value.some((w) => !w.minimised && !w.away && !!w.bounds));

/** Home's pages hidden: lifted (or about to be) over windows that show, outside edit mode (there the pages ARE the panel). */
export const overWindows = computed(() => hostLifts.value && (wanted.value || hostLifted.value) && windowsShow.value && !editing.value);
// Lifted over app windows: the page can't draw the wallpaper under its glass then (apps are behind it) - the compositor
// blurs instead (ui/glasspath.ts).
effect(() => void (overApps.value = overWindows.value));

fromNative.add((text) => {
  if (!text.startsWith("p.lifted ")) return;
  hostLifts.value = true;
  hostLifted.value = text.endsWith("1");
});

if (home) {
  effect(() => {
    if (native.value) send("p.hello");
  });
  let sent: boolean | null = null;
  effect(() => {
    const on = wanted.value;
    if (!native.value || !hostLifts.value) {
      sent = null;
      return;
    }
    if (on === sent) return;
    sent = on;
    // Up: after the frame that hid home's pages has drawn. Down: at once (the pages come back on the host's answer).
    if (on) requestAnimationFrame(() => requestAnimationFrame(() => sent === true && send("p.lift 1")));
    else send("p.lift 0");
  });
}
