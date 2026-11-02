/**
 * The unfolded PowOS AI page's right column parts (the manager's design, 11-01: "a proper setup, not a huge chat"): the
 * segmented row at its top - Chat / Agents / Progress / Devices with their live counts, the open one marked; a tap swaps
 * the right column's content (the left is the folded status page, aistatus.tsx) - and the Agents view in it.
 * powai.tsx lays them out.
 */
import { useEffect, useState } from "preact/hooks";
import { aiScreen, chat } from "../state.ts";
import { agentsView, aiAgent, closeAgents, messages, since, useAgents } from "../agents.ts";
import { fleet, ownWords, shorten, taskOf, workingNow, type Fleet, type Worker } from "../fleet.ts";
import type { Agent } from "../types.ts";
import { ACT_LABEL, act, AgentsView, BoardFeed, needsBoard, took } from "./agents.tsx";
import { ThinBar } from "./aiprogress.tsx";
import { TermButton } from "./terms.tsx";
import { AtWork, areas, dailyDriver, type AiScreen } from "./aimenu.tsx";
import { Feed as UnitsFeed, units } from "./units.tsx";

/** The agent open in the right column's Agents view (null: the list); agents.ts's, so the folded page's screen shares it. */
export { aiAgent };

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

/** The right column's Agents: the fleet as Progress rows with every host's terminals under them, or one agent live. */
export function FleetPane() {
  const id = aiAgent.value;
  return <AgentsView id={id} onClose={() => (aiScreen.value = "chat")} list={(f) => <FleetRows f={f} foot={<AtWork />} />} />;
}

/** A tap on an agent's row: that agent live - its conversation - in this column (the user, 11-01 16:45: "navigate to the chats"). */
const openLive = (id: string) => ((aiAgent.value = id), (aiScreen.value = "fleet"));

/**
 * One agent as one glass row, the Progress page's (the user, 11-01 16:51: "the chat and the agents and the device page
 * don't follow the same design"): its state dot, its task, a plain state word, its device; [children] between the title
 * and the state (a bar, an action). A tap opens it live.
 */
function AgentRow(props: { a: Agent; dot: string; title: preact.ComponentChildren; state: string; children?: preact.ComponentChildren }) {
  const { a, dot, title, state, children } = props;
  return (
    <li class="aip-area tile ag-row" data-agent={a.id}>
      <div class="aip-area-row ag-row-line" role="button" tabIndex={0} onClick={() => openLive(a.id)}>
        <span class={`aip-dot ${dot}`} aria-hidden="true" />
        <span class="aip-area-name ag-row-title">{title}</span>
        {children}
        {state && <span class="ag-row-state">{state}</span>}
        <span class="fl-chip">{a.host}</span>
      </div>
    </li>
  );
}

/** A working agent: its task, the plan's bar and N/M ("working" without one), its terminal. */
function WorkingRow({ x }: { x: Worker }) {
  return (
    <AgentRow a={x.a} dot="working" title={x.title} state={x.total > 0 ? `${x.done}/${x.total}` : "working"}>
      {x.total > 0 && <ThinBar done={x.done} total={x.total} />}
      <TermButton a={x.a} label="terminal" />
    </AgentRow>
  );
}

/** A stuck one: why, as the left column says it (its task is in its live view), its one action (restart / allow). */
function StuckRow({ x }: { x: Worker }) {
  return (
    <AgentRow a={x.a} dot="waiting" title={x.reason ?? x.title} state="">
      {x.action && x.action !== "open" && (
        <button type="button" class="ag-act danger" onClick={(e) => (e.stopPropagation(), act(x))}>
          {ACT_LABEL[x.action]}
        </button>
      )}
      <TermButton a={x.a} label="terminal" />
    </AgentRow>
  );
}

/** A titled group of rows ("Working now 3"); none: not drawn. */
function Group({ name, n, children }: { name: string; n: number; children: preact.ComponentChildren }) {
  if (!n) return null;
  return (
    <section class="ais-sec" aria-label={name}>
      <h3 class="ais-h">
        {name}
        <span class="ais-n">{n}</span>
      </h3>
      <ul class="aip-areas">{children}</ul>
    </section>
  );
}

