/**
 * DG1 (the user, 2026-10-31 03:18: "when two apps are like, docked together... I don't really see it on the launcher,
 * the homebar doesn't really show them as docked together"): PowOS's window groups in the dock as one cell each.
 * A group is a tiling (ui/webwindows.tsx tilings, per home page) with 2 or more windows, or a tab stack (stacks) with
 * 2 or more tabs that isn't in such a tiling (a tiled stack's tabs belong to its tiling's group). Its cell shows the
 * group's icons together (switcher.tsx SplitIcons, the split card's) in the group's layout; its apps get no cells of
 * their own; a tap brings every window of the group to the front on its page (webwindows.tsx bringGroup). Its mark
 * (pagemarks.ts) is the group's page against the page on screen. Folded there are no web windows: no groups.
 */
import { computed } from "@preact/signals";
import { byKey } from "../state.ts";
import { usePress } from "./apps.tsx";
import { pageId } from "./desktops.ts";
import { SplitIcons } from "./switcher.tsx";
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

/** The window groups on the dock, tilings by page, then stacks. */
export const dockGroups = computed((): DockGroup[] => {
  const wins = new Map(webWins.value.filter((w) => !w.full).map((w) => [w.id, w]));
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
  const press = usePress(() => bringGroup(group.ids, group.page), () => {}, null);
  const icons = group.icons.map((k) => byKey.value.get(k)?.icon ?? null);
  const state = group.minimised ? "minimised" : "running";
  return (
    <div class={`app group windowed ${state} ${groupMark(group)}`} data-key={`group:${group.ids.join(",")}`} data-group={group.keys.join(",")} {...press}>
      <div class="app-icon group-icon">
        <SplitIcons icons={icons} layout={group.layout} />
      </div>
    </div>
  );
}
