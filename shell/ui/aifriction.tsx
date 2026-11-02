/**
 * The Friction page (PowOS AI's ⋯ › Friction): what keeps going wrong for the agents, in the user's words. The user,
 * 2026-11-01 22:41 / 23:01: "fricticon page is trash" - it was one box of raw log lines ("ship 68221469a (apk) FAILED
 * rc 5: ship-apk: REFUSED - build-app.sh failed", "14× · permissions · refused · now ago"): commit hashes, exit codes,
 * file names, kebab-case tags, the same failure once per commit, no order but the count, nothing to open.
 *
 * Now the Progress page's design (aistatus.tsx): one glass card per area, the worst area first; in each, one plain
 * line per problem ([plainTitle]: repeats of the same failure merged, so nine refused updates are one row), a P0/P1
 * chip from the board's severity rule (count x1, P1 at 50, P0 at 500, or the board task it is evidence for), how
 * often as a small number, and its state (open / being fixed by an agent / fixed). The logged words, the repro, the
 * evidence and the fix's commit are behind a tap. Fixed in the last week is one folded card at the end.
 *
 * What the old page did, kept: open friction only in the main list, the most frequent first within a severity, a
 * count, area, kind (now words in the detail), last seen; "no friction open" when there is none; the board's feed
 * subscribed while it shows (aimenu.tsx FrictionScreen). New: grouping, merging, severity, state, details, fixed list,
 * "ask the manager" to hand one to an agent.
 */
import { useState } from "preact/hooks";
import { ago } from "./time.ts";
import { askQueued } from "./assistant.ts";
import { board, boardSeen, friction, type FrictionRow, type WorkRow } from "./aiboard.tsx";
import { Reveal } from "./reveal.tsx";

/** The board's severity rule (apps/agents severity_of): one report counts 1, P1 at 50, P0 at 500. */
const P1_AT = 50;
const P0_AT = 500;
/** Fixed this recently shows in "Fixed recently". */
const FIXED_MS = 7 * 86400e3;
/** Rows an area shows before "N more". */
const AREA_ROWS = 6;

/** An area's name in words (the logged area is a tool's tag: "gate", "ship", "permissions"). */
const AREAS: Record<string, string> = {
  gate: "Checks",
  verify: "Phone checks",
  check: "Checks",
  ship: "Updates",
  install: "Updates",
  build: "Builds",
  permissions: "Permissions",
  phone: "The phone",
  adb: "Phone connection",
  git: "Code syncing",
  board: "Task board",
  agents: "Agents",
  worktree: "Agent workspaces",
  stdb: "Database",
  network: "Network",
};
export const areaName = (a: string) => AREAS[a] ?? cap((a || "other").replace(/[-_./]+/g, " ").trim());

/** What a kind of friction means, as a fallback title. */
const KINDS: Record<string, string> = {
  refused: "Something was refused",
  "broken-tool": "A tool broke",
  "flaky-check": "A check failed at random",
  "unclear-rule": "A rule was unclear",
  slow: "Something was too slow",
};
const kindName = (k: string) => KINDS[k] ?? "Something got in the way";

function cap(s: string) {
  return s ? s[0].toUpperCase() + s.slice(1) : s;
}

/** What an update shipped ("apk" → the phone app, "apps:app-api health" → the api app). */
function shipWhat(raw: string) {
  const m = raw.match(/\(([^)]*)\)/);
  const w = m?.[1].trim() ?? "";
  if (!w || /^apk$/i.test(w)) return "the phone app";
  if (/^shell/i.test(w)) return "the shell";
  const app = w.match(/^apps?:\s*(?:app-)?([a-z0-9-]+)/i);
  if (app) return `the ${app[1].replace(/-/g, " ")} app`;
  return "";
}

