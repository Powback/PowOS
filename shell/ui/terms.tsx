/**
 * The terminals (tmux sessions) of PowOS and every host it has a link to (`powos terms list`, "ai.sessions" /
 * "ai.hosts"), and the ways in from the AI page (the user, 11-01 16:57: "There's no terminal option anymore"): one
 * session's row (a tap opens its terminal, view-only until taken over: session.tsx), a host's sessions (the Devices
 * tab's device cards, units.tsx), an agent's own terminal (the Agents tab's "Open terminal", agents.tsx). aimenu.tsx's
 * Agents & terminals lists them per host.
 */
import { useEffect } from "preact/hooks";
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import { openSession, sessionView } from "../state.ts";
import type { Agent, AgentHost, AgentSession } from "../types.ts";
import { ago } from "./time.ts";

export const sessions = signal<AgentSession[]>([]);
/** The hosts the sessions come from (`powos terms list`); empty from a PowOS without it (its own tmux only). */
export const hosts = signal<AgentHost[]>([]);
powos.on("ai.sessions", (s: AgentSession[]) => (sessions.value = s));
powos.on("ai.hosts", (h: AgentHost[]) => (hosts.value = h));

/** How often the sessions are listed again while something showing them is on screen. */
const REFRESH_MS = 5000;

/** Claude Code titles its pane with a braille spinner frame while it works (and a mark when it's done). */
export const working = (s: AgentSession) => /^[⠀-⣿]/.test(s.title);
export const task = (s: AgentSession) => s.title.replace(/^[⠀-⣿✳*·\s]+/, "") || s.command;
const folder = (path: string) => path.split("/").filter(Boolean).at(-1) ?? "~";

/** This PowOS's own host name ("installed & running"'s), "" before `powos terms list` named it. */
export const localHost = () => hosts.value.find((h) => h.via === "local")?.host ?? "";
/** The host a session runs on (its own tmux's: this host). */
export const hostOf = (s: AgentSession) => s.host ?? localHost();

/** The sessions, read when [shown] comes true and every few seconds while it stays (not while the page is hidden). */
export function useSessions(shown: boolean) {
  useEffect(() => {
    if (!shown) return;
    const ask = () => document.hidden || powos.ai.sessions();
    ask();
    const timer = window.setInterval(ask, REFRESH_MS);
    document.addEventListener("visibilitychange", ask);
    return () => {
      clearInterval(timer);
      document.removeEventListener("visibilitychange", ask);
    };
  }, [shown]);
}

/** Opens [s]'s terminal from [card] (view-only; an agent's until taken over). */
export function openTerm(s: AgentSession, card: HTMLElement | null) {
  const local = !s.host || s.host === localHost();
  openSession(s.name, card, task(s), { host: s.host, local, agent: s.agent ?? working(s) });
}

/** One session: its task, a dot while it works, name / windows / command / folder / when; a tap opens its terminal. */
export function SessionRow({ s }: { s: AgentSession }) {
  const open = sessionView.value;
  return (
    <button
      type="button"
      class={`ai-session tile ${open?.name === s.name && (open.host ?? "") === (s.host ?? "") ? "opened" : ""}`}
      data-term={`${hostOf(s)}:${s.name}`}
      onClick={(e) => openTerm(s, e.currentTarget as HTMLElement)}
    >
      <span class={`ai-dot ${working(s) ? "on" : ""}`} />
      <span class="ai-session-main">
        <span class="ai-session-task">
          {s.agent && <span class="ai-session-agent">agent · </span>}
          {task(s)}
        </span>
        <span class="ai-session-meta muted">
          {s.name}
          {s.windows && s.windows > 1 ? ` · ${s.windows} windows` : ""} · {s.command} · {folder(s.path)} · {ago(s.activity)}
        </span>
      </span>
    </button>
  );
}

/** [host]'s sessions, working agents first, then agents, then the latest. */
export function sessionsOn(host: string) {
  return sessions.value
    .filter((s) => hostOf(s) === host)
    .sort((a, b) => Number(working(b)) - Number(working(a)) || Number(!!b.agent) - Number(!!a.agent) || b.activity - a.activity);
}

/** A device card's terminals (the Devices tab, units.tsx): its sessions, each a tap into its terminal; none: nothing. */
export function HostSessions({ host }: { host: string }) {
  const list = sessionsOn(host);
  if (!list.length) return null;
  return (
    <div class="ai-host-terms" aria-label={`${host} terminals`}>
      {list.map((s) => (
        <SessionRow key={`${host}:${s.name}`} s={s} />
      ))}
    </div>
  );
}

/**
 * The session [a] runs in: an agent's session on its host whose folder is the agent's (newest first).
 * HACK: matched by host and working directory - `powos terms list` names no pid and powos-agentsd no tmux session.
 * Real fix: powos-agentsd records the agent's $TMUX_PANE session, and this matches on it.
 */
export function termOf(a: Agent): AgentSession | null {
  const same = (p: string) => !!a.cwd && (p === a.cwd || p.endsWith(`/${a.cwd}`));
  const cands = sessions.value.filter((s) => (s.agent ?? working(s)) && same(s.path)).sort((x, y) => y.activity - x.activity);
  return cands.find((s) => hostOf(s) === a.host) ?? (cands.length === 1 ? cands[0] : null);
}

/** An agent card's "Open terminal" (agents.tsx): its session's terminal; no session found: no button. */
export function TermButton({ a }: { a: Agent }) {
  const s = termOf(a);
  if (!s) return null;
  return (
    <button
      type="button"
      class="ag-act fl-term-open"
      onClick={(e) => {
        e.stopPropagation();
        openTerm(s, (e.currentTarget as HTMLElement).closest(".fl-card"));
      }}
    >
      Open terminal
    </button>
  );
}
