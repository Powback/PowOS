/**
 * DG1 (the user, 2026-10-31 03:18: "when two apps are like, docked together... I don't really see it on the launcher,
 * the homebar doesn't really show them as docked together"): PowOS's window groups in the dock as one cell each.
 * A group is a tiling (ui/webwindows.tsx tilings, per home page) with 2 or more windows, or a tab stack (stacks) with
 * 2 or more tabs that isn't in such a tiling (a tiled stack's tabs belong to its tiling's group). Its cell shows the
 * group's icons together (switcher.tsx GroupIcon, the split card's combined icon) in the group's layout; its apps get no cells of
 * their own; a tap brings every window of the group to the front on its page (webwindows.tsx bringGroup). Its mark
 * (pagemarks.ts) is the group's page against the page on screen. Android's split (folded: no web windows) is a group too
 * (DockGroup.native, ui/splitpair.ts): its tap brings the split back.
 */
import { computed, effect } from "@preact/signals";
import { powos } from "../bridge.ts";
import { byKey } from "../state.ts";
import { usePress } from "./apps.tsx";
import { pageId } from "./desktops.ts";
import { GroupIcon } from "./switcher.tsx";
import { livePair, notePair } from "./splitpair.ts";
import { bringGroup, stacks, tilings, webWins } from "./webwindows.tsx";

export interface DockGroup {
  /** The app of each window, in [ids] order (tile order; a stack's tab order). */
  keys: string[];
  /** Its windows: a tiling's tiles first, then its stacks' hidden tabs. */
  ids: number[];
  /** The icons shown: one per tile (or tab), at most 4. */
  icons: string[];
  /** The home page (its number) it's on. */
  page: number;
  /** A Tiling's layout, or "stack". */
  layout: string;
  /** Every window minimised. */
  minimised: boolean;
  /** Android's split (ui/splitpair.ts livePair): its two tasks, left / top first; [ids] is empty (no web windows). */
  native?: number[];
}

type Win = (typeof webWins.value)[number];

/** The group of windows [shown] (with [extra], hidden tabs) as [layout]; null when fewer than 2 are known apps. */
function groupOf(shown: number[], extra: number[], layout: string, wins: Map<number, Win>): DockGroup | null {
  const known = (id: number) => wins.has(id) && byKey.value.has(wins.get(id)!.key);
  const tiles = shown.filter(known);
  if (tiles.length < 2) return null;
  const ids = [...tiles, ...extra.filter(known)];
  const keys = ids.map((id) => wins.get(id)!.key);
  const first = wins.get(tiles[0])!;
  return { keys, ids, icons: keys.slice(0, Math.min(4, tiles.length)), page: first.page, layout, minimised: ids.every((id) => wins.get(id)!.minimised) };
}

/** The stacks' hidden tabs of the windows [ids] (a tiled stack's other tabs). */
const tabsOf = (ids: number[]) => stacks.value.filter((s) => ids.includes(s.active)).flatMap((s) => s.ids.filter((v) => v !== s.active));

// The last value, kept while equal: webWins changes every frame of a move; the groups only when one forms or ends.
let last: DockGroup[] = [];
const sig = (gs: DockGroup[]) => JSON.stringify(gs);

/**
 * Android's split (WM Shell's: folded, or an app that can't be a web window) as one cell too, as its switcher card is
 * one card - unless its apps are a web window group already ([groups]).
 */
function splitGroup(groups: DockGroup[]): DockGroup | null {
  const split = livePair.value;
  if (!split || !split.keys.every((k) => byKey.value.has(k))) return null;
  if (split.keys.some((k) => groups.some((g) => g.keys.includes(k)))) return null;
  return { keys: split.keys, ids: [], icons: split.keys, page: pageId(), layout: split.layout, minimised: false, native: split.ids };
}

/** The window groups on the dock, tilings by page, then stacks. */
export const dockGroups = computed((): DockGroup[] => {
  const wins = new Map(webWins.value.filter((w) => !w.full && !w.quick).map((w) => [w.id, w]));
  const out: DockGroup[] = [];
  const taken = new Set<number>();
  for (const t of Object.values(tilings.value)) {
    const shown = t.ids.filter((id): id is number => id != null);
    const g = groupOf(shown, tabsOf(shown), t.layout, wins);
    if (g) (out.push(g), g.ids.forEach((id) => taken.add(id)));
  }
  for (const s of stacks.value) {
    if (s.ids.some((id) => taken.has(id))) continue;
    const g = groupOf(s.ids, [], "stack", wins);
    if (g) out.push(g);
  }
  const split = splitGroup(out);
  if (split) out.push(split);
  if (sig(out) === sig(last)) return last;
  return (last = out);
});

/** The apps in a group: none of them gets its own dock cell. */
export const groupedKeys = computed(() => new Set(dockGroups.value.flatMap((g) => g.keys)));

/** The groups with an app not in [pinned] (a pinned app keeps its pinned cell). */
export const unpinnedGroups = (pinned: string[]) => dockGroups.value.filter((g) => g.keys.some((k) => !pinned.includes(k)));

/** The group's mark (pagemarks.ts's classes): its page on screen and not all minimised - the pill; else the dot. */
const groupMark = (g: DockGroup) => (g.page === pageId() && !g.minimised ? "mark-here" : "mark-away");

/** A group's dock cell: its icons together, a tap brings the whole group to the front on its page. */
export function DockGroupCell({ group }: { group: DockGroup }) {
  // Android's split: the split back (as its switcher card's tap, ShellBridge openSplit) - never one of its apps alone.
  const press = usePress(() => (group.native ? void powos.tasks.openSplit(group.native[0], group.native[1]) : bringGroup(group.ids, group.page)), () => {}, null);
  const icons = group.icons.map((k) => byKey.value.get(k)?.icon ?? null);
  const state = group.minimised ? "minimised" : "running";
  return (
    <div class={`app group windowed ${state} ${groupMark(group)}`} data-key={group.native ? `split:${group.native.join(",")}` : `group:${group.ids.join(",")}`} data-group={group.keys.join(",")} {...press}>
      <GroupIcon class="app-icon" icons={icons} layout={group.layout} />
    </div>
  );
}

// PowOS's own split: a tiling of 2+ web windows (not a tab stack) is a pair used now - one recent entry (ui/pairs.tsx).
// Only a group that formed or changed since the last run: two tilings on two pages don't swap places on every update.
let noted = new Set<string>();
effect(() => {
  const now = new Set<string>();
  for (const g of dockGroups.value) {
    if (g.layout === "stack" || g.native) continue;
    const id = `${g.layout} ${g.icons.join(",")}`;
    now.add(id);
    if (!noted.has(id)) notePair({ keys: g.icons, layout: g.layout });
  }
  noted = now;
});
