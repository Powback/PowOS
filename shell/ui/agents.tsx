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

/** A card's inner box and type size, from the panel's measure: what its lines are fitted to. */
interface Box {
  w: number;
  h: number;
  font: number;
}

/**
 * How many lines [text] takes at [cols] characters a line: the shell's font is monospace, so word wrapping is
 * counting (a word longer than a line breaks anywhere, as .ag-c2's overflow-wrap does).
 */
function wrapped(text: string, cols: number) {
  if (cols < 1) return 99;
  let lines = 1;
  let used = 0;
  for (const word of text.split(/\s+/).filter(Boolean)) {
    const need = used ? used + 1 + word.length : word.length;
    if (need <= cols) used = need;
    else if (word.length <= cols) (lines++, (used = word.length));
    else {
      lines += used ? 1 : 0;
      lines += Math.ceil(word.length / cols) - 1;
      used = word.length % cols || cols;
    }
  }
  return lines;
}

/** The lines a card shows in [box]: its first always; what it's on and its step/report while they fit unwrapped-over. */
function fitLines(box: Box, second: string, third: string) {
  const f = box.font;
  const gap = 0.15 * f;
  const per = (size: number) => Math.floor(box.w / (0.62 * size));
  const one = 1.35 * f;
  const two = one + gap + wrapped(second, per(f)) * 1.25 * f;
  const three = two + gap + wrapped(third, per(0.85 * f)) * 1.25 * 0.85 * f;
  return third && three <= box.h ? 3 : second && two <= box.h ? 2 : 1;
}

/**
 * An agent as a card on the widget: its mark, role and when it last did something; then what it's on and (a tall
 * card) its step or last report - as many of those lines as fit its box, never cut. A tap opens the screen on it;
 * this phone's working agent can be stopped in place (a second tap, so a stray one doesn't).
 */
function Card({ id, box }: { id: string; box: Box }) {
  const a = agent(id)?.value;
  const [sure, setSure] = useState(false);
  useEffect(() => setSure(false), [a?.state]);
  if (!a) return null;
  const stoppable = a.host === "phone" && a.state === "working" && a.pid > 1;
  // A finished one says what it was on (its mark is the ✓), not "done".
  const on = a.state === "gone" ? a.title || "done" : doing(a);
  const what = on + (a.subs > 0 ? ` · ${a.subs} sub` : "");
  const more = (a.state === "working" && a.step ? a.step : a.report) || "";
  const lines = fitLines(box, what, more);
  // When it was: only where it doesn't crowd the role (mark, role, a space, the age, and the stop button's room).
  const ago = since(a.last);
  const roomy = Math.floor(box.w / (0.62 * box.font)) >= a.role.length + ago.length + (stoppable ? 9 : 3);
  return (
    <div role="button" tabIndex={0} class={`ag-card ${a.state}`} onPointerUp={takeTap} onClick={() => openAgents(id)}>
      <div class="ag-c1">
        <span class="ag-mark">{mark(a)}</span>
        <span class="ag-who">{a.role}</span>
        {roomy && <span class="ag-ago muted">{ago}</span>}
        {stoppable && (
          <button type="button" class={`ag-act ${sure ? "danger" : ""}`} {...tapOnly(() => (sure ? (powos.agents.interrupt(a.id), setSure(false)) : setSure(true)))}>
            {sure ? "stop?" : "stop"}
          </button>
        )}
      </div>
      {lines > 1 && (
        <div class="ag-c2">
          {on}
          {a.subs > 0 && <span class="muted"> · {a.subs} sub</span>}
        </div>
      )}
      {lines > 2 && <div class="ag-c3 muted">{more}</div>}
    </div>
  );
}

const HINT = "Ask PowOS AI for one, or start claude in a terminal";

/** Nobody at all: one card for the whole list, its hint while it fits. */
function Idle({ box }: { box: Box }) {
  const hint = fitLines(box, HINT, "") > 1;
  // A tall card: a big mark over the words, centred (the box less the mark's 2.8 em still holds them).
  const big = hint && fitLines({ ...box, h: box.h - 2.8 * box.font }, HINT, "") > 1;
  return (
    <div role="button" tabIndex={0} class={`ag-card ag-idle ${big ? "big" : ""}`} onPointerUp={takeTap} onClick={() => openAgents()}>
      {big && <div class="ag-big">○</div>}
      <div class="ag-c1">
        {!big && <span class="ag-mark">○</span>}
        <span class="ag-who">No agents</span>
      </div>
      {hint && <div class="ag-c2 muted">{HINT}</div>}
    </div>
  );
}

/**
 * Nobody at all, plainly: one muted line, no card - a small tile (3x2 and less: the card was most of it, a box in a
 * box) and the desktop's home (the plate on a plate read as a nested grey box). The hint while it fits on the line.
 */
