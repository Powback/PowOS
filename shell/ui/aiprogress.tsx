/**
 * PowOS AI's Progress (the user, 2026-10-31 15:12: "The design of the progress page can be better"): at the top a large
 * ring with the daily driver's percentage, under it one glass row card per area - its name, a thin bar of what's done of
 * the last 30 days' work and the counts, an amber "N need you" chip (the needs-you colour) - and a tap opens an area in place: its open tasks,
 * one line each, a state dot (working / waiting on you / no check). The parts are exported for the folded status page.
 */
import { useState } from "preact/hooks";
import { boardState } from "../agents.ts";
import { board, boardSeen, checks, WorkFeed, type WorkRow } from "./aiboard.tsx";

const MONTH_MS = 30 * 24 * 3_600_000;

/** One area's month: [done] of [total] (open + done in the last 30 days), [you] waiting on the user, its open rows. */
export interface AreaStat {
  name: string;
  done: number;
  total: number;
  you: number;
  open: WorkRow[];
}

/**
 * The board's areas (design QA, 2026-10-31) in their order, each with the older project names that belong to it: a row
 * from before `task infer` ("PowOS · phone UI", "PowOS · kernel") is counted in its area, never under its own name.
 */
export const AREAS: [string, RegExp][] = [
  ["Windows", /window|desktop/i],
  ["Home & launcher", /home|launcher|dock|widget|phone ui/i],
  ["Shade & lock", /shade|lock|notif|quick ?settings/i],
  ["AI page", /\bai\b|chat|assistant/i],
  ["Apps", /\bapps?\b|store/i],
  ["Games", /game/i],
  ["Performance", /perf|speed|battery/i],
  ["Kernel & system", /kernel|system|boot|driver|root/i],
  ["Agents & tooling", /agent|tool|gate|ship/i],
];

/** The area a board row is in (its project, mapped; "Other" when none fits). */
export function areaOf(w: WorkRow) {
  const p = w.project.trim();
  return AREAS.find(([name, rx]) => name === p || rx.test(p))?.[0] ?? "Other";
}
const doneAt = (w: WorkRow) => Number(w.done || w.updated || 0);
const inMonth = (w: WorkRow, now: number) => w.status !== "done" || now - doneAt(w) < MONTH_MS;

/** The board per area: the most waiting on the user first, then the most open. */
export function areaStats(rows: WorkRow[] = board.value, now = Date.now()): AreaStat[] {
  const by = new Map<string, AreaStat>();
  for (const w of rows) {
    if (!inMonth(w, now)) continue;
    const name = areaOf(w);
    const a = by.get(name) ?? { name, done: 0, total: 0, you: 0, open: [] };
    a.total++;
    if (w.status === "done") a.done++;
    else a.open.push(w);
    if (w.status === "waiting") a.you++;
    by.set(name, a);
  }
  // Those that need the user first, then the most open.
  return [...by.values()].sort((x, y) => y.you - x.you || y.open.length - x.open.length || x.name.localeCompare(y.name));
}

/** The ring's figure: the daily-driver epic's own progress (its board row), else the month's share done overall. */
export function driverPct(stats: AreaStat[], rows: WorkRow[] = board.value): { pct: number; label: string } | null {
  const w = rows.find((x) => /^daily driver\b/i.test(x.title) && (x.progressTotal ?? 0) > 0);
  if (w) return { pct: Math.round((100 * Math.min(w.progressDone ?? 0, w.progressTotal!)) / w.progressTotal!), label: "Daily driver" };
  const total = stats.reduce((n, a) => n + a.total, 0);
  return total ? { pct: Math.round((100 * stats.reduce((n, a) => n + a.done, 0)) / total), label: "Done this month" } : null;
}

/** A large progress ring with its percentage in the middle. */
export function ProgressRing({ pct, label, sub }: { pct: number; label: string; sub?: string }) {
  const r = 52;
  const c = 2 * Math.PI * r;
  const p = Math.max(0, Math.min(100, pct));
  return (
    <div class="aip-ring-wrap">
      <svg class="aip-ring" viewBox="0 0 120 120" role="img" aria-label={`${label} ${p}%`}>
        <circle class="aip-ring-track" cx="60" cy="60" r={r} />
        <circle class="aip-ring-fill" cx="60" cy="60" r={r} stroke-dasharray={`${(c * p) / 100} ${c}`} transform="rotate(-90 60 60)" />
      </svg>
      <div class="aip-ring-mid">
        <span class="aip-ring-pct">{p}%</span>
      </div>
      <div class="aip-ring-text">
        <span class="aip-ring-label">{label}</span>
        {sub && <span class="aip-ring-sub">{sub}</span>}
      </div>
    </div>
  );
}

