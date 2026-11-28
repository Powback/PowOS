/**
 * A focus mode's window (ui/focus.ts): which notifications it holds. Apart from focus.ts (its page state, bridge) so
 * node's tests load it alone (shell/test/focus.test.ts).
 */
import { inWindow } from "./time.ts";
import type { PhoneNotification } from "../types.ts";

/** A finished (or running) focus's window: what came in between [since] and [until] from outside [allow] is held. */
export interface FocusWindow {
  id: string;
  label: string;
  since: number;
  /** Still on: none. */
  until?: number;
  allow: string[];
  /**
   * Ended: the keys it held then - the digest keeps exactly those, whatever their time says afterwards (a notification
   * Android re-posts or re-stamps as Do not disturb goes off fell outside [since, until] and the card vanished the
   * moment the focus ended, verify FAIL 11-28). None (an older stored window, or still on): the time window decides.
   */
  held?: string[];
}

/** Never held: alarms, calls, ongoing ones (music, a download). */
const exempt = (n: PhoneNotification) => n.category === "alarm" || n.category === "call" || !n.clearable;

/** Whether [n] is held by window [w]. */
export function heldBy(n: PhoneNotification, w: FocusWindow): boolean {
  if (exempt(n)) return false;
  if (w.held) return w.held.includes(n.key);
  if (!inWindow(n.time, w.since, w.until)) return false;
  return !w.allow.includes(n.pkg ?? n.app);
}

/**
 * [w] ended at [now], its allow list [allow]: the ones of [items] it holds at this moment (as the digest card counted
 * them while on) kept with it by key ([FocusWindow.held]).
 */
export function ended(w: FocusWindow, allow: string[], items: PhoneNotification[], now = Date.now()): FocusWindow {
  const live: FocusWindow = { ...w, allow, until: undefined, held: undefined };
  return { ...live, until: now, held: items.filter((n) => heldBy(n, live)).map((n) => n.key) };
}
