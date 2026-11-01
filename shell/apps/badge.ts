/**
 * host.badge - an app's unread mark on its icon (App API capability, docs/APP-API.md "Icon badge"), as Android draws a
 * notification dot on a launcher icon: the app says how many things wait for the user, the shell draws a small red
 * dot on that app's icon wherever it shows (home tile, dock, drawer, folders, library - ui/apps.tsx AppIcon) while
 * the count is above 0. The app never draws a dot into its icon file; the shell owns it.
 *
 *   host.badge?.(app, unread);   // 0 hides it; call it again whenever the count changes
 *
 * Kept per app in this page's storage, so the dot is right in the first frame after a reload, before the app has run.
 * Keyed by the app's id; launcher keys ("p:<id>", apps/pages.ts PREFIX) are what icons look it up by.
 */
import { signal } from "@preact/signals";
import { PREFIX } from "./pages.ts";

const STORE = "powos.badges";

function load(): Record<string, number> {
  try {
    const v: unknown = JSON.parse(localStorage.getItem(STORE) ?? "{}");
    return v && typeof v === "object" ? (v as Record<string, number>) : {};
  } catch {
    return {};
  }
}

/** Each app's count (by app id), only those above 0. */
export const badges = signal<Record<string, number>>(load());

/** [app]'s count is now [n] (0 or less: no dot). Nothing changes, nothing is written, when it's the same. */
export function setBadge(app: string, n: number) {
  const count = Number.isFinite(n) ? Math.max(0, Math.floor(n)) : 0;
  if ((badges.value[app] ?? 0) === count) return;
  const next = { ...badges.value };
  if (count) next[app] = count;
  else delete next[app];
  badges.value = next;
  try {
    localStorage.setItem(STORE, JSON.stringify(next));
  } catch {
    /* no storage: the dot is still right until the next reload */
  }
}

/** The count behind an icon's launcher [key] - a PowOS app's ("p:<id>"); 0 for anything else. */
export const badgeOf = (key: string | undefined) => (key?.startsWith(PREFIX) ? badges.value[key.slice(PREFIX.length)] ?? 0 : 0);
