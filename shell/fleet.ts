/**
 * The agent fleet in plain words: one model for the Agents screen and the home widget (ui/agents.tsx). Each agent is
 * mapped to the board task it is on, so a line says the task ("Media card redesign"), how far along it is (step 3 of
 * 7, from the board's --plan/--step) and what it's doing now, never a session's raw label.
 *
 * The session ↔ task link is the agent row's `work` (powos-agentsd): set by the agent's own `powos agents task set
 * <id> --step/--plan/--progress/--commit` calls, and for a helper (subagent) by the board slug its prompt names. The
 * task's words come from the board (STDB powos-agents `work`, fed into [workRows] by ui/agents.tsx BoardFeed while
 * something shows the fleet and an agent holds a task).
 *
 * Groups: working (doing something now), attention (errored, stuck, asking, or waiting on a phone check), the manager
 * (its own row), and the rest folded: idle sessions, sessions done today, and anything older than a day.
 */
import { signal } from "@preact/signals";
import { agent, agentIds, asks, isSub, QUEUED_STEP } from "./agents.ts";
import type { Agent } from "./types.ts";

/** The board columns the fleet reads (powai.tsx WorkRow's). */
export interface WorkLite {
  id: string;
  title: string;
  owner: string;
  status: string;
  progressDone?: number;
  progressTotal?: number;
  step?: string;
  /** JSON: [{text, state: "done" | "current" | "next"}] in order. */
  steps?: string;
}
export type Step = { text: string; state: "done" | "current" | "next" };

/** The board's tasks by id. */
export const workRows = signal<Map<string, WorkLite>>(new Map());

export interface Worker {
  a: Agent;
  /** What it's on, in plain words: its board task's title, else the best words the session has. */
  title: string;
  /** Step [done + 1] of [total] (total 0: the task has no plan). */
  done: number;
  total: number;
  /** What it's doing now, one short sentence. */
  now: string;
  /** Attention only: why, plainly ("Can't start: model not found"), and the one thing to do. */
  reason?: string;
  /** answer: an ask is open (allow it in place; the screen has deny + tell). */
  action?: "restart" | "open" | "answer";
  task?: WorkLite;
}

export interface Fleet {
  working: Worker[];
  attention: Worker[];
  manager: Worker | null;
  idle: Agent[];
  doneToday: Agent[];
  older: Agent[];
}

const DAY_MS = 24 * 3_600_000;
/** A working agent that said nothing for this long is stuck (powos-agentsd's own staleness is 30 minutes). */
const STUCK_MS = 30 * 60_000;
const MANAGER = new Set(["manager"]);

/** Known failures, as the user should read them. */
const ERRORS: [RegExp, string][] = [
  [/model_not_found|model not found/i, "Can't start: model not found"],
  [/rate.?limit|429|usage limit/i, "Hit the usage limit"],
  [/overloaded|529/i, "The model is overloaded"],
  [/401|unauthori[sz]ed|invalid.?api.?key|credentials|oauth/i, "Signed out: needs a new login"],
  [/context.?(length|window)|prompt is too long/i, "Ran out of room: its context is full"],
  [/ECONNREFUSED|network|timed? ?out/i, "Lost its connection"],
];

/** A board task by the id an agent named (exact, else a unique prefix: `task set` takes those too). */
export function taskOf(id: string | undefined): WorkLite | undefined {
  if (!id) return undefined;
  const rows = workRows.value;
  const exact = rows.get(id);
  if (exact) return exact;
  let hit: WorkLite | undefined;
  for (const [k, w] of rows) {
    if (!k.startsWith(id)) continue;
    if (hit) return undefined;
    hit = w;
  }
  return hit;
}

/** A JSON-array column ("" or bad: none). */
export function stepsOf(w: WorkLite | undefined): Step[] {
  try {
    const v = JSON.parse(w?.steps || "[]");
    return Array.isArray(v) ? v.filter((s) => s && typeof s.text === "string" && s.text.trim()) : [];
  } catch {
    return [];
  }
}

/** Sentence case, single spaces. */
const plain = (s: string) => {
  const t = s.replace(/\s+/g, " ").trim();
  return t ? t[0].toUpperCase() + t.slice(1) : "";
};

/** "Wrap up …" at [n] characters, cut at a word. */
export function shorten(s: string, n: number) {
  if (s.length <= n) return s;
  const cut = s.slice(0, Math.max(1, n - 1));
  const at = cut.lastIndexOf(" ");
  return `${(at > n * 0.5 ? cut.slice(0, at) : cut).replace(/[\s,.;:-]+$/, "")}…`;
}

/** A session label that says nothing to the user: a raw tag, a state word, an error code, a path. */
const RAW = /^(<[^>]*>?|<.*|idle|working|done|blocked|[a-z]+(_[a-z]+)+|\S+\/\S+)$/i;
/** Wrappers the hooks put before a prompt ("[inbox message from agent 'coordinator' (normal)]: …"). */
const WRAPPER = /^\[[^\]]*\]:?\s*/;

/** The best plain words a session has for what it's on ("" if none). */
export function ownWords(a: Agent) {
  const t = (a.title || "").replace(WRAPPER, "").trim();
  if (!t || RAW.test(t) || t.startsWith("<")) return "";
  return plain(t);
}