function IdleLine({ w, font }: { w: number; font: number }) {
  // Monospace-safe: 0.62 em a character (the phone's font ~0.575).
  const text = (HINT.length + 2) * 0.62 * font <= w ? HINT : "No agents";
  return (
    <div role="button" tabIndex={0} class="ag-idle-line muted" onPointerUp={takeTap} onClick={() => openAgents()}>
      {text}
    </div>
  );
}

/** "3 running · 1 needs you" / "2 idle" / "none running". */
function count(ids: string[]) {
  const states = ids.map((id) => agent(id)?.value.state);
  const working = states.filter((s) => s === "working").length;
  const need = states.filter((s) => s === "needs_you").length;
  const parts = [`${working} running`];
  if (need) parts.push(`${need} needs you`);
  if (!working && !need) parts[0] = ids.length ? `${ids.length} idle` : "none running";
  return parts.join(" · ");
}

/**
 * Home's Agents widget (grid.tsx draws it for a "panel" item named "agents"), on the phone's home and the desktop's.
 * It fills its tile at every size (shell/dev/preview.sh checks it): the agents as cards in a grid, the columns from the
 * measured width (~9 em a card), the rows from the height (~2.6 em at least) sharing it - whole cards only, the rest
 * counted in the head. Running ones first, then the sessions that finished lately (the spool keeps them a while), so
 * an idle home still shows what was done; nothing at all is one idle card. A one-row tile puts the head beside them.
 */
export function AgentsPanel({ item }: { item: HomeItem }) {
  useAgents();
  const [tw, th] = item.size ?? item.minSize ?? [4, 2];
  const plain = document.documentElement.dataset.mode === "desktop" || (tw <= 3 && th <= 2);
  const ids = sessions.value;
  const done = agentIds.value
    .map((id) => agent(id)?.value)
    .filter((a): a is Agent => !!a && a.state === "gone" && !isSub(a))
    .sort((x, y) => y.last - x.last)
    .map((a) => a.id);
  const all = [...ids, ...done];
  const list = useRef<HTMLDivElement>(null);
  const [size, setSize] = useState({ w: 0, h: 0, font: 14 });
  useLayoutEffect(() => {
    const el = list.current;
    if (!el) return;
    const measure = () => {
      const next = { w: el.clientWidth, h: el.clientHeight, font: parseFloat(getComputedStyle(el).fontSize) || 14 };
      setSize((s) => (s.w === next.w && s.h === next.h && s.font === next.font ? s : next));
    };
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  const { w, h, font } = size;
  const gap = font * 0.4;
  const cols = Math.max(1, Math.min(3, Math.floor((w + gap) / (font * 9 + gap))));
  const rows = Math.max(1, Math.floor((h + gap) / (font * 2.6 + gap)));
  const shown = w ? all.slice(0, cols * rows) : [];
  const c = Math.max(1, Math.min(cols, shown.length));
  const r = Math.max(1, Math.ceil(shown.length / c));
  // A card's inner box (less its padding: .ag-card's 0.35em 0.6em).
  const box: Box = { w: (w - gap * (c - 1)) / c - 1.2 * font, h: (h - gap * (r - 1)) / r - 0.7 * font, font };
  const hidden = w ? all.length - shown.length : 0;
  return (
    <div class="tile ag-panel">
      <div class="ag-in">
        <div class="ag-head">
          <span>Agents</span>
          <span class="muted">
            {count(ids)}
            {hidden > 0 && ` · +${hidden}`}
          </span>
        </div>
        <InlineAsks max={1} />
        <div ref={list} class="ag-list" style={{ gridTemplateColumns: `repeat(${c}, minmax(0, 1fr))`, gridTemplateRows: `repeat(${r}, minmax(0, 1fr))` }}>
          {shown.map((id) => (
            <Card key={id} id={id} box={box} />
          ))}
          {w > 0 && !all.length && (plain ? <IdleLine w={w} font={font} /> : <Idle box={box} />)}
        </div>
      </div>
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

/** The comms feed: a line each (its body's start); a tap opens the whole body there, every line of it, and closes it. */
function Comms() {
  const [opened, setOpened] = useState<string | null>(null);
  const list = [...messages.value].reverse();
  if (!list.length) return null;
  return (
    <section>
      <h3 class="ai-heading muted">comms</h3>
      <div class="ag-comms tile">
        {list.map((m) => (
          <div
            key={m.id}
            class={`ag-msg ${opened === m.id ? "open" : ""}`}
            role="button"
            tabIndex={0}
            aria-expanded={opened === m.id}
            onClick={() => setOpened(opened === m.id ? null : m.id)}
          >
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
    <div class="ag-screen tile sheet" {...own}>
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
