/**
 * PowOS AI's Progress (the user, 2026-10-31 15:12: "The design of the progress page can be better"): at the top a large
 * ring with the daily driver's percentage, under it one glass row card per area - its name, a thin bar of what's done of
 * the last 30 days' work and the counts, an amber "N need you" chip (the needs-you colour) - and a tap opens an area in place: its open tasks,
 * one line each, a state dot (working / waiting on you / no check). The parts are exported for the folded status page.
 * Above the areas, the Needs you card (needsyou.tsx): what really waits on the user, each answered in place.
 */
import { memo, sameContent } from "./memo.ts";
import { useEffect, useState } from "preact/hooks";
import { computed, signal } from "@preact/signals";
import { boardState, QUEUED_STEP, type BoardCheck } from "../agents.ts";
import { board, boardSeen, checks, isParked, PARKED, SevChip, WorkFeed, type WorkRow } from "./aiboard.tsx";
import { needIds, needsYou, NeedsYouCard } from "./needsyou.tsx";
import { upNext, UpNext } from "./upnext.tsx";
import { Reveal } from "./reveal.tsx";

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

/** What boardCounts gives: how many are open, done (today, this week), parked; and the open and done rows behind them. */
export interface BoardCounts {
  open: number;
  done: number;
  backlog: number;
  stale: number;
  today: number;
  week: number;
  rows: { open: WorkRow[]; done: WorkRow[] };
}

/** How many of [done] (newest first) were done since local midnight, and in the last 7 days. */
function doneWhen(done: WorkRow[], now: number) {
  const midnight = new Date(now).setHours(0, 0, 0, 0);
  return { today: done.filter((w) => doneAt(w) >= midnight).length, week: done.filter((w) => now - doneAt(w) < 7 * 24 * 3_600_000).length };
}

/**
 * The board's counts, the ONE place they are worked out (every header and glance reads these, so a parked task is
 * never counted as open work anywhere): [open] - not done and not parked; [done] - closed (the board keeps a week), of
 * them [today] / [week]; [backlog] / [stale] - parked, shown only in their folds; [rows] the open and done tasks behind
 * the two numbers (done newest first) - the list a tap on the status header's "N open" / "M done" filters to (the user,
 * 11-25, circling "Done this month 30%": they want how many are open and how many done, not a share of a month).
 */
export function boardCounts(rows: WorkRow[] = board.value, now = Date.now()): BoardCounts {
  const parked = { backlog: 0, stale: 0 };
  const open: WorkRow[] = [];
  const done: WorkRow[] = [];
  for (const w of rows) {
    if (w.status === "backlog" || w.status === "stale") parked[w.status]++;
    else (w.status === "done" ? done : open).push(w);
  }
  done.sort((a, b) => doneAt(b) - doneAt(a));
  return { open: open.length, done: done.length, ...parked, ...doneWhen(done, now), rows: { open, done } };
}

/** [boardCounts] worked out once per board change, never per render (as heroRing). */
export const counts = computed(() => boardCounts(board.value));

/** The board per area: the most waiting on the user first, then the most open. Parked tasks (backlog, stale) aren't in it. */
export function areaStats(rows: WorkRow[] = board.value, now = Date.now(), you: Set<string> = needIds(needsYou(rows))): AreaStat[] {
  const by = new Map<string, AreaStat>();
  for (const w of rows) {
    if (isParked(w) || !inMonth(w, now)) continue;
    const name = areaOf(w);
    const a = by.get(name) ?? { name, done: 0, total: 0, you: 0, open: [] };
    a.total++;
    if (w.status === "done") a.done++;
    else a.open.push(w);
    if (you.has(w.id)) a.you++;
    by.set(name, a);
  }
  // Those that need the user first, then the most open.
  return [...by.values()].sort((x, y) => y.you - x.you || y.open.length - x.open.length || x.name.localeCompare(y.name));
}

/** The ring's figure: the daily-driver epic's own progress (its board row), else the month's share done overall. */
export function driverPct(stats: AreaStat[], rows: WorkRow[] = board.value): { pct: number; label: string } | null {
  const dd = dailyDriverOf(rows);
  if (dd) return dd;
  const total = stats.reduce((n, a) => n + a.total, 0);
  return total ? { pct: Math.round((100 * stats.reduce((n, a) => n + a.done, 0)) / total), label: "Done this month" } : null;
}

