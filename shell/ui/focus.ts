/**
 * Focus modes (board task focus-modes-and-a-notification-digest, docs/research/stock-parity-gaps.md): Do not disturb,
 * Sleep, Work, Gaming - each one a list of apps allowed through. On, Android's Do not disturb goes on (priority only,
 * through PowOS's notification listener: no root, no policy access) so the rest stay silent, and PowOS's own shade
 * holds them back: they don't show as cards or banners, only counted on one digest card at the top of the list. The
 * allowed apps show as ever, and their banners come through Do not disturb (the host's peek is told the list,
 * notifications.focus). Off, the digest card stays - "while Work was on: 7 from Slack, Mail..." - until "show" lets
 * them into the list or "clear" dismisses them. Alarms, calls and ongoing ones are never held.
 *
 * The control center's focus tile: a tap turns the last mode on or off, a long press opens Settings > focus (the modes,
 * their allowed apps). State lives in the page's storage, so the shade page and home's Settings follow each other
 * ("storage" events, as align.ts).
 */
import { computed, effect, signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import { openScreen } from "../screens.ts";
import type { IconName } from "./icons.tsx";
import { inWindow } from "./time.ts";
import type { PhoneNotification, QuickTile } from "../types.ts";

export interface FocusMode {
  id: string;
  label: string;
  icon: IconName;
  /** Packages whose notifications come through. */
  allow: string[];
}

/** A finished (or running) focus's window: what came in between [since] and [until] from outside [allow] is held. */
export interface FocusWindow {
  id: string;
  label: string;
  since: number;
  /** Still on: none. */
  until?: number;
  allow: string[];
}

export const FOCUS_ID = "powos.focus";

export const DEFAULT_MODES: FocusMode[] = [
  { id: "dnd", label: "Do not disturb", icon: "minusCircleOutline", allow: [] },
  { id: "sleep", label: "Sleep", icon: "moonWaningCrescent", allow: ["com.google.android.deskclock", "com.google.android.dialer", "com.android.dialer"] },
  { id: "work", label: "Work", icon: "monitor", allow: ["com.google.android.gm", "com.google.android.calendar", "com.Slack", "com.microsoft.teams"] },
  { id: "gaming", label: "Gaming", icon: "gamepad", allow: ["com.discord"] },
];

/** A JSON value kept in the page's storage, mirrored from other pages. */
function storedJson<T>(key: string, initial: T) {
  const k = `powos.${key}`;
  const read = (raw: string | null): T => {
    if (!raw) return initial;
    try {
      return JSON.parse(raw) as T;
    } catch {
      return initial;
    }
  };
  let first = initial;
  try {
    first = read(localStorage.getItem(k));
  } catch {}
  const s = signal<T>(first);
  let last = JSON.stringify(first);
  effect(() => {
    const v = JSON.stringify(s.value);
    if (v === last) return;
    last = v;
    try {
      localStorage.setItem(k, v);
    } catch {}
  });
  addEventListener("storage", (e) => {
    if (e.key !== k) return;
    last = e.newValue ?? JSON.stringify(initial);
    s.value = read(e.newValue);
  });
  return s;
}

/** The modes (the user's allow lists), the one on (null: none), the last one used, the held windows not yet shown. */
export const focusModes = storedJson<FocusMode[]>("focus.modes", DEFAULT_MODES);
export const focusOn = storedJson<FocusWindow | null>("focus.on", null);
export const focusLast = storedJson<string>("focus.last", "dnd");
export const focusDigest = storedJson<FocusWindow[]>("focus.digest", []);

export const modeOf = (id: string) => focusModes.value.find((m) => m.id === id) ?? DEFAULT_MODES.find((m) => m.id === id) ?? DEFAULT_MODES[0];

/** An Android app key ("a:<package>/<activity>[@profile]") -> its package; other kinds: null. */
export function pkgOfKey(key: string): string | null {
  if (!key.startsWith("a:")) return null;
  return key.slice(2).split("/")[0] || null;
}

/** Never held: alarms, calls, ongoing ones (music, a download). */
const exempt = (n: PhoneNotification) => n.category === "alarm" || n.category === "call" || !n.clearable;

/** Whether [n] is held by window [w]. */
export function heldBy(n: PhoneNotification, w: FocusWindow): boolean {
  if (exempt(n)) return false;
  if (!inWindow(n.time, w.since, w.until)) return false;
  return !w.allow.includes(n.pkg ?? n.app);
}

/** The windows holding notifications now: the running focus (with its live allow list) and the digest's. */
const windows = computed<FocusWindow[]>(() => {
  const on = focusOn.value;
  const live = on ? [{ ...on, allow: modeOf(on.id).allow }] : [];
  return [...live, ...focusDigest.value];
});

export const isHeld = (n: PhoneNotification) => windows.value.some((w) => heldBy(n, w));

/** [items] split: the ones shown, the ones held. */
export function splitHeld<T extends PhoneNotification>(items: T[]): { shown: T[]; held: T[] } {
  if (!windows.value.length) return { shown: items, held: [] };
  const shown: T[] = [];
  const held: T[] = [];
  for (const n of items) (isHeld(n) ? held : shown).push(n);
  return { shown, held };
}

/** Do not disturb to [on] through the control center's own switch (qs: the tile's real state read first). */
async function dnd(on: boolean) {
  try {
    const s = await powos.qs.state();
    const now = s.tiles?.find((x) => x.id === "dnd")?.on ?? s.dnd;
    if (now != null && now !== on) await powos.qs.toggle("dnd");
  } catch (e) {
    console.warn("[focus] dnd", e);
  }
}

/** [id] on (another one on ends first, its held ones going to the digest). */
export function startFocus(id: string) {
  const was = focusOn.value;
  if (was?.id === id) return;
  if (was) endWindow(was);
  const m = modeOf(id);
  focusLast.value = id;
  focusOn.value = { id, label: m.label, since: Date.now(), allow: m.allow };
  void dnd(true);
}

function endWindow(w: FocusWindow) {
  focusDigest.value = [{ ...w, allow: modeOf(w.id).allow, until: Date.now() }, ...focusDigest.value].slice(0, 8);
}

/** The focus off: Do not disturb off, what it held left on the digest card. */
export function endFocus() {
  const was = focusOn.value;
  if (!was) return;
  endWindow(was);
  focusOn.value = null;
  void dnd(false);
}

export const toggleFocus = () => (focusOn.value ? endFocus() : startFocus(focusLast.value));

/** The digest let go: its notifications into the list. */
export const releaseDigest = () => (focusDigest.value = []);

/** The held ones dismissed (the clearable ones) and the digest let go. */
export function clearHeld(held: PhoneNotification[]) {
  for (const n of held) if (n.clearable) powos.notifications.dismiss(n.key).catch(() => {});
  releaseDigest();
}

/** The control center's tile. */
export function focusTile(): QuickTile {
  const on = focusOn.value;
  return { id: FOCUS_ID, label: on ? on.label.toLowerCase() : "focus", on: !!on, detail: on ? on.label : "off" };
}

/** The digest card's words: who's held, by app, the most first ("Slack 4 · Mail 2 · 1 more"). */
export function digestLine(held: PhoneNotification[]): string {
  const by = new Map<string, number>();
  for (const n of held) by.set(n.app, (by.get(n.app) ?? 0) + 1);
  const sorted = [...by.entries()].sort((a, b) => b[1] - a[1]);
  const head = sorted.slice(0, 3).map(([app, c]) => (c > 1 ? `${app} ${c}` : app));
  const rest = sorted.length - 3;
  return rest > 0 ? `${head.join(" · ")} · ${rest} more` : head.join(" · ");
}

/** The card's title: "Work: 5 held" while on, "While Work was on: 5" after. */
export function digestTitle(count: number): string {
  const on = focusOn.value;
  const what = `${count} notification${count === 1 ? "" : "s"}`;
  if (on) return `${on.label} · ${what} held`;
  const last = focusDigest.value[0];
  return last ? `while ${last.label.toLowerCase()} was on · ${what}` : what;
}

// The host's banner: the running focus's allowed apps come through Do not disturb (an older host has no such call).
effect(() => {
  const on = focusOn.value;
  const allow = on ? modeOf(on.id).allow : [];
  powos.notifications.focus?.(allow).catch(() => {});
});

/**
 * Settings > focus (the modes' allowed apps) opened: here, and on home's page from the shade's (a page of its own, no
 * screens there) through the storage they share.
 */
const EDIT_KEY = "powos.focus.edit";
export function editFocus() {
  try {
    localStorage.setItem(EDIT_KEY, String(Date.now()));
  } catch {}
  openScreen("focus");
}
addEventListener("storage", (e) => {
  if (e.key === EDIT_KEY && e.newValue) openScreen("focus");
});