/** What the tool step says, as a sentence ("Bash final renders" → "Final renders"; "Grep" → "Searching the code"). */
export function stepWords(step: string) {
  const s = (step || "").trim();
  if (!s || s.startsWith("<")) return "";
  if (/^mcp__comms__send/i.test(s)) return "Messaging another agent";
  if (/^mcp__/i.test(s)) return "Using a tool";
  const m = s.match(/^(Bash|Read|Edit|Write|Grep|Glob|Task|Agent|WebFetch|WebSearch)\b\s*(.*)$/);
  if (!m) return plain(s);
  const rest = m[2];
  switch (m[1]) {
    case "Bash":
      return rest ? plain(rest) : "Running a command";
    case "Read":
      return rest ? `Reading ${rest}` : "Reading a file";
    case "Edit":
    case "Write":
      return rest ? `Editing ${rest}` : "Editing a file";
    case "Grep":
    case "Glob":
      return "Searching the code";
    case "WebFetch":
    case "WebSearch":
      return "Looking something up online";
    default:
      return rest ? `Starting a helper: ${rest}` : "Starting a helper";
  }
}

/** Why [a] needs the user, plainly, and what to do ("" : it doesn't). */
function trouble(a: Agent, w: WorkLite | undefined, now: number): Pick<Worker, "reason" | "action"> | null {
  const text = `${a.step} ${a.title} ${a.report}`;
  const err = a.state === "blocked" || a.state === "idle" || a.state === "paused" ? ERRORS.find(([rx]) => rx.test(text)) : undefined;
  if (err) return { reason: err[1], action: "restart" };
  if (a.state === "needs_you") {
    const ask = asks.value.find((x) => x.agent === a.id && x.answer == null);
    return { reason: ask ? `Wants to ${ask.tool === "Bash" ? "run a command" : `use ${ask.tool}`}` : "Waiting for your answer", action: ask ? "answer" : "open" };
  }
  if (a.state === "blocked") return { reason: "Stuck: its last tries kept failing", action: "restart" };
  if (a.state === "working" && now - a.last > STUCK_MS) return { reason: "Quiet for over 30 minutes", action: "open" };
  if (a.state === "idle" && w && w.status !== "done" && w.step === QUEUED_STEP) return { reason: "Waiting for its phone check", action: "open" };
  return null;
}

/** [a] as a fleet line: task words, progress and its step now. */
function workerOf(a: Agent): Worker {
  const w = taskOf(a.work);
  const total = w?.progressTotal ?? 0;
  const done = Math.min(w?.progressDone ?? 0, total);
  const boardStep = w?.step && w.step !== QUEUED_STEP ? plain(w.step) : "";
  const title = w?.title ? plain(w.title) : ownWords(a) || `${plain(a.role)} session in ${a.cwd || a.host}`;
  // Its live tool step while working (what it does this second), the board's step otherwise.
  const live = a.state === "working" ? stepWords(a.step) : "";
  return { a, title, done, total, now: live || boardStep, task: w };
}

/** The manager's row: what it is doing, in plain words. */
function managerWords(a: Agent): string {
  const s = stepWords(a.step);
  const asked = (a.title || "").replace(WRAPPER, "").trim();
  if (a.state === "working") {
    if (/^Messaging/.test(s)) return "Handing out work to the agents";
    if (/agents task/.test(a.step)) return "Updating the board";
    if (asked && !RAW.test(asked)) return `Answering you: “${shorten(asked, 60)}”`;
    return s || "Thinking";
  }
  if (a.state === "needs_you") return "Waiting for your answer";
  return "Waiting for your next message";
}

/** The whole fleet, grouped (reads the agent signals: a component calling it redraws when they change). */
export function fleet(now = Date.now()): Fleet {
  const all = agentIds.value.map((id) => agent(id)?.value).filter((a): a is Agent => !!a);
  const out: Fleet = { working: [], attention: [], manager: null, idle: [], doneToday: [], older: [] };
  // A session whose helpers are working is shown by them (each is one piece of work); the session itself is not.
  const busyParents = new Set(all.filter((a) => isSub(a) && a.state === "working").map((a) => a.parent));
  for (const a of all) {
    const sub = isSub(a);
    if (!sub && MANAGER.has(a.role)) {
      if (!out.manager || a.last > out.manager.a.last) out.manager = { ...workerOf(a), now: managerWords(a) };
      continue;
    }
    if (a.state === "gone") {
      if (now - a.last < DAY_MS) out.doneToday.push(a);
      continue;
    }
    const w = taskOf(a.work);
    const t = trouble(a, w, now);
    const fresh = now - a.last < DAY_MS;
    if (t && (fresh || a.state === "needs_you")) {
      out.attention.push({ ...workerOf(a), ...t });
      continue;
    }
    if (!sub && busyParents.has(a.id)) continue;
    if (a.state === "working") {
      out.working.push(workerOf(a));
      continue;
    }
    if (sub) continue;
    if (!fresh) out.older.push(a);
    else out.idle.push(a);
  }
  const recent = (x: { a: Agent }, y: { a: Agent }) => y.a.last - x.a.last;
  out.working.sort(recent);
  out.attention.sort(recent);
  out.idle.sort((x, y) => y.last - x.last);
  out.doneToday.sort((x, y) => y.last - x.last);
  out.older.sort((x, y) => y.last - x.last);
  return out;
}

/** "3 working · 1 needs you", the widget's and the screen's head. */
export function headline(f: Fleet) {
  const parts = [`${f.working.length} working`];
  if (f.attention.length) parts.push(`${f.attention.length} need${f.attention.length === 1 ? "s" : ""} you`);
  return parts.join(" · ");
}

/** The one action on an attention line. Restart: the manager restarts it (no agent restarts itself from here). */
export function restartNote(x: Worker) {
  return `Please restart the ${x.a.role} agent on ${x.a.host}${x.task ? ` (task ${x.task.id})` : ""}: ${x.reason}.`;
}
