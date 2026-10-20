/**
 * The Agents view (docs/AGENTS-VIEW-DESIGN.md §1): which agents run - here and on the Mac - what each one is on, its
 * subagents, tasks and tools, and who handed what to whom.
 *
 * - AgentsPanel: home's Agents widget (a "panel" home item): open asks allowed/denied in place, a line per session agent
 *   (this phone's working ones stoppable in place), needs-you first; a tap on a line opens
 *   the screen on it. 4×1 shows the count line only.
 * - AgentsScreen: the tree (manager → its agents → their subagents), the picked agent's step, tasks, recent tools and
 *   last report, and the comms feed. Opened from the widget, PowOS AI's page and the agents' notification.
 *
 * Its data is agents.ts (one signal per agent: a line redraws only when its agent changes).
 */
import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";
import { powos } from "../bridge.ts";
import {
  agent,
  agentIds,
  asks,
  agentsView,
  closeAgents,
  isSub,
  live,
  mark,
  messages,
  openAgents,
  parentOf,
  recent,
  sessions,
  since,
  tasks,
  useAgentEvents,
  useAgents,
} from "../agents.ts";
import { takeTap } from "./taps.ts";
import type { Agent, AgentEvent, HomeItem } from "../types.ts";

/** "role · host · what it's on", the widget's and the tree's line. */
const doing = (a: Agent) =>
  a.state === "needs_you"
    ? "needs you"
    : a.state === "blocked"
      ? a.step || "blocked"
      : a.state === "gone"
        ? "done"
        : a.title || a.step || (a.state === "idle" ? "idle" : a.cwd);

/** A button on the widget: its tap is its own (not the tile's, not the line's). */
const tapOnly = (run: () => void) => ({
  onPointerUp: takeTap,
  onClick: (e: Event) => {
    e.stopPropagation();
    run();
  },
});

function Line({ id, inline = false }: { id: string; inline?: boolean }) {
  const a = agent(id)?.value;
  const [sure, setSure] = useState(false);
  useEffect(() => setSure(false), [a?.state]);
  if (!a) return null;
  // On the widget: this phone's agent, working, can be stopped right there (a second tap, so a stray one doesn't).
  const stoppable = inline && a.host === "phone" && a.state === "working" && a.pid > 1;
  return (
    <div class="ag-line-row" style={{ display: "flex", alignItems: "center", gap: "6px" }}>
      <button type="button" class={`ag-line ${a.state}`} style={{ flex: 1, minWidth: 0 }} onPointerUp={takeTap} onClick={() => openAgents(id)}>
        <span class="ag-mark">{mark(a)}</span>
        <span class="ag-who">{a.role}</span>
        <span class="ag-host muted">· {a.host} ·</span>
        <span class="ag-what">
          {doing(a)}
          {a.subs > 0 && <span class="muted"> ({a.subs} sub)</span>}
        </span>
        <span class="ag-ago muted">{since(a.last)}</span>
      </button>
      {stoppable && (
        <button type="button" class={`ag-act ${sure ? "danger" : ""}`} {...tapOnly(() => (sure ? (powos.agents.interrupt(a.id), setSure(false)) : setSure(true)))}>
          {sure ? "stop?" : "stop"}
        </button>
      )}
    </div>
  );
}

/** "3 running · 1 needs you". */
function count(ids: string[]) {
  const states = ids.map((id) => agent(id)?.value.state);
  const working = states.filter((s) => s === "working").length;
  const need = states.filter((s) => s === "needs_you").length;
  const parts = [`${working} running`];
  if (need) parts.push(`${need} needs you`);
  if (!working && !need) parts[0] = ids.length ? `${ids.length} idle` : "none running";
  return parts.join(" · ");
}

/** Home's Agents widget (grid.tsx draws it for a "panel" item named "agents"). */
export function AgentsPanel({ item }: { item: HomeItem }) {
  useAgents();
  const ids = sessions.value;
  const rows = item.cell && item.cell.h <= 1 ? 0 : 4;
  const shown = ids.slice(0, rows);
  return (
    <div class="tile ag-panel">
      <div class="ag-head">
        <span>Agents</span>
        <span class="muted">{count(ids)}</span>
      </div>
      {rows > 0 && <InlineAsks max={2} />}
      {shown.map((id) => (
        <Line key={id} id={id} inline />
      ))}
      {rows > 0 && ids.length > rows && <div class="ag-more muted">+{ids.length - rows} more</div>}
      {rows > 0 && !ids.length && <div class="ag-more muted">no agent reports yet</div>}
    </div>
  );
}

