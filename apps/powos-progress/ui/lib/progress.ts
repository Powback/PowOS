/**
 * The road to PowOS as the user's everyday phone, from two live sources (no polling - both are SpacetimeDB
 * subscriptions, re-rendered on every change):
 * - the daily-driver checklist: this app's own `item` table (module/src/lib.rs), which the manager edits with
 *   `powos progress item add|set|list|rm`;
 * - the work board: the powos-agents module's `work` table, read-only, on the same subscription the PowOS AI page
 *   uses (one socket per database for the whole shell, shell/apps/stdb.ts). This app never writes it.
 */
import { useApp, type Host } from "./app";

export type ItemState = "works" | "partly" | "broken" | "untested";
export interface Item {
  id: string;
  area: string;
  capability: string;
  state: ItemState;
  tasks: string;
  note: string;
  rank: number;
  updated: bigint | number;
}

/** A powos-agents `work` row, as the SDK hands it (camelCase); only what this app reads. */
export interface WorkRow {
  id: string;
  title: string;
  owner: string;
  status: string;
  note: string;
  project: string;
  step: string;
  tryLine?: string;
  done: bigint | number;
  updated: bigint | number;
  activity?: bigint | number;
  parent?: string;
}

/** What a board task means for the user right now. */
export type Lane = "you" | "try" | "on" | "blocked" | "done";
export const LANES: { key: Lane; name: string }[] = [
  { key: "you", name: "Needs you" },
  { key: "try", name: "Ready to try" },
  { key: "on", name: "Being worked on" },
  { key: "blocked", name: "Blocked" },
  { key: "done", name: "Done" },
];

/** The board's areas, in the AI page's order (lib/ai/agents/powos-agents-cli AREAS). */
export const AREAS = ["Windows", "Home & launcher", "Shade & lock", "Games", "Performance", "Kernel & system", "AI page", "Apps", "Agents & tooling"];
export const OTHER = "Other";
export const areaOf = (w: WorkRow) => (AREAS.includes(w.project) ? w.project : OTHER);

/**
 * HACK: a plain status-based lane, not the AI page's full grouping (shell/ui/powai.tsx groupOf: agent liveness, phone
 * checks, the user's verdicts). Close enough for counts and blockers; the real fix is that grouping moved into a
 * module both read (or the board publishing each task's lane as a column).
 */
export function laneOf(w: WorkRow): Lane {
  if (w.status === "done") return "done";
  if (w.status === "waiting") return "you";
  if (w.status === "blocked") return "blocked";
  return w.tryLine?.trim() ? "try" : "on";
}

/** A P0: the board marks the must-fix ones "P0" in their title, note or step. */
export const isP0 = (w: WorkRow) => w.status !== "done" && /\bP0\b/.test(`${w.title} ${w.note} ${w.step}`);

const n = (v: bigint | number | undefined) => Number(v ?? 0);

export const STATE_NAME: Record<ItemState, string> = { works: "works", partly: "partly works", broken: "broken", untested: "not tried yet" };
export const STATE_COLOR: Record<ItemState, string> = {
  works: "var(--color-green, #4caf6a)",
  partly: "var(--color-yellow, #d9a43a)",
  broken: "var(--color-red, #e0605a)",
  untested: "color-mix(in srgb, currentColor 22%, transparent)",
};
export const STATE_ORDER: ItemState[] = ["works", "partly", "broken", "untested"];

export interface AreaBar {
  area: string;
  items: Item[];
  counts: Record<ItemState, number>;
  pct: number;
}

/** Works items / all items, 0..100 (null: an empty checklist). */
export const pctOf = (items: Item[]) => (items.length ? Math.round((100 * items.filter((i) => i.state === "works").length) / items.length) : null);

/** The checklist by area, in first-seen order of the areas' lowest rank; items by rank then id. */
export function areas(items: Item[]): AreaBar[] {
  const sorted = [...items].sort((a, b) => a.rank - b.rank || a.id.localeCompare(b.id));
  const m = new Map<string, Item[]>();
  for (const i of sorted) m.set(i.area, [...(m.get(i.area) ?? []), i]);
  return [...m].map(([area, its]) => {
    const counts = { works: 0, partly: 0, broken: 0, untested: 0 } as Record<ItemState, number>;
    for (const i of its) counts[STATE_ORDER.includes(i.state) ? i.state : "untested"]++;
    return { area, items: its, counts, pct: pctOf(its) ?? 0 };
  });
}

export const taskIds = (i: Item) => i.tasks.split(",").map((t) => t.trim()).filter(Boolean);

