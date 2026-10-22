/**
 * The Agents view's data (docs/AGENTS-VIEW-DESIGN.md §3-§5): which agents run, on which host, their subagents, tasks,
 * events and the comms between them - from one AgentsSource per backend, folded into a signal per agent, so a line
 * redraws only when its own agent changed.
 *
 * Phase 1's source is the spool (powos-agentsd), through the host (AgentsSpool.kt). Phase 2's is SpacetimeDB: the same
 * rows and deltas (types.ts Agent ... AgentsDelta), another AgentsSource - nothing below it changes.
 *
 * Subscribed only while something shows it (the home widget, the Agents screen) and the page is visible: hidden, the
 * host sends nothing; shown again, one snapshot.
 */
import { signal, type Signal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import { powos } from "./bridge.ts";
import type { Agent, AgentAsk, AgentEvent, AgentMessage, AgentTask, AgentsDelta } from "./types.ts";

/** What a view subscribes to (§4 The backend swap). */
export interface AgentsSource {
  subscribe(onDelta: (d: AgentsDelta) => void): () => void;
}

/** Phase 1: the spool, through the host - everything now, then only what changed. */
export const spoolSource: AgentsSource = {
  subscribe(onDelta) {
    const off = powos.on("agents.delta", onDelta);
    powos.agents.snapshot().then(onDelta, () => {});
    return () => {
      off();
      powos.agents.unsubscribe();
    };
  },
};

const rows = new Map<string, Signal<Agent>>();
/** The session agents (not subagents) to list, in the widget's order: needs you, working, blocked, idle; then latest. */
export const sessions = signal<string[]>([]);
/** Every agent's id (subagents too): the screen's tree. */
export const agentIds = signal<string[]>([]);
export const tasks = signal<Map<string, AgentTask[]>>(new Map());
/** The comms feed, oldest first (the host keeps the last 50). */
export const messages = signal<AgentMessage[]>([]);
export const asks = signal<AgentAsk[]>([]);
/** The watched agent's recent events (useAgentEvents). */
export const recent = signal<{ agent: string | null; events: AgentEvent[] }>({ agent: null, events: [] });
/** Subscribed (the header's "live"). */
export const live = signal(false);
/** A slow clock for "12s ago" while subscribed: 30 s, not a frame. */
export const tick = signal(0);

export const agent = (id: string) => rows.get(id);
export const isSub = (a: Agent) => a.id.includes("/");

const RANK: Record<Agent["state"], number> = { needs_you: 0, working: 1, blocked: 2, paused: 3, idle: 4, gone: 5 };

/** An agent's parent's id: a row id, or "@role" - that role's live agent (the manager), latest first. */
export function parentOf(a: Agent): string | null {
  const p = a.parent;
  if (!p) return null;
  if (!p.startsWith("@")) return rows.has(p) ? p : null;
  let best: Agent | null = null;
  for (const s of rows.values()) {
    const r = s.value;
    if (r.role === p.slice(1) && !isSub(r) && r.id !== a.id && r.state !== "gone" && (!best || r.last > best.last))
      best = r;
  }
  return best?.id ?? null;
}

function order() {
  const all = [...rows.values()].map((s) => s.value);
  const tops = all
    .filter((a) => !isSub(a) && a.state !== "gone")
    .sort((a, b) => RANK[a.state] - RANK[b.state] || b.last - a.last)
    .map((a) => a.id);
  if (tops.join("\n") !== sessions.value.join("\n")) sessions.value = tops;
  const ids = all.map((a) => a.id);
  if (ids.join("\n") !== agentIds.value.join("\n")) agentIds.value = ids;
}

function apply(d: AgentsDelta) {
  if (d.full) {
    const keep = new Set((d.agents ?? []).map((a) => a.id));
    for (const id of [...rows.keys()]) if (!keep.has(id)) rows.delete(id);
  }
  for (const a of d.agents ?? []) {
    const s = rows.get(a.id);
    if (!s) rows.set(a.id, signal(a));
    else if (JSON.stringify(s.value) !== JSON.stringify(a)) s.value = a;
  }
  for (const id of d.gone ?? []) rows.delete(id);
  if (d.full || d.tasksOf) {
    const next = d.full ? new Map<string, AgentTask[]>() : new Map(tasks.value);
    for (const id of d.tasksOf ?? []) next.delete(id);
    for (const t of d.tasks ?? []) next.set(t.agent, [...(next.get(t.agent) ?? []), t]);
    for (const l of next.values()) l.sort((a, b) => a.order - b.order);
    tasks.value = next;
  }
  if (d.full) messages.value = d.messages ?? [];
  else if (d.messages?.length) {
    const have = new Set(messages.value.map((m) => m.id));
    messages.value = [...messages.value, ...d.messages.filter((m) => !have.has(m.id))].slice(-50);
  }
  if (d.full || d.asks) asks.value = d.asks ?? [];
  if (d.eventsOf && d.eventsOf === recent.value.agent) recent.value = { agent: d.eventsOf, events: d.events ?? [] };
  if (d.full || d.agents || d.gone) order();
}

// Subscribed while something shows it and the page is visible.
let users = 0;
let off: (() => void) | null = null;
let clock = 0;
function sync() {
  const want = users > 0 && document.visibilityState !== "hidden";
  if (want && !off) {
    off = spoolSource.subscribe(apply);
    live.value = true;
    clock = window.setInterval(() => tick.value++, 30_000);
  } else if (!want && off) {
    off();
    off = null;
    live.value = false;
    clearInterval(clock);
  }
}
document.addEventListener("visibilitychange", sync);

/** The agents, kept current while the calling component shows. */
export function useAgents() {
  useEffect(() => {
    users++;
    sync();
    return () => {
      users--;
      sync();
    };
  }, []);
}

/** [id]'s recent events in `recent` while the calling component shows it (one agent at a time). */
export function useAgentEvents(id: string | null) {
  useEffect(() => {
    recent.value = { agent: id, events: [] };
    if (!id) return;
    powos.agents.events(id);
    return () => {
      if (recent.value.agent === id) recent.value = { agent: null, events: [] };
      powos.agents.events(null);
    };
  }, [id]);
}

/** The Agents screen: open (on an agent, or none picked) or not. */
export const agentsView = signal<{ id: string | null } | null>(null);
export const openAgents = (id: string | null = null) => (agentsView.value = { id });
export const closeAgents = () => (agentsView.value = null);

/** "12s", "4m", "2h": how long since [ms] (Unix ms). */
export function since(ms: number) {
  void tick.value;
  const s = Math.max(0, (Date.now() - ms) / 1000);
  if (s < 60) return `${Math.floor(s)}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86400) return `${Math.floor(s / 3600)}h`;
  return `${Math.floor(s / 86400)}d`;
}

/**
 * A board task's state as the user should read it (the user, 2026-10-22: idle tasks showed "working"): "working" only
 * while a LIVE agent holds it - one whose `work` is the task (its own `task set <id> --step/--progress` calls,
 * powos-agentsd), else a live agent of the owner's role holding nothing else. Without one: "awaiting check" (the
 * verify queue's marker), "stalled" (started, nothing for STALL_MS) or "queued". Live = working or needs you, heard
 * from within agentsd's own 30-minute staleness (a mirror that stopped).
 */
export type BoardState = "working" | "queued" | "awaiting check" | "stalled";
export interface BoardTask {
  id: string;
  owner: string;
  step?: string;
  steps?: string;
  commits?: string;
  progressTotal?: number;
  activity?: bigint | number;
  updated: bigint | number;
}
export const STALL_MS = 20 * 60_000;
const LIVE_MS = 30 * 60_000;
const isLive = (a: Agent) => (a.state === "working" || a.state === "needs_you") && Date.now() - a.last < LIVE_MS;
const movedAt = (w: BoardTask) => Number(w.activity) || Number(w.updated);
/** Bumped at the next stall boundary (useStallClock): the only timer. */
const stallClock = signal(0);

export function holder(w: BoardTask): Agent | null {
  let byRole: Agent | null = null;
  for (const id of agentIds.value) {
    const a = rows.get(id)?.value;
    if (!a || !isLive(a)) continue;
    if (a.work === w.id) return a;
    if (!a.work && w.owner && w.owner !== "coder" && a.role === w.owner) byRole = a;
  }
  return byRole;
}

export function boardState(w: BoardTask, checkQueued: boolean): BoardState {
  if (holder(w)) return "working";
  if (checkQueued) return "awaiting check";
  void stallClock.value;
  return started(w) && Date.now() - movedAt(w) >= STALL_MS ? "stalled" : "queued";
}

/** Someone began it: a step, a bar, steps or commits. */
const started = (w: BoardTask) => !!w.step || (w.progressTotal ?? 0) > 0 || [w.steps, w.commits].some((j) => !!j && j !== "[]");

/** One timeout to the nearest moment one of [open] tasks turns stalled; nothing at rest. */
export function useStallClock(open: BoardTask[]) {
  const n = stallClock.value;
  useEffect(() => {
    const now = Date.now();
    const next = Math.min(...open.map((w) => movedAt(w) + STALL_MS).filter((t) => t > now));
    if (!Number.isFinite(next)) return;
    const t = window.setTimeout(() => stallClock.value++, next - now + 50);
    return () => clearTimeout(t);
  }, [open, n]);
}

/** A state's mark (§1.1): working ●, idle ◐ (○ after 10 minutes), blocked ■, needs you !, paused ⏸, done ✓. */
export function mark(a: Agent) {
  switch (a.state) {
    case "working":
      return "●";
    case "needs_you":
      return "!";
    case "blocked":
      return "■";
    case "paused":
      return "⏸";
    case "gone":
      return "✓";
    default:
      return Date.now() - a.last > 600_000 ? "○" : "◐";
  }
}
