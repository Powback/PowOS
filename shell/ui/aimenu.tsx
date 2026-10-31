/**
 * What PowOS AI's ⋯ menu opens (powai.tsx AiHeader), each its own screen with back: Progress (the powos-progress app's
 * page where it's installed; else a short summary per area - the things to try come in the chat, aiboard.tsx's board
 * list with its works / still broken rows is gone from here: the user rejected it, 2026-10-31), Agents & terminals (the agents view
 * - tree, tasks, tools, comms - and the tmux sessions of PowOS and every host it has a link to, grouped per host by the
 * names "installed & running" uses, each with the task its pane's title names, a spinner's mark while it works, its
 * agent marked; a tap opens its terminal, view-only until taken over), Devices (installed & running per host),
 * Friction (what keeps getting in the agents' way).
 */
import { Component, type ComponentType } from "preact";
import { useEffect, useState } from "preact/hooks";
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import { openSession, sessionView } from "../state.ts";
import { openAgents } from "../agents.ts";
import { installedApps, manifestOf, moduleUrl } from "../apps/pages.ts";
import { host as appHost } from "../apps/stdb.ts";
import type { AgentHost, AgentSession } from "../types.ts";
import { ago } from "./time.ts";
import { HOSTS, Units } from "./units.tsx";
import { Friction, WorkFeed, board, boardSeen, type WorkRow } from "./aiboard.tsx";

declare function importShim(url: string): Promise<{ default: ComponentType<any> }>;

export type AiScreen = "chat" | "progress" | "agents" | "devices" | "friction" | "fleet";
/** The menu's screens in its order, by name. */
export const SCREENS: [AiScreen, string][] = [
  ["progress", "Progress"],
  ["agents", "Agents & terminals"],
  ["devices", "Devices"],
  ["friction", "Friction"],
];

const sessions = signal<AgentSession[]>([]);
/** The hosts the sessions come from (`powos terms list`); empty from a PowOS without it (its own tmux only). */
const hosts = signal<AgentHost[]>([]);
powos.on("ai.sessions", (s: AgentSession[]) => (sessions.value = s));
powos.on("ai.hosts", (h: AgentHost[]) => (hosts.value = h));

/** How often the agents at work are listed again while their screen shows. */
const REFRESH_MS = 5000;

/** Claude Code titles its pane with a braille spinner frame while it works (and a mark when it's done). */
const working = (s: AgentSession) => /^[⠀-⣿]/.test(s.title);
const task = (s: AgentSession) => s.title.replace(/^[⠀-⣿✳*·\s]+/, "") || s.command;
const folder = (path: string) => path.split("/").filter(Boolean).at(-1) ?? "~";

