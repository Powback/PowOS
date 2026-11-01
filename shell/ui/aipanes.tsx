/**
 * The unfolded PowOS AI page's right column parts (the manager's design, 11-01: "a proper setup, not a huge chat"): the
 * segmented row at its top - Chat / Agents / Progress / Devices with their live counts, the open one marked; a tap swaps
 * the right column's content (the left is the folded status page, aistatus.tsx) - and the Agents view in it.
 * powai.tsx lays them out.
 */
import { useEffect } from "preact/hooks";
import { signal } from "@preact/signals";
import { aiScreen, chat } from "../state.ts";
import { agentsView, closeAgents, useAgents } from "../agents.ts";
import { fleet, type Fleet } from "../fleet.ts";
import { AgentsView, BoardFeed, needsBoard } from "./agents.tsx";
import { AtWork, areas, dailyDriver, type AiScreen } from "./aimenu.tsx";
import { Feed as UnitsFeed, units } from "./units.tsx";

/** The agent open in the right column's Agents view (null: the list). */
export const aiAgent = signal<string | null>(null);

/**
 * HACK: the Agents view's rows (agents.tsx) open an agent through the overlay's signal (openAgents), which would put the
 * Agents sheet over home behind this page; while the wide page shows, that signal is taken here into the right column
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

/** The right column's Agents: the fleet list with every host's terminals under it (as folded Agents & terminals), or one agent live. */
export function FleetPane() {
  const id = aiAgent.value;
  return <AgentsView id={id} onClose={() => (aiScreen.value = "chat")} foot={<AtWork />} />;
}

/** The segments, each with its live count ("" none): Agents counts the working and the stuck ones. */
function segItems(f: Fleet): [AiScreen, string, string][] {
  const dd = dailyDriver();
  const open = areas().reduce((n, [, a, b]) => n + a + b, 0);
  const hosts = new Set(units.value.map((u) => u.host)).size;
  const busy = f.working.length + f.attention.length;
  return [
    ["chat", "Chat", chat.value.busy ? "…" : ""],
    ["fleet", "Agents", busy ? String(busy) : ""],
    ["progress", "Progress", dd != null ? `${dd}%` : open ? String(open) : ""],
    ["devices", "Devices", hosts ? String(hosts) : ""],
  ];
}

/** The right column's segmented row. [shown]: the feeds behind its counts run only then (the board's is the status column's, beside it). */
export function AiSegs({ shown }: { shown: boolean }) {
  useAgents();
  const f = fleet();
  const s = aiScreen.value;
  const at = (k: AiScreen) => k === s || (k === "fleet" && s === "agents");
  return (
    <nav class="ai-segs" aria-label="PowOS AI">
      {shown && <UnitsFeed />}
      {shown && needsBoard(f) && <BoardFeed />}
      {segItems(f).map(([k, name, n]) => (
        <button
          key={k}
          type="button"
          class={`ai-seg ${at(k) ? "on" : ""}`}
          aria-pressed={at(k)}
          onClick={() => ((aiAgent.value = null), (aiScreen.value = k))}
        >
          <span class="ai-seg-name">{name}</span>
          {n && <span class="ai-seg-n">{n}</span>}
        </button>
      ))}
    </nav>
  );
}