/** A thin bar, [done] of [total], its fill a spring from empty (transform only). */
export function ThinBar({ done, total }: { done: number; total: number }) {
  const k = total ? Math.min(1, done / total) : 0;
  return (
    <span class="aip-bar" role="progressbar" aria-valuemin={0} aria-valuemax={total} aria-valuenow={done} data-done={done} data-total={total}>
      <span class="aip-bar-fill" style={{ transform: `scaleX(${k})` }} />
    </span>
  );
}

type Dot = "working" | "check" | "waiting" | "stalled";
/** Each dot's words, in the legend's order. */
export const DOTS: [Dot, string][] = [
  ["working", "working"],
  ["check", "awaiting check"],
  ["waiting", "needs you"],
  ["stalled", "stalled / no check"],
];
const DOT_WORDS = Object.fromEntries(DOTS) as Record<Dot, string>;

/** An open task's true state: waiting on the user, an agent on it, its phone check queued or running, else stalled. */
export function dotOf(w: WorkRow): Dot {
  if (w.status === "waiting") return "waiting";
  const s = boardState(w, checks.value);
  return s === "working" ? "working" : s === "awaiting check" ? "check" : "stalled";
}

/** The dots' legend: one small line. */
export function DotLegend() {
  return (
    <div class="aip-legend">
      {DOTS.map(([d, words]) => (
        <span key={d} class="aip-legend-item">
          <span class={`aip-dot ${d}`} aria-hidden="true" />
          {words}
        </span>
      ))}
    </div>
  );
}

/** An area's open tasks, up to two lines each. */
function Tasks({ open }: { open: WorkRow[] }) {
  return (
    <ul class="aip-tasks">
      {open.map((w) => {
        const d = dotOf(w);
        return (
          <li key={w.id} class="aip-task">
            <span class={`aip-dot ${d}`} role="img" aria-label={DOT_WORDS[d]} />
            <span class="aip-task-title">{w.title}</span>
          </li>
        );
      })}
    </ul>
  );
}

/** One area as a glass row card; a tap opens its tasks in place. */
export function AreaRow({ a, open, toggle }: { a: AreaStat; open: boolean; toggle: () => void }) {
  return (
    <li class={`aip-area tile ${open ? "open" : ""}`}>
      <button type="button" class="aip-area-row" aria-expanded={open} onClick={toggle}>
        <span class="aip-area-name">{a.name}</span>
        {a.you > 0 && <span class="aip-chip">{a.you} need you</span>}
        <ThinBar done={a.done} total={a.total} />
        <span class="aip-count">
          {a.done}/{a.total}
        </span>
      </button>
      {open && a.open.length > 0 && <Tasks open={a.open} />}
    </li>
  );
}

/** "3 need you · 42 open": the ring's line under its label. */
function subLine(stats: AreaStat[]) {
  const you = stats.reduce((n, a) => n + a.you, 0);
  const open = stats.reduce((n, a) => n + a.open.length, 0);
  return [you ? `${you} need you` : "", `${open} open`].filter(Boolean).join(" · ");
}

/** The Progress view: the ring, then every area's card. [shown]: the board's feed runs only then. */
export function ProgressView({ shown }: { shown: boolean }) {
  const [opened, setOpened] = useState<string | null>(null);
  const stats = areaStats();
  const ring = driverPct(stats);
  return (
    <section class="aip">
      {shown && <WorkFeed />}
      {ring && <ProgressRing pct={ring.pct} label={ring.label} sub={subLine(stats)} />}
      {stats.length > 0 && <DotLegend />}
      <ul class="aip-areas">
        {stats.map((a) => (
          <AreaRow key={a.name} a={a} open={opened === a.name} toggle={() => setOpened(opened === a.name ? null : a.name)} />
        ))}
      </ul>
      {!stats.length && <div class="aip-empty">{boardSeen.value ? "Nothing in progress" : "…"}</div>}
    </section>
  );
}