/** Known log lines and their meaning; the first match wins. */
const PLAIN: [RegExp, (raw: string) => string][] = [
  [/^ship\b.*\b(skip|skipped)\b/i, (r) => (shipWhat(r) ? `An update to ${shipWhat(r)} was skipped` : "An update was skipped")],
  [/^ship\b.*\b(fail|failed|refused)\b/i, (r) => (shipWhat(r) ? `An update to ${shipWhat(r)} failed to install` : "An update failed to install")],
  [/permission system|permission denied|not permitted/i, () => "A command was blocked by the safety rules"],
  [/gate failed while the mac'?s load was high/i, () => "Checks failed because the Mac was too busy"],
  [/^check\b.*\bSKIP\b/i, () => "A check was skipped while it waited for an update"],
  [/^check\b.*\b(fail|failed)\b/i, () => "A check failed"],
  [/^git push\b.*\b(rejected|non-fast-forward)/i, () => "Sending code was rejected: someone else sent theirs first"],
  [/merge conflict/i, () => "Two changes clashed (a merge conflict)"],
  [/out of memory|\bOOM\b|SIGKILL/i, () => "A build ran out of memory"],
  [/device offline|no devices? (found|attached)|device not found/i, () => "The phone dropped its connection"],
  [/\btime(d)? ?out\b/i, () => "Something timed out"],
];

/** Raw tokens that mean nothing to the user: hashes, exit codes, ids, paths, file names, flags, quoted code. */
function scrub(t: string) {
  return t
    .replace(/`[^`]*`/g, " ")
    .replace(/\b[0-9a-f]{7,40}\b/gi, " ")
    .replace(/\brc\s*\d+\b/gi, " ")
    .replace(/\b[A-Z][A-Z0-9_]+=\S*/g, " ")
    .replace(/\b[fx]\d+\b/g, " ")
    .replace(/\S*[/\\]\S*/g, " ")
    .replace(/\S+\.(sh|py|ts|tsx|mjs|js|rs|json|jpg|png|log|md|css|html|toml|yml|yaml)\b/gi, " ")
    .replace(/(^|\s)--?[a-z][\w-]*/gi, " ")
    .replace(/\(\s*[^a-z]*\)/gi, " ")
    .replace(/\s+([,.;:)])/g, "$1")
    .replace(/\s{2,}/g, " ")
    .trim();
}

/** A line that starts as a command (a tool's name or a path into the repo). */
const CMD = /^(adb|git|bin\/\S*|tools\/\S*|apps\/\S*|shell\/\S*|npm|npx|node|python3?|bash|sh|cd|sudo|su|docker|ssh|scp|rsync|make|cargo)\b\s*/i;

/** The line a title's words make: before the first ":" or " - " (what follows is the tool's output) - unless that is a
 * command line ("adb shell ...: device offline"): then what follows. A short head ("Coordinator briefs: ...") takes
 * the next clause with it. [tail]: the line came from after a command. */
function lineOf(raw: string): { line: string; tail: boolean } {
  const [first, ...rest] = raw.split(/:\s|\s[-–]\s/);
  if (CMD.test(first.trim())) {
    const tail = rest.length ? scrub(rest.join(": ")) : "";
    return tail ? { line: tail, tail: true } : { line: scrub(first.trim().replace(CMD, "")), tail: false };
  }
  const short = rest.length > 0 && first.trim().split(/\s+/).length < 3;
  return { line: scrub(short ? `${first}: ${rest[0]}` : first), tail: false };
}

/** One plain line for a logged friction title: a known meaning, else the title without its raw tokens. */
export function plainTitle(f: Pick<FrictionRow, "title" | "kind">) {
  const raw = (f.title || "").trim();
  const known = PLAIN.find(([re]) => re.test(raw));
  if (known) return known[1](raw);
  const { line, tail } = lineOf(raw);
  const clean = line.replace(/[,.;:]+$/, "").replace(/\s+(in|on|of|for|to|at|with|the|a|an|and|by|from)$/i, "").trim();
  const words = clean.split(/\s+/).filter((w) => /[a-z]{2}/i.test(w));
  return words.length < (tail ? 2 : 3) ? kindName(f.kind) : cap(clean);
}

const num = (v: bigint | number | undefined) => Number(v || 0);
const sevOf = (score: number) => (score >= P0_AT ? 2 : score >= P1_AT ? 1 : 0);

/** Problems with the same plain line in one area: one row. */
export interface Problem {
  key: string;
  area: string;
  title: string;
  rows: FrictionRow[];
  count: number;
  last: number;
  first: number;
  sev: number;
  /** "open" | "fixing" (a board task an agent has) | "fixed". */
  state: "open" | "fixing" | "fixed";
  task?: WorkRow;
}

/** [f] added to its problem in [m] (a new one if none): counts, times, and the board task it is evidence for. */
function addRow(m: Map<string, Problem>, f: FrictionRow, byId: Map<string, WorkRow>) {
  const fixed = f.status === "fixed";
  const title = plainTitle(f);
  const key = `${fixed ? "x" : "o"}|${f.area}|${title}`;
  const p: Problem = m.get(key) ?? { key, area: f.area, title, rows: [], count: 0, last: 0, first: Infinity, sev: 0, state: fixed ? "fixed" : "open" };
  p.rows.push(f);
  p.count += f.count;
  p.last = Math.max(p.last, (fixed && num(f.fixedAt)) || num(f.last));
  p.first = Math.min(p.first, num(f.first) || num(f.last));
  m.set(key, p);
  linkTask(p, byId.get(f.task || ""), fixed);
}

/** The board task a report is evidence for: its severity counts, and an agent on it means "being fixed". */
function linkTask(p: Problem, t: WorkRow | undefined, fixed: boolean) {
  if (!t) return;
  p.sev = Math.max(p.sev, num(t.severity));
  if (!fixed && t.status !== "done") (p.state = "fixing"), (p.task = t);
}

/** The friction rows as problems: merged by area and plain line, worst first. */
export function problems(rows: FrictionRow[], tasks: WorkRow[]): Problem[] {
  const byId = new Map(tasks.map((w) => [w.id, w]));
  const m = new Map<string, Problem>();
  for (const f of rows) addRow(m, f, byId);
  const all = [...m.values()];
  for (const p of all) p.sev = Math.max(p.sev, sevOf(p.count));
  return all.sort((a, b) => b.sev - a.sev || b.count - a.count || b.last - a.last);
}

/** Open problems per area, the area with the worst first. */
function byArea(ps: Problem[]) {
  const m = new Map<string, Problem[]>();
  for (const p of ps) m.set(areaName(p.area), [...(m.get(areaName(p.area)) ?? []), p]);
  // ps is sorted worst first, so each area's first row is its worst and the map's order is the worst-first order.
  return [...m.entries()];
}

const STATE: Record<Problem["state"], [string, string]> = {
  open: ["stuck", "open"],
  fixing: ["working", "being fixed"],
  fixed: ["check", "fixed"],
};

const when = (ms: number) => {
  if (!ms) return "";
  const a = ago(ms / 1000);
  return a === "now" ? "just now" : `${a} ago`;
};
const times = (n: number) => `${n}×`;

/** A P0/P1 chip (the board's .ais-sev; none below P1). */
function Sev({ s }: { s: number }) {
  if (!s) return null;
  return <span class={`ais-sev p${2 - s}`}>{s >= 2 ? "P0" : "P1"}</span>;
}

/** How often and when, what kind, who is on it, the fix. */
function Facts({ p }: { p: Problem }) {
  const fix = p.rows.find((r) => r.fixCommit || r.fixNote);
  const back = p.rows.reduce((n, r) => n + num(r.reopened), 0);
  const first = Number.isFinite(p.first) && p.first ? `, first ${when(p.first)}` : "";
  const last = when(Math.max(...p.rows.map((r) => num(r.last))));
  const fixed = fix && `Fixed${fix.fixCommit ? ` in ${fix.fixCommit.slice(0, 9)}` : ""}${fix.fixNote ? `: ${fix.fixNote}` : ""}`;
  return (
    <>
      <div class="ais-done-fact">
        Happened {times(p.count)}
        {first}, last {last}
      </div>
      <div class="ais-done-fact">{[...new Set(p.rows.map((r) => kindName(r.kind)))].join(", ")}</div>
      {p.task && <div class="ais-done-fact">Being fixed: {p.task.title}</div>}
      {fixed && <div class="ais-done-fact">{fixed}</div>}
      {back > 0 && <div class="ais-done-fact">Came back {times(back)} after a fix</div>}
    </>
  );
}

/** The logged words of each merged report, and the latest one's story, repro and evidence. */
function Logged({ p }: { p: Problem }) {
  const f = [...p.rows].sort((a, b) => num(b.last) - num(a.last))[0];
  return (
    <>
      <div class="afr-raw-h">What was logged</div>
      <ul class="afr-raw">
        {p.rows.slice(0, 5).map((r) => (
          <li key={r.id}>
            {r.title} <span class="afr-raw-n">({times(r.count)}, {r.id})</span>
          </li>
        ))}
        {p.rows.length > 5 && <li>and {p.rows.length - 5} more like it</li>}
      </ul>
      {f.details && f.details !== f.title && <div class="afr-raw-p">{f.details}</div>}
      {f.repro && <div class="afr-raw-h">How to make it happen again</div>}
      {f.repro && <div class="afr-raw-p">{f.repro}</div>}
      {f.evidence && <div class="afr-raw-p">Evidence: {f.evidence}</div>}
    </>
  );
}

/** The raw facts behind a problem, shown on a tap; an open one can be handed to the manager. */
function Detail({ p }: { p: Problem }) {
  const ask = () => askQueued(`Please fix the friction "${p.title}" (${p.rows.map((r) => r.id).join(", ")}): it happened ${p.count} times.`);
  return (
    <div class="ais-done-detail afr-detail">
      <Facts p={p} />
      <Logged p={p} />
      {p.state === "open" && (
        <button type="button" class="ais-open-chat afr-ask" onClick={ask}>
          Ask the manager to fix it
        </button>
      )}
    </div>
  );
}

/** One problem: chip, plain line, how often; its state and when under it. A tap opens the details. */
function ProblemRow({ p, open, onToggle }: { p: Problem; open: boolean; onToggle: () => void }) {
  const [dot, label] = STATE[p.state];
  return (
    <li class={`ais-done-item afr-item${open ? " open" : ""}`} data-sev={p.sev} data-state={p.state}>
      <button type="button" class="afr-row" aria-expanded={open} onClick={onToggle}>
        <span class="afr-line">
          <Sev s={p.sev} />
          <span class="afr-title">{p.title}</span>
          <span class="ais-n afr-n" aria-label={`happened ${p.count} times`}>
            {times(p.count)}
          </span>
        </span>
        <span class="afr-facts">
          <span class={`aip-dot ${dot}`} aria-hidden="true" />
          {label}
          {p.last ? ` · ${p.state === "fixed" ? "" : "last "}${when(p.last)}` : ""}
        </span>
      </button>
      <Reveal open={open}>
        <Detail p={p} />
      </Reveal>
    </li>
  );
}

/** One area's card: its name and count, its problems worst first, the rest behind "N more". */
function Area({ name, ps, openKey, tap, folded = false }: { name: string; ps: Problem[]; openKey: string | null; tap: (k: string) => void; folded?: boolean }) {
  const [open, setOpen] = useState(!folded);
  const [all, setAll] = useState(false);
  const shown = all ? ps : ps.slice(0, AREA_ROWS);
  return (
    <section class="ais-sec tile afr-sec" aria-label={name}>
      <h3 class="ais-h">
        <button type="button" class="ais-toggle" aria-expanded={open} onClick={() => setOpen(!open)}>
          {name}
          <span class="ais-n">{ps.length}</span>
          <span class="ais-chev" aria-hidden="true" />
        </button>
      </h3>
      <Reveal open={open}>
        <ul class="ais-list">
          {shown.map((p) => (
            <ProblemRow key={p.key} p={p} open={openKey === p.key} onToggle={() => tap(p.key)} />
          ))}
          {ps.length > shown.length && (
            <li>
              <button type="button" class="ais-more" onClick={() => setAll(true)}>
                {ps.length - shown.length} more
              </button>
            </li>
          )}
        </ul>
      </Reveal>
    </section>
  );
}

/** The page: open problems per area (the worst area first), then what was fixed this week, folded. */
export function FrictionPage() {
  const [openKey, setOpenKey] = useState<string | null>(null);
  const tap = (k: string) => setOpenKey(openKey === k ? null : k);
  const now = Date.now();
  const recent = friction.value.filter((f) => f.status === "open" || (f.status === "fixed" && now - num(f.fixedAt) < FIXED_MS));
  const ps = problems(recent, board.value);
  const open = ps.filter((p) => p.state !== "fixed");
  const fixed = ps.filter((p) => p.state === "fixed").sort((a, b) => b.last - a.last);
  if (!friction.value.length && !boardSeen.value) return <div class="ais-empty tile afr-empty">Loading…</div>;
  return (
    <div class="afr">
      {!open.length && <div class="ais-empty tile afr-empty">Nothing is getting in the way right now.</div>}
      {byArea(open).map(([name, list]) => (
        <Area key={name} name={name} ps={list} openKey={openKey} tap={tap} />
      ))}
      {fixed.length > 0 && <Area name="Fixed recently" ps={fixed} openKey={openKey} tap={tap} folded={true} />}
    </div>
  );
}