/** The daily-driver epic's own progress (its board row with steps), or null when the board has none. */
export function dailyDriverOf(rows: WorkRow[] = board.value): { pct: number; label: string } | null {
  const w = rows.find((x) => /^daily driver\b/i.test(x.title) && (x.progressTotal ?? 0) > 0);
  return w ? { pct: Math.round((100 * Math.min(w.progressDone ?? 0, w.progressTotal!)) / w.progressTotal!), label: "Daily driver" } : null;
}

/**
 * The status hero's ring: the daily driver's figure only - never the month's share done (the user, 11-25, circling "Done
 * this month 30%": it meant nothing; the hero leads with counts, boardCounts). Worked out once per board change, never
 * per render (perf trace perf-1793551432355, 11-01: a per-render board scan was a 4.7 ms commit).
 */
export const heroRing = computed(() => dailyDriverOf(board.value));

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
// Memo: a bar re-renders only when done/total change (render scan 11-03: 200 of 210 renders needless).
export const ThinBar = memo(function ThinBar({ done, total }: { done: number; total: number }) {
  const k = total ? Math.min(1, done / total) : 0;
  return (
    <span class="aip-bar" role="progressbar" aria-valuemin={0} aria-valuemax={total} aria-valuenow={done} data-done={done} data-total={total}>
      <span class="aip-bar-fill" style={{ transform: `scaleX(${k})` }} />
    </span>
  );
}, sameContent);

export type Dot = "working" | "check" | "waiting" | "stalled";
/** Each dot's words, in the legend's order. */
export const DOTS: [Dot, string][] = [
  ["working", "working"],
  ["check", "awaiting check"],
  ["waiting", "needs you"],
  ["stalled", "stalled / no check"],
];
const DOT_WORDS = Object.fromEntries(DOTS) as Record<Dot, string>;