/** The sessions, read when the screen comes into view and every few seconds while it shows (not while hidden). */
function useSessions(shown: boolean) {
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

/** A host's line "at work": its name ("installed & running"'s), how many sessions, and when it was read if not now. */
function hostState(h: AgentHost | undefined, n: number) {
  const count = `${n} session${n === 1 ? "" : "s"}`;
  if (!h) return count;
  if (h.pending) return "reading…";
  if (!h.ok) return h.seen ? `${h.error} · as of ${ago(h.seen)}` : h.error;
  return h.via === "local" || Date.now() / 1000 - h.seen < 30 ? count : `${count} · as of ${ago(h.seen)}`;
}

const rank = (h: string) => HOSTS.indexOf(h) + 1 || 99;

/** Per host (this one first, then as "installed & running" orders them): its sessions, working agents first. */
export function AtWork() {
  const local = hosts.value.find((h) => h.via === "local")?.host;
  const names = [...new Set([...hosts.value.map((h) => h.host), ...sessions.value.map((s) => s.host ?? local ?? "")])];
  names.sort((a, b) => Number(b === local) - Number(a === local) || rank(a) - rank(b) || a.localeCompare(b));
  if (!sessions.value.length && !hosts.value.some((h) => !h.ok || h.pending)) return null;
  return (
    <section>
      <h3 class="ai-heading muted">at work</h3>
      {names.map((host) => {
        const list = sessions.value
          .filter((s) => (s.host ?? local ?? "") === host)
          .sort((a, b) => Number(working(b)) - Number(working(a)) || Number(!!b.agent) - Number(!!a.agent) || b.activity - a.activity);
        const h = hosts.value.find((x) => x.host === host);
        const isLocal = !host || host === local;
        return (
          <div key={host || "local"} class="ai-session-host">
            {names.length > 1 && (
              <div class="ai-session-host-head muted">
                {host || "here"} · {hostState(h, list.length)}
              </div>
            )}
            {list.map((s) => {
              const open = sessionView.value;
              return (
                <button
                  type="button"
                  key={`${host}:${s.name}`}
                  class={`ai-session tile ${open?.name === s.name && (open.host ?? "") === (s.host ?? "") ? "opened" : ""}`}
                  onClick={(e) =>
                    openSession(s.name, e.currentTarget as HTMLElement, task(s), { host: s.host, local: isLocal, agent: s.agent ?? working(s) })
                  }
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
            })}
          </div>
        );
      })}
    </section>
  );
}

/** Agents & terminals: the agents view, then every host's sessions. */
function AgentsScreen({ shown }: { shown: boolean }) {
  useSessions(shown);
  return (
    <>
      <button type="button" class="ai-session tile" onClick={() => openAgents()}>
        <span class="ai-dot" />
        <span class="ai-session-main">
          <span class="ai-session-task">Agents</span>
          <span class="ai-session-meta muted">what every agent is on: tree, tasks, tools, comms</span>
        </span>
      </button>
      <AtWork />
      {!sessions.value.length && <div class="ai-empty muted">no terminals open</div>}
    </>
  );
}

/** The app Progress is (another agent's powos-progress); not installed: Summary. */
export const PROGRESS_APP = "powos-progress";

/** The daily-driver epic's percentage as powos-progress tracks it (its board row), null without the app or the row. */
export function dailyDriver(): number | null {
  if (!installedApps.value.some((a) => a.id === PROGRESS_APP)) return null;
  const w = board.value.find((x) => /^daily driver\b/i.test(x.title) && (x.progressTotal ?? 0) > 0);
  return w ? Math.round((100 * Math.min(w.progressDone ?? 0, w.progressTotal!)) / w.progressTotal!) : null;
}

const open = (w: WorkRow) => w.status !== "done";
/** Open tasks per area, most first: [area, in progress, waiting on the user]. */
export function areas(): [string, number, number][] {
  const by = new Map<string, [number, number]>();
  for (const w of board.value.filter(open)) {
    const k = w.project.trim() || "Other";
    const [a, b] = by.get(k) ?? [0, 0];
    by.set(k, w.status === "waiting" ? [a, b + 1] : [a + 1, b]);
  }
  return [...by.entries()].map(([k, [a, b]]): [string, number, number] => [k, a, b]).sort((x, y) => y[1] + y[2] - (x[1] + x[2]));
}

/** Progress without the app: what's open per area, and where the things to try are. No rows to answer here. */
function Summary({ shown }: { shown: boolean }) {
  const rows = areas();
  return (
    <section class="ai-summary tile">
      {shown && <WorkFeed />}
      {rows.map(([area, going, you]) => (
        <div key={area} class="ai-summary-row">
          <span class="ai-summary-area">{area}</span>
          <span class="ai-summary-n muted">
            {going ? `${going} in progress` : ""}
            {going && you ? " · " : ""}
            {you ? `${you} waiting on you` : ""}
          </span>
        </div>
      ))}
      {!rows.length && <div class="ai-summary-row muted">{boardSeen.value ? "nothing in progress" : "…"}</div>}
      <div class="ai-summary-foot muted">Things to try arrive in the chat.</div>
    </section>
  );
}

/** The progress app's page module URL, when it is installed with a page. */
function progressUrl(): string | null {
  const app = installedApps.value.find((a) => a.id === PROGRESS_APP);
  const entry = app && manifestOf(app).page?.entry;
  return app && entry ? moduleUrl(app.id, entry, app.version) : null;
}

/** A page that threw: the board instead (and the reason in the log), never a dead screen. */
class Fallback extends Component<{ children?: any }, { failed: boolean }> {
  state = { failed: false };
  componentDidCatch(e: unknown) {
    console.error(`${PROGRESS_APP} page crashed:`, e);
    this.setState({ failed: true });
  }
  render() {
    return this.state.failed ? <Summary shown={true} /> : this.props.children;
  }
}

/** Progress: the powos-progress app's page in this screen (its module, as appscreen.tsx renders it), else the board. */
function ProgressScreen({ shown, back }: { shown: boolean; back: () => void }) {
  const url = progressUrl();
  const [mod, setMod] = useState<{ url: string; c: ComponentType<any> } | null>(null);
  const [failed, setFailed] = useState(false);
  useEffect(() => {
    if (!url) return;
    let live = true;
    importShim(url).then(
      (m) => live && setMod({ url, c: m.default }),
      (e) => live && (console.error(`${PROGRESS_APP} page didn't load:`, e), setFailed(true)),
    );
    return () => void (live = false);
  }, [url]);
  const C = mod && mod.url === url ? mod.c : null;
  if (!url || failed) return <Summary shown={shown} />;
  if (!C) return <div class="ai-empty muted">…</div>;
  return (
    <div class="ai-app-page">
      <Fallback>
        <C host={appHost} app={PROGRESS_APP} base={`./_app/${PROGRESS_APP}/`} close={back} />
      </Fallback>
    </div>
  );
}

/** Friction: what keeps getting in the agents' way, open (the board's feed while it shows). */
function FrictionScreen({ shown }: { shown: boolean }) {
  return (
    <section class="ai-work-list tile">
      {shown && <WorkFeed />}
      <Friction start={true} />
    </section>
  );
}

/** The screen [s] (not the chat), [shown]: on screen - its feeds run only then. */
export function MenuScreen({ s, shown, back }: { s: AiScreen; shown: boolean; back: () => void }) {
  if (s === "progress") return <ProgressScreen shown={shown} back={back} />;
  if (s === "agents" || s === "fleet") return <AgentsScreen shown={shown} />;
  if (s === "devices") return <Units shown={shown} />;
  if (s === "friction") return <FrictionScreen shown={shown} />;
  return null;
}
