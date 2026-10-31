/**
 * The unfolded PowOS AI page's side panes (the user, 2026-10-31 13:29: a three-pane app, "not a stretched chat"): the
 * left nav (the title, Chat / Agents / Progress / Devices with their live counts, the open one marked; a tap swaps the
 * middle pane) and the right context column (Working now: the fleet's working agents, a tap opens one live in the
 * middle; Try this: the newest things-to-try message only; Needs attention: stuck agents). Each a glass pane of its own;
 * an empty section isn't drawn. Folded sideways (rail) the nav is icons and the column is gone. powai.tsx lays them out.
 */
import { useEffect } from "preact/hooks";
import { signal } from "@preact/signals";
import { aiScreen, chat } from "../state.ts";
import { agentsView, closeAgents, useAgents } from "../agents.ts";
import { fleet, type Fleet, type Worker } from "../fleet.ts";
import { AgentsView, Bar, BoardFeed, needsBoard } from "./agents.tsx";
import { areas, dailyDriver, type AiScreen } from "./aimenu.tsx";
import { WorkFeed } from "./aiboard.tsx";
import { Feed as UnitsFeed, units } from "./units.tsx";
import { LatestTry, latestTry } from "./trycard.tsx";

/** The agent open in the middle pane's Agents view (null: the list). */
export const aiAgent = signal<string | null>(null);

/** An agent's live view in the middle pane. */
const openAgent = (id: string) => ((aiAgent.value = id), (aiScreen.value = "fleet"));

/**
 * HACK: the Agents view's rows (agents.tsx) open an agent through the overlay's signal (openAgents), which would put the
 * Agents sheet over home behind this page; while the wide page shows, that signal is taken here into the middle pane
 * instead. Real fix: AgentsView takes an onOpen it hands its rows.
 */
export function useAgentsInPane(on: boolean) {
  const v = agentsView.value;
  useEffect(() => {
    if (!on || !v) return;
    aiAgent.value = v.id;
    aiScreen.value = "fleet";
    closeAgents();
  }, [on, v]);
}

/** The middle pane's Agents: the fleet list, or one agent live. */
export function FleetPane() {
  const id = aiAgent.value;
  return <AgentsView id={id} onClose={() => (aiScreen.value = "chat")} />;
}

/** The nav's places, each with its live count ("" none). */
function navItems(f: Fleet): [AiScreen, string, string, string][] {
  const dd = dailyDriver();
  const open = areas().reduce((n, [, a, b]) => n + a + b, 0);
  const hosts = new Set(units.value.map((u) => u.host)).size;
  const busy = f.working.length + f.attention.length;
  return [
    ["chat", "Chat", "›", chat.value.busy ? "…" : ""],
    ["fleet", "Agents", "◎", busy ? String(busy) : ""],
    ["progress", "Progress", "▤", dd != null ? `${dd}%` : open ? String(open) : ""],
    ["devices", "Devices", "▣", hosts ? String(hosts) : ""],
  ];
}

/** The left nav. [rail]: icons only (folded sideways). [shown]: the feeds behind its counts run only then. */
export function AiNav({ rail, shown }: { rail: boolean; shown: boolean }) {
  useAgents();
  const f = fleet();
  const s = aiScreen.value;
  const at = (k: AiScreen) => k === s || (k === "fleet" && s === "agents");
  return (
    <nav class={`ai-nav tile ${rail ? "rail" : ""}`} aria-label="PowOS AI">
      {shown && <WorkFeed />}
      {shown && <UnitsFeed />}
      {shown && needsBoard(f) && <BoardFeed />}
      <div class="ai-nav-title">{rail ? "AI" : "PowOS AI"}</div>
      {navItems(f).map(([k, name, icon, n]) => (
        <button
          key={k}
          type="button"
          class={`ai-nav-item ${at(k) ? "on" : ""}`}
          aria-current={at(k) ? "page" : undefined}
          aria-label={name}
          onClick={() => ((aiAgent.value = null), (aiScreen.value = k))}
        >
          <span class="ai-nav-icon" aria-hidden="true">{icon}</span>
          {!rail && <span class="ai-nav-name">{name}</span>}
          {n && <span class="ai-nav-n">{n}</span>}
        </button>
      ))}
    </nav>
  );
}

/** One agent card in the right column: its task, a thin progress bar, what it's doing now (or why it's stuck). */
function Card({ x }: { x: Worker }) {
  const bad = !!x.reason;
  return (
    <button type="button" class={`ai-ctx-card ${bad ? "bad" : ""}`} onClick={() => openAgent(x.a.id)}>
      <span class="ai-ctx-title">{bad ? x.reason : x.title}</span>
      {!bad && <Bar done={x.done} total={x.total} />}
      <span class="ai-ctx-now muted">{bad ? x.title : x.now}</span>
    </button>
  );
}

/** A section of the right column, not drawn without anything in it. */
function Sec({ title, children, when }: { title: string; children: preact.ComponentChildren; when: boolean }) {
  if (!when) return null;
  return (
    <section class="ai-ctx-sec">
      <h3 class="ai-ctx-head">{title}</h3>
      {children}
    </section>
  );
}

/** The right context column: Working now, Try this (the newest bundle), Needs attention. */
export function AiContext() {
  useAgents();
  const f = fleet();
  const texts = chat.value.items.flatMap((i) => (i.kind === "assistant" ? [i.text] : []));
  const hasTry = latestTry(texts) != null;
  const empty = !f.working.length && !f.attention.length && !hasTry;
  return (
    <aside class="ai-ctx tile" aria-label="right now">
      <Sec title="Working now" when={f.working.length > 0}>
        {f.working.slice(0, 6).map((x) => (
          <Card key={x.a.id} x={x} />
        ))}
      </Sec>
      <Sec title="Try this" when={hasTry}>
        <LatestTry texts={texts} />
      </Sec>
      <Sec title="Needs attention" when={f.attention.length > 0}>
        {f.attention.slice(0, 6).map((x) => (
          <Card key={x.a.id} x={x} />
        ))}
      </Sec>
      {empty && <div class="ai-ctx-empty muted">Nothing running and nothing to try right now.</div>}
    </aside>
  );
}