/** An open task's true state: waiting on the user, an agent on it, its phone check queued or running, else stalled. */
export function dotOf(w: WorkRow, you: Set<string> = needIds()): Dot {
  if (you.has(w.id)) return "waiting";
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

/**
 * What an open task waits on, in plain words (the user, 11-03 22:56: "says 1 to check but which one???" - a count alone
 * never says what to look at): [what] - the user's own try ("Try it on the phone: ...", the task's try line), else its
 * step or, waiting on the user, its note; [check] - the phone check it waits for, queued or running, with its line.
 */
export function waitsOn(w: WorkRow, d: Dot, cs: BoardCheck[] = checks.value): { what: string; check: string } {
  return { what: whatOf(w, d), check: d === "check" ? checkOf(w, cs) : "" };
}

/** What the user can do about it: try it on the phone (its try line), else its step; waiting on the user: its note first. */
function whatOf(w: WorkRow, d: Dot): string {
  const tryLine = w.tryLine?.trim();
  const step = w.step?.trim();
  const tryIt = tryLine ? `Try it on the phone: ${tryLine}` : "";
  const now = step && step !== QUEUED_STEP ? step : "";
  return (d === "waiting" && w.note?.trim()) || tryIt || now;
}

/** The phone check it waits for: the newest queued or running one, with its line. */
function checkOf(w: WorkRow, cs: BoardCheck[]): string {
  const c = cs.filter((x) => x.task === w.id && (x.state === "queued" || x.state === "running")).at(-1);
  if (!c) return "Phone check queued";
  return c.line ? `Phone check ${c.state}: ${c.line}` : `Phone check ${c.state}`;
}

/** Another page asked to show one task (By area's "Open task"): Progress opens its area and marks the row. */
export const progressFocus = signal<{ area: string; id: string } | null>(null);

/** An area's open tasks, up to two lines each; one waiting for a check says what to check under it. */
function Tasks({ open }: { open: WorkRow[] }) {
  const you = needIds();
  const focus = progressFocus.value?.id;
  return (
    <ul class="aip-tasks">
      {open.map((w) => {
        const d = dotOf(w, you);
        const why = d === "check" ? waitsOn(w, d) : null;
        return (
          <li key={w.id} class={`aip-task ${focus === w.id ? "focus" : ""}`} data-task={w.id}>
            <span class={`aip-dot ${d}`} role="img" aria-label={DOT_WORDS[d]} />
            <SevChip w={w} />
            <span class="aip-task-text">
              <span class="aip-task-title">{w.title}</span>
              {why && <span class="aip-task-why">{[why.what, why.check].filter(Boolean).join(" · ")}</span>}
            </span>
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
      <Reveal open={open && a.open.length > 0}>
        <Tasks open={a.open} />
      </Reveal>
    </li>
  );
}

/**
 * Parked work under the areas (the user, 11-25: "move stale reports to stale and the backlog to the backlog"): one folded
 * card each, "Backlog · N" and "Stale · N" (none: not drawn); a tap opens its tasks, each with its note (why it's parked).
 */
export function Parked({ rows = board.value }: { rows?: WorkRow[] }) {
  const [opened, setOpened] = useState<string | null>(null);
  const folds = PARKED.map(([s, label]) => [s, label, rows.filter((w) => w.status === s)] as const).filter(([, , r]) => r.length);
  if (!folds.length) return null;
  return (
    <ul class="aip-areas aip-parked">
      {folds.map(([s, label, r]) => (
        <li key={s} class={`aip-area tile ${opened === s ? "open" : ""}`} data-parked={s}>
          <button type="button" class="aip-area-row" aria-expanded={opened === s} onClick={() => setOpened(opened === s ? null : s)}>
            <span class="aip-area-name">
              {label} · {r.length}
            </span>
            <span class="aip-count" aria-hidden="true">{opened === s ? "▾" : "▸"}</span>
          </button>
          <Reveal open={opened === s}>
            <ul class="aip-tasks">
              {r.map((w) => (
                <li key={w.id} class="aip-task" data-task={w.id}>
                  <span class="aip-task-text">
                    <span class="aip-task-title">{w.title}</span>
                    {w.note?.trim() && <span class="aip-task-why">{w.note.trim()}</span>}
                  </span>
                </li>
              ))}
            </ul>
          </Reveal>
        </li>
      ))}
    </ul>
  );
}

/** "3 need you · 42 open": the ring's line under its label. */
function subLine(stats: AreaStat[]) {
  const you = stats.reduce((n, a) => n + a.you, 0);
  const open = stats.reduce((n, a) => n + a.open.length, 0);
  return [you ? `${you} need you` : "", `${open} open`].filter(Boolean).join(" · ");
}

/** The area By area's "Open task" asked for (null: none). */
const focusArea = () => progressFocus.value?.area ?? null;

/** By area's "Open task" ([progressFocus]): its area opened, the row brought into view once the area has opened. */
function useFocus(setOpened: (area: string) => void) {
  const focus = progressFocus.value;
  useEffect(() => {
    if (!focus) return;
    setOpened(focus.area);
    const t = window.setTimeout(() => document.querySelector(`.aip-task[data-task="${CSS.escape(focus.id)}"]`)?.scrollIntoView({ block: "center", behavior: "smooth" }), 120);
    return () => clearTimeout(t);
  }, [focus]);
}

/** The Progress view: the ring, then every area's card. [shown]: the board's feed runs only then. */
export function ProgressView({ shown, areasOnly = false }: { shown: boolean; areasOnly?: boolean }) {
  const [opened, setOpened] = useState<string | null>(focusArea);
  useFocus(setOpened);
  const needs = needsYou();
  const stats = areaStats(board.value, Date.now(), needIds(needs));
  const ring = driverPct(stats);
  return (
    <section class="aip">
      {shown && <WorkFeed />}
      {!areasOnly && ring && <ProgressRing pct={ring.pct} label={ring.label} sub={subLine(stats)} />}
      {!areasOnly && <NeedsYouCard needs={needs} />}
      {!areasOnly && <UpNext rows={upNext()} busy={needs.length > 0} />}
      {stats.length > 0 && <DotLegend />}
      <ul class="aip-areas">
        {stats.map((a) => (
          <AreaRow key={a.name} a={a} open={opened === a.name} toggle={() => ((progressFocus.value = null), setOpened(opened === a.name ? null : a.name))} />
        ))}
      </ul>
      {!stats.length && <div class="aip-empty">{boardSeen.value ? "Nothing in progress" : "…"}</div>}
      <Parked />
    </section>
  );
}
