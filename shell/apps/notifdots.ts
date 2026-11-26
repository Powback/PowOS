/**
 * Android apps' notification dots: as stock (Pixel / One UI) marks a launcher icon while its app has notifications
 * waiting, the shell draws the same dot PowOS apps get for their unread count (apps/badge.ts, ui/apps.tsx AppIcon) on
 * an Android app's icon - home tile, dock, drawer, folders, library - while the phone's notification list (the shade's
 * feed, "notifications.changed") holds one of that app's that stock would count.
 *
 * Counted as stock's launcher counts them: ongoing, foreground-service and group-summary ones never reach the feed
 * (widgets/runtime/Notifications.kt shown()); silent / minimised ones and those whose channel turned dots off come
 * marked dot: false (Ranking: importance <= LOW, isAmbient, !canShowBadge) and are left out; media players' too.
 *
 * Per-icon signals: a notification change sets only the counts that moved, so only those apps' icons draw again.
 */
import { batch, signal, type Signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import type { NotificationList, PhoneNotification } from "../types.ts";

/** One counter per (package, profile side): "pkg" for the launcher's own profile, "pkg@" for a work / cloned one. */
const counts = new Map<string, Signal<number>>();

function slot(id: string) {
  let s = counts.get(id);
  if (!s) counts.set(id, (s = signal(0)));
  return s;
}

/** Whether stock would put [n] on its app's dot. A host before the dot field (undefined) counts it. */
const dotted = (n: PhoneNotification) => n.dot !== false && !n.media && !!n.pkg && !n.pkg.startsWith("linux:");

/** A new list: each app's count from it, and only the changed counters written. */
export function takeNotifications(l: NotificationList | null | undefined) {
  const next = new Map<string, number>();
  if (l?.available)
    for (const n of l.items ?? []) {
      if (!dotted(n)) continue;
      const id = n.profile ? `${n.pkg}@` : n.pkg!;
      next.set(id, (next.get(id) ?? 0) + 1);
    }
  batch(() => {
    for (const [id, s] of counts) if (!next.has(id) && s.peek()) s.value = 0;
    for (const [id, n] of next) {
      const s = slot(id);
      if (s.peek() !== n) s.value = n;
    }
  });
}

/**
 * The notification count behind an icon's launcher [key] - an Android app's ("a:<pkg>/<activity>[@<profile>]", the
 * mock's "a:<name>"); 0 for anything else. Read inside a component, it re-renders that icon only when this app's count changes.
 * HACK: the key's profile is a user serial and a notification names only "work" / "clone", so any non-own profile
 * matches any non-own profile's notifications. Real fix: the host names the serial on each notification too.
 */
export function notifCountOf(key: string | undefined): number {
  if (!key?.startsWith("a:")) return 0;
  const at = key.indexOf("@");
  const end = key.indexOf("/");
  const pkg = key.slice(2, end >= 0 ? end : at >= 0 ? at : key.length);
  return slot(at >= 0 ? `${pkg}@` : pkg).value;
}

powos.on("notifications.changed", takeNotifications);
// A host without notifications (the desktop's powos-shell) rejects: no dots, not an uncaught error.
powos.notifications.list().then(takeNotifications, () => {});