/** An idle or finished session, one line in the fold: its best words, idle / took N, its device; a tap opens it live. */
function RestLine({ a }: { a: Agent }) {
  const words = taskOf(a.work)?.title || ownWords(a) || `Session in ${a.cwd || a.host}`;
  const state = a.state === "gone" ? `done · took ${took(a.last - a.started)}` : `idle ${since(a.last)}`;
  return (
    <li class="ag-rest">
      <button type="button" class="ag-rest-line" onClick={() => openLive(a.id)}>
        <span class="aip-dot" aria-hidden="true" />
        <span class="ag-row-title">{shorten(words, 70)}</span>
        <span class="ag-row-state">{state}</span>
        <span class="fl-chip">{a.host}</span>
      </button>
    </li>
  );
}

/** A glass row that opens in place: [line] and a count, then [children] under it. */
function Fold({ line, n, children }: { line: string; n: number; children: preact.ComponentChildren }) {
  const [open, setOpen] = useState(false);
  if (!n) return null;
  return (
    <ul class="aip-areas">
      <li class={`aip-area tile ag-fold ${open ? "open" : ""}`}>
        <button type="button" class="aip-area-row ais-toggle" aria-expanded={open} onClick={() => setOpen(!open)}>
          <span class="aip-area-name">{line}</span>
          <span class="ais-chev" aria-hidden="true" />
        </button>
        {open && <ul class="aip-tasks ag-fold-list">{children}</ul>}
      </li>
    </ul>
  );
}

/** The agents' mail, folded to one row; open, a line each (when, who to whom, its start), a tap shows the whole body. */
function CommsFold() {
  const [opened, setOpened] = useState<string | null>(null);
  const list = [...messages.value].reverse();
  return (
    <Fold line={`Messages between agents · ${list.length}`} n={list.length}>
      {list.map((m) => (
        <li key={m.id} class={`ag-mail ${opened === m.id ? "open" : ""}`}>
          <button type="button" class="ag-rest-line" aria-expanded={opened === m.id} onClick={() => setOpened(opened === m.id ? null : m.id)}>
            <span class="ag-row-state">{new Date(m.ts).toTimeString().slice(0, 5)}</span>
            <span class="ag-row-title">
              {m.from} → {m.to}: {m.body.split("\n")[0]}
            </span>
          </button>
          {opened === m.id && <div class="ag-mail-body">{m.body}</div>}
        </li>
      ))}
    </Fold>
  );
}

/**
 * The AI page's Agents tab in the Progress design: the manager, Needs attention, Working now - a glass row each - then
 * the idle and finished ones folded to one row, [foot] (every host's terminals) and the agents' mail folded.
 */
function FleetRows({ f, foot }: { f: Fleet; foot?: preact.ComponentChildren }) {
  const working = workingNow(f);
  const m = f.manager;
  const rest = [...f.idle, ...f.doneToday, ...f.older];
  const idle = f.idle.length + f.older.length;
  return (
    <div class="aip ag-rows">
      {m && (
        <ul class="aip-areas">
          <AgentRow a={m.a} dot={m.a.state === "working" ? "working" : ""} title="Manager" state={m.now}>
            <span class="ag-row-ago">{since(m.a.last)}</span>
          </AgentRow>
        </ul>
      )}
      <Group name="Needs attention" n={f.attention.length}>
        {f.attention.map((x) => (
          <StuckRow key={x.a.id} x={x} />
        ))}
      </Group>
      <Group name="Working now" n={working.length}>
        {working.map((x) => (
          <WorkingRow key={x.a.id} x={x} />
        ))}
      </Group>
      {!working.length && !f.attention.length && <div class="aip-empty">No agent is working right now.</div>}
      <Fold line={[idle ? `${idle} idle` : "", f.doneToday.length ? `${f.doneToday.length} done today` : ""].filter(Boolean).join(" · ")} n={rest.length}>
        {rest.map((a) => (
          <RestLine key={a.id} a={a} />
        ))}
      </Fold>
      {foot}
      <CommsFold />
    </div>
  );
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