/** One blocker line: a P0 on the board, or a broken checklist item. */
export interface Blocker {
  key: string;
  text: string;
  /** The board task it opens (a broken item: its first linked task). */
  task?: string;
  kind: "p0" | "broken";
}

/** The top blockers: P0s needing the user first, then the other P0s, then broken items - newest activity first. */
export function blockers(work: WorkRow[], items: Item[]): Blocker[] {
  const p0 = work
    .filter(isP0)
    .sort((a, b) => Number(laneOf(b) === "you") - Number(laneOf(a) === "you") || n(b.activity || b.updated) - n(a.activity || a.updated))
    .map((w): Blocker => ({ key: `w:${w.id}`, text: w.title.replace(/^\s*P0[:\s-]*/i, ""), task: w.id, kind: "p0" }));
  const linked = new Set(p0.map((b) => b.task));
  const broken = items
    .filter((i) => i.state === "broken")
    .sort((a, b) => n(b.updated) - n(a.updated))
    .map((i): Blocker => ({ key: `i:${i.id}`, text: i.capability, task: taskIds(i)[0], kind: "broken" }))
    .filter((b) => !b.task || !linked.has(b.task));
  return [...p0, ...broken];
}

/** Local midnight today (ms). */
export function todayStart(now = Date.now()) {
  const d = new Date(now);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}

/** Board tasks finished today, newest first: the page's "shipped today". */
export const doneToday = (work: WorkRow[], now = Date.now()) =>
  work.filter((w) => w.status === "done" && n(w.done) >= todayStart(now)).sort((a, b) => n(b.done) - n(a.done));

export const clock = (ms: bigint | number) => new Date(n(ms)).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });

const BOARD_QUERY = "SELECT * FROM work"; // the AI page's own query (shell/ui/powai.tsx WORK_QUERY): one subscription

/** A known hack: a HACK registry row (docs/REMOTE-POWOS.md §4), synced on every ship (module/src/lib.rs `hack`). */
export interface Hack {
  key: string;
  file: string;
  line: number;
  area: string;
  why: string;
  fix: string;
  task: string;
  since: bigint | number;
}

/** Oldest first (unknown age last). */
export const byAge = (hs: Hack[]) => [...hs].sort((a, b) => (n(a.since) || Infinity) - (n(b.since) || Infinity) || a.key.localeCompare(b.key));

/** "3 days", "5 weeks": how long a hack has stood. */
export function age(since: bigint | number, now = Date.now()) {
  const ms = n(since);
  if (!ms) return "";
  const d = Math.max(0, Math.floor((now - ms) / 86400000));
  if (d < 1) return "today";
  if (d < 14) return `${d} day${d === 1 ? "" : "s"}`;
  if (d < 70) return `${Math.floor(d / 7)} weeks`;
  return `${Math.floor(d / 30)} months`;
}

/** A hack's one plain line: the first sentence of why it's there. */
export const hackLine = (h: Hack) => h.why.split(/(?<=[.;:])\s/)[0].replace(/[.;:]$/, "");

/** Both sources, live. */
export function useProgress(host: Host) {
  const app = useApp(host);
  const items = app.useTable<Item>("item");
  const hacks = app.useTable<Hack>("hack");
  // No bindings of our own: the shell's (shell/apps/stdb.ts SHARED), so `work` decodes exactly as the AI page reads it.
  const agents = host.useDb("powos-agents", undefined);
  const work = host.useRows<WorkRow>(agents, "work", BOARD_QUERY);
  const open = work.filter((w) => w.status !== "done");
  return {
    status: app.useStatus(),
    boardStatus: agents.status,
    items,
    work,
    pct: pctOf(items),
    areas: areas(items),
    blockers: blockers(work, items),
    on: open.filter((w) => laneOf(w) === "on").length,
    you: open.filter((w) => laneOf(w) === "you").length,
    hacks,
  };
}

/** Which board task the page opens on (the widget's tapped blocker): the widget and the page are separate bundles. */
const FOCUS = "powos-progress.focus";
export function setFocus(task: string | undefined) {
  try {
    if (task) sessionStorage.setItem(FOCUS, task);
    else sessionStorage.removeItem(FOCUS);
  } catch {
    /* storage blocked: the page opens at its top */
  }
}
export function takeFocus(): string | null {
  try {
    const t = sessionStorage.getItem(FOCUS);
    sessionStorage.removeItem(FOCUS);
    return t;
  } catch {
    return null;
  }
}

/** The known hacks alone (the Hacks widget: no board subscription). */
export function useHacks(host: Host) {
  const app = useApp(host);
  return { status: app.useStatus(), hacks: byAge(app.useTable<Hack>("hack")) };
}
