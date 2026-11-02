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
import { aiAgent, openAgents } from "../agents.ts";
import { AgentLive } from "./agents.tsx";
import { installedApps, manifestOf, moduleUrl } from "../apps/pages.ts";
import { host as appHost } from "../apps/stdb.ts";
import type { AgentHost } from "../types.ts";
import { SessionRow, hostOf, hosts, localHost, sessions, sessionsOn, useSessions } from "./terms.tsx";
import { ago } from "./time.ts";
import { HOSTS, Units } from "./units.tsx";
import { WorkFeed, board, type WorkRow } from "./aiboard.tsx";
import { FrictionPage } from "./aifriction.tsx";
import { ProgressView } from "./aiprogress.tsx";

declare function importShim(url: string): Promise<{ default: ComponentType<any> }>;

export type AiScreen = "chat" | "progress" | "agents" | "devices" | "friction" | "fleet";
/** The menu's screens in its order, by name. */
export const SCREENS: [AiScreen, string][] = [
  ["progress", "Progress"],
  ["agents", "Agents & terminals"],
  ["devices", "Devices"],
  ["friction", "Friction"],
];
/** The screens the bottom tabs offer (Agents & terminals: the Agents tab; its terminals under the Agents and Devices tabs): never in a ⋯ that sits over those tabs. */
export const TABBED = new Set<AiScreen>(["progress", "agents", "devices"]);

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
  const local = localHost();
  const names = [...new Set([...hosts.value.map((h) => h.host), ...sessions.value.map(hostOf)])];
  names.sort((a, b) => Number(b === local) - Number(a === local) || rank(a) - rank(b) || a.localeCompare(b));
  if (!sessions.value.length && !hosts.value.some((h) => !h.ok || h.pending)) return null;
  return (
    <section class="ais-sec" aria-label="At work">
      <h3 class="ais-h">
        At work<span class="ais-n">{sessions.value.length}</span>
      </h3>
      {names.map((host) => {
        const list = sessionsOn(host);
        const h = hosts.value.find((x) => x.host === host);
        return (
          <div key={host || "local"} class="ai-session-host">
            {names.length > 1 && (
              <div class="ai-session-host-head muted">
                {host || "here"} · {hostState(h, list.length)}
              </div>
            )}
            {list.map((s) => (
              <SessionRow key={`${host}:${s.name}`} s={s} />
            ))}
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

/** Progress without the app: the ring and the areas' cards (aiprogress.tsx). */
const Summary = ProgressView;

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
function ProgressScreen({ shown, back, beside = false }: { shown: boolean; back: () => void; beside?: boolean }) {
  // Beside the status column (unfolded): only the areas - the column already shows the ring and Needs you.
  const url = beside ? null : progressUrl();
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
  if (!url || failed) return <Summary shown={shown} areasOnly={beside} />;
  if (!C) return <div class="ai-empty muted">…</div>;
  return (
    <div class="ai-app-page">
      <Fallback>
        <C host={appHost} app={PROGRESS_APP} base={`./_app/${PROGRESS_APP}/`} close={back} />
      </Fallback>
    </div>
  );
}

/** Friction: what keeps getting in the agents' way, in plain words per area (aifriction.tsx; the board's feed while it shows). */
function FrictionScreen({ shown }: { shown: boolean }) {
  return (
    <>
      {shown && <WorkFeed />}
      <FrictionPage />
    </>
  );
}

/** Devices: installed & running per host, each host's terminals under its name (the sessions read while it shows). */
function Devices({ shown }: { shown: boolean }) {
  useSessions(shown);
  return <Units shown={shown} />;
}

/** The screen [s] (not the chat), [shown]: on screen - its feeds run only then; [beside]: next to the status column. */
export function MenuScreen({ s, shown, back, beside = false }: { s: AiScreen; shown: boolean; back: () => void; beside?: boolean }) {
  if (s === "progress") return <ProgressScreen shown={shown} back={back} beside={beside} />;
  // Folded, a Working now row opens its agent here, full page (the user, 11-01 16:45: "navigate to the chats").
  if (s === "fleet" && aiAgent.value) return <AgentLive id={aiAgent.value} />;
  if (s === "agents" || s === "fleet") return <AgentsScreen shown={shown} />;
  if (s === "devices") return <Devices shown={shown} />;
  if (s === "friction") return <FrictionScreen shown={shown} />;
  return null;
}
