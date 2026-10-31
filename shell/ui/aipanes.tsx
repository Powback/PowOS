/**
 * The unfolded PowOS AI page's side panes (the user, 2026-10-31 13:29: a three-pane app, "not a stretched chat"): the
 * left nav (the title, Chat / Agents / Progress / Devices with their live counts, the open one marked; a tap swaps the
 * middle pane) and the right context column (Working now: the fleet's working agents, a tap opens one live in the
 * middle; Try this: the board's open asks - needsyou.tsx, the same rows as Progress's Needs you; Needs attention: stuck
 * agents). Each a glass pane of its own;
 * an empty section isn't drawn. Folded sideways (rail) the nav is icons and the column is gone. powai.tsx lays them out.
 */
import { useEffect, useState } from "preact/hooks";
import { signal } from "@preact/signals";
import { aiScreen, chat } from "../state.ts";
import { agentsView, closeAgents, useAgents } from "../agents.ts";
import { fleet, isPowOS, projectOf, type Fleet, type Worker } from "../fleet.ts";
import { AgentsView, Bar, BoardFeed, needsBoard } from "./agents.tsx";
import { areas, dailyDriver, type AiScreen } from "./aimenu.tsx";
import { WorkFeed } from "./aiboard.tsx";
import { Feed as UnitsFeed, units } from "./units.tsx";
import { needsYou, TryThis } from "./needsyou.tsx";

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

/**
 * Working now: PowOS's own agents (fleet.ts projectOf: the session's working directory); other projects' under a small
 * "Other projects (N)" toggle, closed at first (the user's review, 14:17: "Fix #815 answer contracts", "Coder session
 * in rsi-native" listed as if they were PowOS work).
 */
function WorkingNow({ working }: { working: Worker[] }) {
  const [open, setOpen] = useState(false);
  const own = working.filter((x) => isPowOS(x.a));
  const other = working.filter((x) => !isPowOS(x.a));
  return (
    <Sec title="Working now" when={working.length > 0}>
      {own.slice(0, 6).map((x) => (
        <Card key={x.a.id} x={x} />
      ))}
      {other.length > 0 && (
        <button type="button" class="ai-ctx-other" aria-expanded={open} onClick={() => setOpen(!open)}>
          Other projects ({other.length}) <span class="mail-chev" aria-hidden="true" />
        </button>
      )}
      {open &&
        other.slice(0, 6).map((x) => (
          <Card key={x.a.id} x={{ ...x, now: x.now ? `${projectOf(x.a)} · ${x.now}` : projectOf(x.a) }} />
        ))}
    </Sec>
  );
}

/**
 * The right context column: Working now, Try this, Needs attention. Try this reads the board (needsyou.tsx), not the
 * chat's newest try message: with that answered (or none in the loaded history) it said "nothing to try" while
 * Progress listed what waits on the user. The board's feed is the nav's (AiNav, beside it whenever this shows).
 */
export function AiContext() {
  useAgents();
  const f = fleet();
  const needs = needsYou();
  const empty = !f.working.length && !f.attention.length && !needs.length;
  return (
    <aside class="ai-ctx tile" aria-label="right now">
      <WorkingNow working={f.working} />
      <Sec title="Try this" when={needs.length > 0}>
        <TryThis needs={needs} />
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
