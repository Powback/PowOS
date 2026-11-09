/**
 * The pair entity's state (the user, 2026-10-31: "a split pair is ONE app entry everywhere (switcher, recents, ...)"):
 * apps split together are one app - one switcher card (recents.tsx, the host's split card), one dock cell
 * (dockgroups.tsx), one recent-apps entry (pairs.tsx) - launched together and closed together.
 *
 * - [livePair]: Android's split as it stands (WM Shell's, ShellBridge "tasks.splitPair"): its tasks and apps.
 * - [pairs]: the pairs used lately, newest first, kept across restarts (store "pairs"): the recent apps show each as
 *   one entry; a tap launches its apps together again. Recorded from Android's split and from PowOS's own (a tiling of
 *   web windows, ui/webwindows.tsx); an app opened alone ends its pair ([forgetPairOf]).
 *
 * No other module's state in here (state.ts, the dock and the recents all read it): no import cycle.
 */
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import type { AppPair, SplitPair } from "../types.ts";

/** At most this many recent pairs. */
const KEEP = 6;
const STORE = "pairs";

export const livePair = signal<SplitPair | null>(null);
export const pairs = signal<AppPair[]>([]);

/** Same apps (as a set: a pair swapped sides is the same pair). */
export const samePair = (a: string[], b: string[]) => a.length === b.length && a.every((k) => b.includes(k));

const save = () => void powos.store.set(STORE, pairs.value).catch(() => {});

/**
 * [p] used now: first among the recent pairs. One that grew or shrank from the newest (a third window tiled in, one
 * untiled) replaces it - the same group being arranged, not a new pair each step.
 */
export function notePair(p: AppPair) {
  if (p.keys.length < 2 || new Set(p.keys).size !== p.keys.length) return;
  const head = pairs.value[0];
  if (head && samePair(head.keys, p.keys) && head.layout === p.layout) return;
  const grows = (a: string[], b: string[]) => a.every((k) => b.includes(k)) || b.every((k) => a.includes(k));
  const rest = pairs.value.filter((q, i) => !samePair(q.keys, p.keys) && !(i === 0 && grows(q.keys, p.keys)));
  pairs.value = [{ keys: [...p.keys], layout: p.layout }, ...rest].slice(0, KEEP);
  save();
}

/** App [key] opened alone: its pairs end (the user left the pair for one of its apps, as Android's split ends). */
export function forgetPairOf(key: string) {
  const live = livePair.value;
  if (live?.keys.includes(key)) return;
  const next = pairs.value.filter((p) => !p.keys.includes(key));
  if (next.length === pairs.value.length) return;
  pairs.value = next;
  save();
}

const valid = (p: unknown): p is AppPair =>
  !!p && Array.isArray((p as AppPair).keys) && (p as AppPair).keys.length >= 2 && (p as AppPair).keys.every((k) => typeof k === "string");

void powos.store.get<AppPair[]>(STORE).then(
  (v) => {
    // A pair noted before the stored list came back stays first.
    if (Array.isArray(v)) pairs.value = [...pairs.value, ...v.filter(valid).filter((p) => !pairs.value.some((q) => samePair(q.keys, p.keys)))].slice(0, KEEP);
  },
  () => undefined,
);

const isSplit = (p: SplitPair | null): p is SplitPair => !!p && Array.isArray(p.ids) && p.ids.length === 2 && Array.isArray(p.keys);
const sig = (p: SplitPair | null) => (p ? `${p.ids.join()} ${p.keys.join()} ${p.layout}` : "");

/** The host's split (host-optional: an older APK has no "tasks.splitPair"); kept while equal. */
const take = (p: SplitPair | null) => {
  const next = isSplit(p) ? p : null;
  if (sig(next) === sig(livePair.value)) return;
  livePair.value = next;
  if (next) notePair({ keys: next.keys, layout: next.layout });
};
if (powos.tasks.splitPair) {
  powos.on("tasks.splitPair", take);
  void powos.tasks.splitPair().then(take, () => undefined);
}