/** The widget's open asks, decided in place: allow or deny (telling it what to do instead is on the screen). */
function InlineAsks({ max }: { max: number }) {
  const open = asks.value.filter((x) => x.answer == null).slice(0, max);
  return (
    <>
      {open.map((x) => (
        <div key={x.id} class="ag-ask-line" style={{ display: "flex", alignItems: "center", gap: "6px" }}>
          <span style={{ flex: 1, minWidth: 0, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
            <b>{agent(x.agent)?.value.role ?? "an agent"}</b> wants {x.tool}: <span class="muted">{x.summary}</span>
          </span>
          <button type="button" class="ag-act" {...tapOnly(() => powos.agents.answer(x.id, "allow"))}>
            allow
          </button>
          <button type="button" class="ag-act danger" {...tapOnly(() => powos.agents.answer(x.id, "deny"))}>
            deny
          </button>
        </div>
      ))}
    </>
  );
}

/** The tree: session agents under their parent (the manager), subagents under their session. */
function tree(ids: string[]) {
  const all = ids.map((id) => agent(id)?.value).filter((a): a is Agent => !!a);
  const kids = new Map<string | null, Agent[]>();
  for (const a of all) {
    // Done subagents stay a while (§2 gone: an hour); finished sessions don't.
    if (a.state === "gone" && !isSub(a)) continue;
    const p = parentOf(a);
    kids.set(p, [...(kids.get(p) ?? []), a]);
  }
  const out: { a: Agent; depth: number }[] = [];
  const seen = new Set<string>();
  const walk = (p: string | null, depth: number) => {
    for (const a of (kids.get(p) ?? []).sort((x, y) => x.started - y.started)) {
      if (seen.has(a.id)) continue;
      seen.add(a.id);
      out.push({ a, depth });
      walk(a.id, depth + 1);
    }
  };
  walk(null, 0);
  return out;
}

/** Tool calls as §1.3's "Read×6 · Bash ✗ (2s)": the coalesced rows, latest last. */
function Tool({ e }: { e: AgentEvent }) {
  const label = e.kind === "tool" ? e.name : e.kind === "prompt" ? "asked" : e.kind.replace("_", " ");
  return (
    <span class={`ag-tool ${e.ok === false ? "fail" : ""}`} title={e.hint}>
      {label}
      {e.n > 1 && `×${e.n}`}
      {e.n === 1 && e.hint && e.hint !== e.name && <span class="muted"> {e.hint}</span>}
      {e.ok === false && " ✗"}
      {e.ms >= 2000 && <span class="muted"> ({Math.round(e.ms / 1000)}s)</span>}
    </span>
  );
}

function Detail({ id }: { id: string }) {
  useAgentEvents(id);
  const a = agent(id)?.value;
  if (!a) return null;
  const list = tasks.value.get(id) ?? [];
  const events = recent.value.agent === id ? recent.value.events.slice(-20) : [];
  return (
    <section class="ag-detail tile">
      <div class="ag-detail-head">
        <span class={`ag-mark ${a.state}`}>{mark(a)}</span> {a.role}
        <span class="muted">
          {" "}
          · {a.host} · {a.cwd} · {a.state.replace("_", " ")} {since(a.last)}
        </span>
      </div>
      {a.step && a.state !== "gone" && (
        <div>
          <span class="muted">Now </span>
          {a.step}
        </div>
      )}
      {a.title && (
        <div>
          <span class="muted">Task </span>
          {a.title}
        </div>
      )}
      {list.length > 0 && (
        <div class="ag-tasks">
          {list.map((t) => (
            <span key={t.id} class={`ag-task ${t.status}`}>
              {t.status === "done" ? "✓" : t.status === "in_progress" ? "●" : "○"} {t.subject}
            </span>
          ))}
        </div>
      )}
      {events.length > 0 && (
        <div class="ag-tools">
          {events.map((e) => (
            <Tool key={e.id} e={e} />
          ))}
        </div>
      )}
      {a.report && (
        <div class="ag-report">
          <span class="muted">Last report </span>
          {a.report}
        </div>
      )}
      {!isSub(a) && a.state !== "gone" && <Actions a={a} />}
    </section>
  );
}

/**
 * What reaches an agent from here (§6): mail to its comms inbox, and - this phone's own, while it works - ending its
 * turn (SIGINT, as Esc at its terminal; a second tap, so a stray one doesn't).
 */
function Actions({ a }: { a: Agent }) {
  const [text, setText] = useState("");
  const [sure, setSure] = useState(false);
  const [sent, setSent] = useState(false);
  useEffect(() => setSure(false), [a.id, a.state]);
  const send = () => {
    const t = text.trim();
    if (!t) return;
    powos.agents.message(a.role, t);
    setText("");
    setSent(true);
  };
  return (
    <div class="ag-actions">
      <form
        class="ag-say"
        onSubmit={(e) => {
          e.preventDefault();
          send();
        }}
      >
        <input
          value={text}
          onInput={(e) => (setText((e.currentTarget as HTMLInputElement).value), setSent(false))}
          onFocus={() => powos.keyboard.show()}
          placeholder={sent ? `sent to ${a.role}'s inbox` : `message ${a.role}`}
          enterKeyHint="send"
          autocomplete="off"
        />
      </form>
      {a.host === "phone" && a.state === "working" && a.pid > 1 && (
        <button
          type="button"
          class={`ag-act ${sure ? "danger" : ""}`}
          onClick={() => (sure ? (powos.agents.interrupt(a.id), setSure(false)) : setSure(true))}
        >
          {sure ? "stop its turn?" : "stop"}
        </button>
      )}
    </div>
  );
}

/** The open asks (§1.2 approvals), decided on the card itself: allow, deny, or deny with what to do instead. */
function Asks() {
  const open = asks.value.filter((x) => x.answer == null);
  const [reply, setReply] = useState<Record<string, string>>({});
  if (!open.length) return null;
  return (
    <section>
      <h3 class="ai-heading muted">needs you</h3>
      {open.map((x) => {
        const who = agent(x.agent)?.value.role ?? "an agent";
        const why = (reply[x.id] ?? "").trim();
        return (
          <div key={x.id} class="ag-ask tile">
            <div>
              <b>{who}</b> wants to run <b>{x.tool}</b> <span class="muted">· {since(x.ts)}</span>
            </div>
            <code class="ag-ask-what">{x.summary}</code>
            <input
              value={reply[x.id] ?? ""}
              onInput={(e) => setReply({ ...reply, [x.id]: (e.currentTarget as HTMLInputElement).value })}
              onFocus={() => powos.keyboard.show()}
              placeholder="or tell it what to do instead"
              autocomplete="off"
            />
            <div class="ag-ask-do">
              <button type="button" class="ag-act" onClick={() => powos.agents.answer(x.id, "allow")} disabled={!!why}>
                allow
              </button>
              <button
                type="button"
                class="ag-act danger"
                onClick={() => powos.agents.answer(x.id, "deny", why || undefined)}
              >
                {why ? "deny + tell" : "deny"}
              </button>
            </div>
          </div>
        );
      })}
    </section>
  );
}

const clock = (ms: number) => new Date(ms).toTimeString().slice(0, 5);

function Comms() {
  const list = [...messages.value].reverse();
  if (!list.length) return null;
  return (
    <section>
      <h3 class="ai-heading muted">comms</h3>
      <div class="ag-comms tile">
        {list.map((m) => (
          <div key={m.id} class="ag-msg">
            <span class="muted">{clock(m.ts)}</span> {m.from} → {m.to}
            {m.kind !== "message" && <span class="muted"> {m.kind}</span>} <span class="ag-body">{m.body}</span>
          </div>
        ))}
      </div>
    </section>
  );
}

/** Its touches are its own: home's swipes under it don't see them. */
const own = {
  onTouchStart: (e: TouchEvent) => e.stopPropagation(),
  onTouchMove: (e: TouchEvent) => e.stopPropagation(),
  onPointerDown: (e: PointerEvent) => e.stopPropagation(),
};

function Screen({ picked }: { picked: string | null }) {
  useAgents();
  const nodes = tree(agentIds.value);
  const id = picked && agent(picked) ? picked : (sessions.value[0] ?? null);
  const scroller = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => scroller.current?.scrollTo(0, 0), []);
  return (
    <div class="ag-screen" {...own}>
      <header class="ag-top">
        <button type="button" class="session-back" onClick={closeAgents}>
          ‹
        </button>
        <span class="ai-title">Agents</span>
        <span class={`ag-live ${live.value ? "on" : ""}`}>{live.value ? "● live" : "○"}</span>
      </header>
      <div class="ag-scroll" ref={scroller}>
        <section class="ag-tree tile">
          {!nodes.length && <div class="muted">No agent reports yet. Agents started with the hooks show here.</div>}
          {nodes.map(({ a, depth }) => (
            <button
              type="button"
              key={a.id}
              class={`ag-node ${a.state} ${a.id === id ? "picked" : ""}`}
              style={{ paddingLeft: `${8 + depth * 16}px` }}
              onClick={() => (agentsView.value = { id: a.id })}
            >
              <span class="ag-mark">{mark(a)}</span>
              <span class="ag-who">
                {a.role}
                {!isSub(a) && <span class="muted"> ({a.host})</span>}
              </span>
              <span class="ag-what">{doing(a)}</span>
              {a.state === "working" && a.step && isSub(a) && <span class="muted ag-step">{a.step}</span>}
              <span class="ag-ago muted">{since(a.last)}</span>
            </button>
          ))}
        </section>
        <Asks />
        {id && <Detail id={id} />}
        <Comms />
      </div>
    </div>
  );
}

/** The Agents screen over home while it's open; opened by the agents' notification too. */
export function AgentsScreen() {
  useEffect(() => {
    // Tapped while this page wasn't there yet (a cold start), or now.
    powos.agents.takeOpen().then(
      (open) => open && openAgents(null),
      () => {},
    );
    return powos.on("agents.open", () => {
      powos.agents.takeOpen();
      openAgents(null);
    });
  }, []);
  const v = agentsView.value;
  return v ? <Screen picked={v.id} /> : null;
}
