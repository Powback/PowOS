/**
 * The pair entity in the recent apps (the dock's recents page, the recents widget): a pair used lately (ui/splitpair.ts
 * [pairs]: Android's split, a tiling of web windows) is ONE entry where its newest app was - its apps' icons as one
 * combined icon (switcher.tsx GroupIcon, the split card's and the dock group's), its apps get no entry of their own. A
 * tap launches them together again ([launchPair]):
 *
 * - still split (Android's split stands, in the background too): the split back, as its switcher card does;
 * - web windows on (unfolded): tiled again on the page on screen (webwindows.tsx tileApps), PowOS's own split;
 * - otherwise Android's split of the two (ShellBridge launchPair: WM Shell's split of their tasks with the recents
 *   role, Android's launch-adjacent without root).
 */
import { powos } from "../bridge.ts";
import { byKey } from "../state.ts";
import type { App, AppPair } from "../types.ts";
import { GroupIcon } from "./switcher.tsx";
import { livePair, notePair, pairs, samePair } from "./splitpair.ts";
import { tileApps, webWindowsOn } from "./webwindows.tsx";

/** A recent entry: an app, or a pair standing in for its apps. */
export type RecentEntry = { app: App; pair?: undefined } | { pair: AppPair; app?: undefined };

/** A pair whose apps are all installed. */
const known = (p: AppPair) => p.keys.every((k) => byKey.value.has(k));

/**
 * The recent apps [keys] (newest first) as entries: each recent pair where its newest app was, its other apps left
 * out; a pair none of whose apps is recent any more is gone with them. [skip]: apps never listed alone (pinned, a
 * window's), [hidePair]: pairs not listed (the dock's live groups: their cell is the dock's already).
 */
export function recentEntries(keys: string[], skip: Set<string>, hidePair: (p: AppPair) => boolean = () => false): RecentEntry[] {
  const list = pairs.value.filter((p) => known(p) && !hidePair(p));
  const out: RecentEntry[] = [];
  const done = new Set<AppPair>();
  for (const k of keys) {
    const p = list.find((q) => q.keys.includes(k));
    if (p) {
      if (!done.has(p)) (done.add(p), out.push({ pair: p }));
      continue;
    }
    const app = skip.has(k) ? undefined : byKey.value.get(k);
    if (app) out.push({ app });
  }
  return out;
}

/** The entry's React key. */
export const entryKey = (e: RecentEntry) => (e.pair ? `pair:${e.pair.keys.join(",")}` : e.app.key);

/** Pair [p]'s apps launched together (see the head comment); false when nothing could. */
export async function launchPair(p: AppPair): Promise<boolean> {
  const live = livePair.value;
  if (live && samePair(live.keys, p.keys)) return powos.tasks.openSplit(live.ids[0], live.ids[1]);
  notePair(p);
  if (await webWindowsOn()) {
    const apps = p.keys.map((k) => ({ key: k, label: byKey.value.get(k)?.label ?? k }));
    if (await tileApps(apps)) return true;
  }
  const [a, b] = p.keys;
  if (p.keys.length === 2 && a.startsWith("a:") && b.startsWith("a:") && powos.tasks.launchPair) return powos.tasks.launchPair(a, b);
  console.info(`[pairs] ${p.keys.join(" | ")}: no split for these here (not two Android apps, web windows off)`);
  return false;
}

/**
 * A recent pair's cell: its apps' icons as one, a tap launches them together. A plain click, not apps.tsx's usePress:
 * importing apps.tsx here joined its import cycle (recentwidget.tsx draws these cells).
 */
export function PairCell({ pair, class: cls = "" }: { pair: AppPair; class?: string }) {
  const icons = pair.keys.slice(0, 4).map((k) => byKey.value.get(k)?.icon ?? null);
  const label = pair.keys.map((k) => byKey.value.get(k)?.label ?? k).join(" | ");
  return (
    <div class={`app group pair ${cls}`} data-key={`pair:${pair.keys.join(",")}`} data-group={pair.keys.join(",")} role="button" aria-label={label} title={label} onClick={() => void launchPair(pair)}>
      <GroupIcon class="app-icon" icons={icons} layout={pair.layout} />
    </div>
  );
}
