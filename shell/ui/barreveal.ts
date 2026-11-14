// TB1: a window's title bar auto-hidden and slid back in, as Android's own caption does (docs/WEB_WINDOWS.md "Title
// bar: native parity"). The owner, 11-14: "the titlebar isnt acting like the native one, with autohide on fullscreen
// apps etc, slide to reveal". AOSP (DesktopModeWindowDecoration.updateRelayoutParams): a desktop task in full immersive
// shows its header only while the status bar shows - a swipe in from the top edge shows both for a moment (transient
// bars), over the app (the header is no inset source then: the app keeps its size), and SystemUI's AutoHideController
// hides them again 2250 ms after the last touch on them, 350 ms after a touch on the app.
// State only (no import of ui/webwindows.tsx: that one imports this).
import { signal } from "@preact/signals";

/** How long a slid-in bar stays after the last touch on it (AutoHideController.AUTO_HIDE_TIMEOUT_MS; the gate shortens it). */
export const BAR_REVEAL = { ms: 2250, afterApp: 350 };

/** A press this near an auto-hidden window's top edge (CSS px; at least the status bar's room), pulled down this far, slides its bar in. */
export const REVEAL_EDGE = 24;
export const REVEAL_PULL = 24;

/** The window whose auto-hidden bar is slid in now (one at a time, as Android's transient bars), or null. */
export const barReveal = signal<number | null>(null);

/** Something besides a press keeps window [id]'s bar in (its tile menu open on it): ui/webwindows.tsx sets it. */
export const revealKept = { now: (_id: number) => false };

let timer: ReturnType<typeof setTimeout> | undefined;
let held = false;

function hideIn(ms: number) {
  if (timer !== undefined) clearTimeout(timer);
  timer = setTimeout(() => {
    timer = undefined;
    const id = barReveal.peek();
    if (id == null || held) return;
    if (revealKept.now(id)) return hideIn(BAR_REVEAL.ms);
    barReveal.value = null;
  }, ms);
}

/** Window [id]'s bar slides in (another one's slid-in bar goes); it hides again [BAR_REVEAL] after. */
export function revealBar(id: number) {
  held = false;
  barReveal.value = id;
  hideIn(BAR_REVEAL.ms);
}

/** A press on window [id]'s slid-in bar: it stays while pressed ([releaseReveal] lets it go again). */
export function holdReveal(id: number) {
  if (barReveal.peek() !== id) return;
  held = true;
  if (timer !== undefined) clearTimeout(timer);
  timer = undefined;
}

/** The press on window [id]'s slid-in bar ended: it hides [BAR_REVEAL] from now. */
export function releaseReveal(id: number) {
  if (barReveal.peek() !== id) return;
  held = false;
  hideIn(BAR_REVEAL.ms);
}

/** A press on window [id]'s app while its bar is slid in: the bar goes soon (AutoHideController's user timeout). */
export function appPressed(id: number) {
  if (barReveal.peek() === id && !held) hideIn(BAR_REVEAL.afterApp);
}

/** Window [id]'s bar no longer auto-hides (or the window went): nothing slid in stays for it. */
export function revealGone(id: number) {
  if (barReveal.peek() !== id) return;
  held = false;
  if (timer !== undefined) clearTimeout(timer);
  timer = undefined;
  barReveal.value = null;
}

/** Edge pulls in progress: pointer id -> its window and the press's y. */
const pulls = new Map<number, { id: number; y: number }>();

/** Press [e] on window [id]'s body (its top at [top], the status bar's room [inset]): a pull may start here. */
export function edgeDown(id: number, e: { pointerId: number; clientY: number }, top: number, inset: number) {
  if (e.clientY - top <= Math.max(REVEAL_EDGE, inset)) pulls.set(e.pointerId, { id, y: e.clientY });
  else appPressed(id);
}

/** The press moved to [y]: pulled down past [REVEAL_PULL], its window's bar slides in (the app still gets the touch). */
export function edgeMove(pointerId: number, y: number) {
  const p = pulls.get(pointerId);
  if (!p || y - p.y <= REVEAL_PULL) return;
  pulls.delete(pointerId);
  revealBar(p.id);
}

export function edgeEnd(pointerId: number) {
  pulls.delete(pointerId);
}
