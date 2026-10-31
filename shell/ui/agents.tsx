/**
 * The Agents view, in plain words (shell/fleet.ts): what each agent is doing, how far along, and who needs the user.
 *
 * - AgentsPanel: home's Agents widget (a "panel" home item). One tile per agent at work - needs-attention first (red,
 *   its plain reason and one tap: restart / allow), then the working ones by recent activity: the task's words, a thin
 *   progress bar, its step now. The head says "N working · N need you". Idle and finished agents aren't in it; the
 *   manager shows only while it works. 2x2: the count and the top task; 4x2: four tiles; bigger: more.
 * - AgentsView: the screen - the manager's row, "Needs attention", "Working now" (a card each: task, progress, step,
 *   how long, device), and the rest folded into one line ("12 idle · 14 done today"). A tap opens that agent's live
 *   view: its steps so far, its activity (read-only), its last report, message / stop. Its own component, so PowOS AI
 *   (or anything) can show it: openAgents(id) puts it over home (AgentsScreen).
 *
 * Its data is agents.ts (one signal per agent) through fleet.ts (agent ↔ board task).
 */
import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";
import { powos } from "../bridge.ts";
import { holdRefresh } from "./refresh.ts";
import { agent, agentsView, asks, closeAgents, live, messages, openAgents, recent, since, tasks, useAgentEvents, useAgents } from "../agents.ts";
import { fleet, headline, ownWords, restartNote, shorten, stepsOf, taskOf, workRows, type Fleet, type Step, type WorkLite, type Worker } from "../fleet.ts";
import { DbConnection as AgentsDb } from "../vendor/powos-agents.js";
import { useDb, useRows } from "../apps/stdb.ts";
import { takeTap } from "./taps.ts";
import type { Agent, AgentEvent, AgentTask, HomeItem } from "../types.ts";

/** "4m", "1h 5m": how long [ms] milliseconds took. */
const took = (ms: number) => {
  const m = Math.round(ms / 60_000);
  if (m < 1) return `${Math.max(1, Math.round(ms / 1000))}s`;
  return m < 60 ? `${m}m` : `${Math.floor(m / 60)}h${m % 60 ? ` ${m % 60}m` : ""}`;
};

/** Plain sentences for the non-tool events, by kind. */
const KIND_SENTENCE: Record<string, (h: string, name: string) => string> = {
  prompt: (h) => (h ? `asked: ${h}` : "was asked something"),
  stop: () => "finished its turn",
  sub_start: (h, n) => `started helper: ${h || n}`,
  sub_stop: (h, n) => `helper done: ${h || n}`,
  fail: (h) => `failed: ${h}`,
  compact: () => "compacted its context",
  notify: (h) => h || "notified you",
};
/** And for tools, by name. */
const TOOL_SENTENCE: Record<string, (h: string) => string> = {
  Read: (h) => `read ${h || "a file"}`,
  NotebookRead: (h) => `read ${h || "a file"}`,
  Edit: (h) => `edited ${h || "a file"}`,
  MultiEdit: (h) => `edited ${h || "a file"}`,
  NotebookEdit: (h) => `edited ${h || "a file"}`,
  Write: (h) => `wrote ${h || "a file"}`,
  Grep: () => "searched the code",
  Glob: () => "searched the code",
  Agent: (h) => `started helper: ${h}`,
  Task: (h) => `started helper: ${h}`,
  Bash: (h) =>
    /gate\.sh/.test(h) ? "ran the shell gate" : /land\.sh|push/.test(h) ? "landed the change" : h ? `ran: ${h}` : "ran a command",
};

/** A tool event as a short plain sentence for the timeline ("edited gesture.ts", "ran a command"). */
function sentence(e: AgentEvent) {
  const h = e.hint && e.hint !== e.name ? e.hint : "";
  if (e.kind !== "tool") return (KIND_SENTENCE[e.kind] ?? (() => e.kind))(h, e.name);
  return (TOOL_SENTENCE[e.name] ?? ((x: string) => (x ? `${e.name}: ${x}` : e.name)))(h);
}

const clock = (ms: number) => new Date(ms).toTimeString().slice(0, 5);

/** A button on the widget: its tap is its own (not the tile's, not the line's). */
const tapOnly = (run: () => void) => ({
  onPointerUp: takeTap,
  onClick: (e: Event) => {
    e.stopPropagation();
    run();
  },
});

/** Tool calls as §1.3's "Read×6 · Bash ✗ (2s)": the coalesced rows, latest last. */
function Tool({ e }: { e: AgentEvent }) {
  return (
    <div class={`ag-tool ${e.ok === false ? "fail" : ""}`} title={e.hint}>
      <span class="muted">{clock(e.ts)}</span> {sentence(e)}
      {e.n > 1 && ` ×${e.n}`}
      {e.ok === false && " ✗"}
      {e.ms >= 2000 && <span class="muted"> ({Math.round(e.ms / 1000)}s)</span>}
    </div>
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
function Asks({ only }: { only?: string } = {}) {
  const open = asks.value.filter((x) => x.answer == null && (!only || x.agent === only));
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


/**
 * The board's tasks while the fleet shows and an agent holds one (the words, steps and progress the lines say). The
 * connection is apps/stdb.ts's, shared with PowOS AI's board by database name; it goes 5 s after nothing shows it.
 */
function BoardFeed() {
  const db = useDb("powos-agents", AgentsDb);
  const rows = useRows<WorkLite>(db, "work", "SELECT * FROM work");
  useEffect(() => {
    if (db.status === "connected" && rows.length) workRows.value = new Map(rows.map((r) => [r.id, r]));
  }, [rows, db.status]);
  return null;
}
const needsBoard = (f: Fleet) => [...f.working, ...f.attention, ...(f.manager ? [f.manager] : [])].some((x) => !!x.a.work);

/** The one action of an attention line: restart (the manager does it), allow the open ask, or open its live view. */
function act(x: Worker) {
  if (x.action === "restart") powos.agents.message("manager", restartNote(x));
  else if (x.action === "answer") {
    const ask = asks.value.find((k) => k.agent === x.a.id && k.answer == null);
    if (ask) powos.agents.answer(ask.id, "allow");
  } else openAgents(x.a.id);
}
const ACT_LABEL = { restart: "restart", answer: "allow", open: "open" } as const;

/** A thin progress bar: step [done + 1] of [total] (nothing without a plan). */
function Bar({ done, total }: { done: number; total: number }) {
  if (!total) return null;
  return (
    <div class="fl-bar" role="progressbar" aria-valuemin={0} aria-valuemax={total} aria-valuenow={done}>
      <i style={{ width: `${Math.max(4, (100 * done) / total)}%` }} />
    </div>
  );
}
const stepLabel = (x: Worker) => (!x.total ? "" : x.done >= x.total ? "all steps done" : `step ${x.done + 1} of ${x.total}`);

/** A tile's inner box (px) and type size: what its lines are fitted to (the font is monospace: ~0.62 em a char). */
interface Box {
  w: number;
  h: number;
  font: number;
  /** One character's width at [font], measured (the shell's font is monospace). */
  ch: number;
}
const cols = (b: Box, scale = 1) => Math.max(4, Math.floor(b.w / (b.ch * scale)) - 1);

/** [el]'s font's character width (px; 0.62 em when it can't be measured). */
function charWidth(el: HTMLElement, font: number) {
  const cs = getComputedStyle(el);
  const g = document.createElement("canvas").getContext("2d");
  if (!g) return 0.62 * font;
  g.font = `${cs.fontWeight} ${cs.fontSize} ${cs.fontFamily}`;
  return g.measureText("0123456789".repeat(4)).width / 40 || 0.62 * font;
}

/** How many lines [text] takes at [n] characters a line (monospace: word wrapping is counting). */
function wrapped(text: string, n: number) {
  let lines = 1;
  let used = 0;
  for (const word of text.split(/\s+/).filter(Boolean)) {
    const need = used ? used + 1 + word.length : word.length;
    if (need <= n) used = need;
    else if (word.length <= n) (lines++, (used = word.length));
    else (lines += Math.ceil(word.length / n) - (used ? 0 : 1), (used = word.length % n || n));
  }
  return lines;
}

/** [text] cut at a word so it fits [lines] lines of [n] characters, never cut by the box. */
function fit(text: string, n: number, lines: number) {
  let max = n * lines;
  let t = shorten(text, max);
  while (max > 4 && wrapped(t, n) > lines) t = shorten(text, (max -= Math.max(1, Math.floor(n / 4))));
  return t;
}

const ICON = { restart: "↻", answer: "allow", open: "›" } as const;

/**
 * One agent at work, as a widget tile: its task (a stuck one: why, in red, and its one action), its step now while
 * there's room, and a thin progress line along its foot - as many lines as fit its box, never cut.
 */
function Tile({ x, box, manager }: { x: Worker; box: Box; manager?: boolean }) {
  const bad = !!x.reason;
  const f = box.font;
  const stoppable = manager && x.a.host === "phone" && x.a.state === "working" && x.a.pid > 1;
  const n = cols(box);
  const wide = n >= 30;
  const label = bad && x.action ? (wide ? ACT_LABEL[x.action] : ICON[x.action]) : stoppable ? "■" : "";
  const first = bad ? x.reason! : manager ? `Manager: ${x.now}` : x.title;
  const second = bad ? x.title : manager ? "" : x.now;
  // Lines: the first gets one (two on a tall tile), the second (0.85 em) what's left, up to three.
  const total = Math.max(1, Math.floor(box.h / (1.25 * f)));
  const firstLines = total >= 4 && !second ? Math.min(3, total) : total >= 4 ? 2 : 1;
  const secondLines = second ? Math.min(3, Math.floor((box.h - firstLines * 1.25 * f) / (1.1 * f))) : 0;
  return (
    <div role="button" tabIndex={0} class={`fl-tile ${bad ? "bad" : ""}`} onPointerUp={takeTap} onClick={() => openAgents(x.a.id)}>
      <div class="fl-t1">
        <span class="fl-t1-text">{fit(first, n - (label ? label.length + 3 : 0), firstLines)}</span>
        {label && (
          <button
            type="button"
            class={bad ? "fl-icon danger" : "fl-icon"}
            aria-label={bad && x.action ? ACT_LABEL[x.action] : "stop its turn"}
            {...tapOnly(() => (bad ? act(x) : powos.agents.interrupt(x.a.id)))}
          >
            {label}
          </button>
        )}
      </div>
      {secondLines > 0 && <div class="fl-t2 muted">{fit(second, cols(box, 0.85), secondLines)}</div>}
      {!bad && x.total > 0 && <Bar done={x.done} total={x.total} />}
    </div>
  );
}

const HINT = "Ask PowOS AI for one, or start claude in a terminal";

/** Nobody at work: one card for the whole list - what's idle or done, else how to start one. */
function Idle({ box, f }: { box: Box; f: Fleet }) {
  const rest = f.idle.length + f.older.length;
  const counts = [rest ? `${rest} idle` : "", f.doneToday.length ? `${f.doneToday.length} done today` : ""].filter(Boolean).join(" · ");
  const line = counts || HINT;
  const fits = (lines: number) => lines * 1.3 * box.font <= box.h;
  const big = fits(4);
  return (
    <div role="button" tabIndex={0} class={`ag-card ag-idle ${big ? "big" : ""}`} onPointerUp={takeTap} onClick={() => openAgents()}>
      {big && <div class="ag-big">○</div>}
      <div class="ag-c1">
        <span class="ag-who">No agent working</span>
      </div>
      {fits(2) && <div class="ag-c2 muted">{shorten(line, cols(box) * Math.max(1, Math.floor(box.h / (1.3 * box.font)) - (big ? 3 : 1)))}</div>}
    </div>
  );
}

/** Nobody at work on a small tile or the desktop's home: one muted line, no card. */
function IdleLine({ w, font }: { w: number; font: number }) {
  return (
    <div role="button" tabIndex={0} class="ag-idle-line muted" onPointerUp={takeTap} onClick={() => openAgents()}>
      {(HINT.length + 2) * 0.62 * font <= w ? HINT : "No agent working"}
    </div>
  );
}

/**
 * Home's Agents widget (grid.tsx draws it for a "panel" item named "agents"), on the phone's home and the desktop's.
 * It fills its tile at every size (shell/dev/preview.sh checks it): the tiles in a grid, its columns from the measured
 * width (~13 em a tile), its rows from the height (~1.6 em a tile) - whole tiles only. 2x2 shows
 * the count and the top task.
 */
export function AgentsPanel({ item }: { item: HomeItem }) {
  useAgents();
  const [tw, th] = item.cell ? [item.cell.w, item.cell.h] : (item.size ?? item.minSize ?? [4, 2]);
  const plain = document.documentElement.dataset.mode === "desktop" || (tw <= 3 && th <= 2);
  const f = fleet();
  const mgr = f.manager && f.manager.a.state === "working" ? [f.manager] : [];
  const work = [...f.working, ...mgr].sort((x, y) => y.a.last - x.a.last);
  const all = [...f.attention, ...work];
  const list = useRef<HTMLDivElement>(null);
  const [size, setSize] = useState({ w: 0, h: 0, font: 14, ch: 8 });
  useLayoutEffect(() => {
    const el = list.current;
    if (!el) return;
    const measure = () => {
      const font = parseFloat(getComputedStyle(el).fontSize) || 14;
      const next = { w: el.clientWidth, h: el.clientHeight, font, ch: charWidth(el, font) };
      setSize((s) => (s.w === next.w && s.h === next.h && s.font === next.font && s.ch === next.ch ? s : next));
    };
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  const { w, h, font, ch } = size;
  const gap = font * 0.3;
  // A tile: ~13 em wide (a task's words, not a stub of them), ~1.6 em tall at least (a line, its progress along its foot).
  const c0 = Math.max(1, Math.min(3, Math.floor((w + gap) / (font * 13 + gap))));
  const r0 = tw <= 2 && th <= 2 ? 1 : Math.max(1, Math.floor((h + gap) / (font * 1.6 + gap)));
  const shown = w ? all.slice(0, c0 * r0) : [];
  const c = Math.max(1, Math.min(c0, shown.length));
  const r = Math.max(1, Math.ceil(shown.length / c));
  // A tile's inner box (less its padding: .fl-tile's 0.2em 0.55em).
  const box: Box = { w: (w - gap * (c - 1)) / c - 1.1 * font, h: (h - gap * (r - 1)) / r - 0.4 * font, font, ch };
  return (
    <div class="tile ag-panel">
      {needsBoard(f) && <BoardFeed />}
      <div class="ag-in">
        <div class="ag-head">
          <span>Agents</span>{" "}
          <span class={f.attention.length ? "fl-need" : "muted"}>{headline(f)}</span>
        </div>
        <div ref={list} class="ag-list" style={{ gridTemplateColumns: `repeat(${c}, minmax(0, 1fr))`, gridTemplateRows: `repeat(${r}, minmax(0, 1fr))` }}>
          {shown.map((x) => (
            <Tile key={x.a.id} x={x} box={box} manager={mgr[0] === x} />
          ))}
          {w > 0 && !all.length && (plain ? <IdleLine w={w} font={font} /> : <Idle box={box} f={f} />)}
        </div>
      </div>
    </div>
  );
}

/** A device chip ("mac", "phone"). */
const Chip = ({ host }: { host: string }) => <span class="fl-chip">{host}</span>;

/** "running 12m" from its start. */
const running = (a: Agent) => `running ${since(a.started)}`;

/** A working agent's card: its task, the bar and step N of M, what it's doing now, how long, the device. */
function WorkCard({ x }: { x: Worker }) {
  return (
    <button type="button" class="fl-card tile" onClick={() => openAgents(x.a.id)}>
      <div class="fl-c1">
        <span class="fl-title">{x.title}</span>
        <Chip host={x.a.host} />
      </div>
      {x.total > 0 && (
        <div class="fl-prog">
          <Bar done={x.done} total={x.total} />
          <span class="muted">{stepLabel(x)}</span>
        </div>
      )}
      <div class="fl-c3">
        <span class="fl-now">{x.now || "Thinking"}</span>
        <span class="muted fl-ago">{running(x.a)}</span>
      </div>
    </button>
  );
}

/** Something that needs the user: its plain reason, the task, and one action. */
function AttentionCard({ x }: { x: Worker }) {
  return (
    <div class="fl-card fl-bad tile" role="button" tabIndex={0} onClick={() => openAgents(x.a.id)}>
      <div class="fl-c1">
        <span class="fl-title">{x.reason}</span>
        <Chip host={x.a.host} />
      </div>
      <div class="fl-c3">
        <span class="fl-now muted">{x.title}</span>
        {x.action && (
          <button type="button" class="ag-act danger" onClick={(e) => (e.stopPropagation(), act(x))}>
            {ACT_LABEL[x.action]}
          </button>
        )}
      </div>
    </div>
  );
}

/** The manager's own row: what it's doing, in plain words. */
function ManagerRow({ x }: { x: Worker }) {
  const on = x.a.state === "working";
  return (
    <button type="button" class="fl-mgr tile" onClick={() => openAgents(x.a.id)}>
      <span class={`fl-dot ${on ? "on" : ""}`} />
      <span class="fl-mgr-who">Manager</span>
      <span class="fl-now">{x.now}</span>
      <Chip host={x.a.host} />
      <span class="muted fl-ago">{since(x.a.last)}</span>
    </button>
  );
}

/** An idle or finished session, folded under the line: the best words it has, never a raw label. */
function RestRow({ a }: { a: Agent }) {
  const words = taskOf(a.work)?.title || ownWords(a) || `Session in ${a.cwd || a.host}`;
  const tail = a.state === "gone" ? `took ${took(a.last - a.started)}${a.sha ? ` · ${a.sha}` : ""}` : "idle";
  return (
    <button type="button" class={`fl-rest ${a.state}`} onClick={() => openAgents(a.id)}>
      <span class="fl-rest-what">{shorten(words, 70)}</span>
      <span class="muted">{tail}</span>
      <Chip host={a.host} />
      <span class="muted fl-ago">{since(a.last)}</span>
    </button>
  );
}
/** "12 idle · 14 done today", opened by a tap: idle sessions, those done today, then anything older than a day. */
function Folded({ f }: { f: Fleet }) {
  const [open, setOpen] = useState(false);
  const idle = f.idle.length + f.older.length;
  if (!idle && !f.doneToday.length) return null;
  const line = [idle ? `${idle} idle` : "", f.doneToday.length ? `${f.doneToday.length} done today` : ""].filter(Boolean).join(" · ");
  return (
    <section class="fl-fold tile">
      <button type="button" class="fl-fold-head muted" aria-expanded={open} onClick={() => setOpen(!open)}>
        <span>{open ? "▾" : "▸"}</span> {line}
      </button>
      {open && (
        <div class="fl-fold-list">
          {f.idle.map((a) => (
            <RestRow key={a.id} a={a} />
          ))}
          {f.doneToday.map((a) => (
            <RestRow key={a.id} a={a} />
          ))}
          {f.older.length > 0 && <div class="muted fl-sub">older than a day</div>}
          {f.older.map((a) => (
            <RestRow key={a.id} a={a} />
          ))}
        </div>
      )}
    </section>
  );
}

/** The fleet: the manager, what needs the user, what's being worked on, the rest folded; then the comms. */
function List({ f }: { f: Fleet }) {
  return (
    <>
      {f.manager && <ManagerRow x={f.manager} />}
      {f.attention.length > 0 && (
        <section class="fl-sec">
          <h3 class="ai-heading fl-need">Needs attention ({f.attention.length})</h3>
          {f.attention.map((x) => (
            <AttentionCard key={x.a.id} x={x} />
          ))}
        </section>
      )}
      <section class="fl-sec">
        <h3 class="ai-heading muted">Working now ({f.working.length})</h3>
        {!f.working.length && <div class="muted fl-none">No agent is working right now.</div>}
        {f.working.map((x) => (
          <WorkCard key={x.a.id} x={x} />
        ))}
      </section>
      <Folded f={f} />
      <Comms />
    </>
  );
}

/** What [a] is doing now, in words. */
function nowOf(a: Agent, x: Worker | undefined) {
  if (x?.now) return x.now;
  if (a.state === "gone") return "Finished";
  return a.state === "working" ? "Thinking" : "Idle";
}

/** The live card's progress line (none without a plan). */
function LiveProgress({ x }: { x: Worker | undefined }) {
  if (!x || !(x.total > 0)) return null;
  return (
    <div class="fl-prog">
      <Bar done={x.done} total={x.total} />
      <span class="muted">{stepLabel(x)}</span>
    </div>
  );
}

/** The live card's one action (restart / answer; "open" is this view). */
function LiveAct({ x }: { x: Worker | undefined }) {
  if (!x?.action || x.action === "open") return null;
  return (
    <div class="ag-ask-do">
      <button type="button" class="ag-act danger" onClick={() => act(x)}>
        {ACT_LABEL[x.action]}
      </button>
    </div>
  );
}

/** The live view's head card: task, progress, what it's doing now, and its one action. */
function LiveCard({ a, x, title }: { a: Agent; x: Worker | undefined; title: string }) {
  return (
    <section class={`fl-card tile fl-live ${x?.reason ? "fl-bad" : ""}`}>
      <div class="fl-c1">
        <span class="fl-title">{a.role === "manager" ? "Manager" : title}</span>
        <Chip host={a.host} />
      </div>
      {x?.reason && <div class="fl-need">{x.reason}</div>}
      <LiveProgress x={x} />
      <div class="fl-c3">
        <span class="fl-now">{nowOf(a, x)}</span>
        <span class="muted fl-ago">{a.state === "working" ? running(a) : since(a.last)}</span>
      </div>
      <LiveAct x={x} />
    </section>
  );
}

/** The live view's steps: the board's (done, now, next) and the session's own todo list. */
function LiveSteps({ steps, todo }: { steps: Step[]; todo: AgentTask[] }) {
  return (
    <>
      {steps.length > 0 && (
        <section class="fl-sec">
          <h3 class="ai-heading muted">Steps</h3>
          <ol class="fl-steps tile">
            {steps.map((s, i) => (
              <li key={i} class={s.state}>
                <span class="fl-mark">{s.state === "done" ? "✓" : s.state === "current" ? "●" : "○"}</span> {s.text}
              </li>
            ))}
          </ol>
        </section>
      )}
      {todo.length > 0 && (
        <div class="ag-tasks">
          {todo.map((t) => (
            <span key={t.id} class={`ag-task ${t.status}`}>
              {t.status === "done" ? "✓" : t.status === "in_progress" ? "●" : "○"} {t.subject}
            </span>
          ))}
        </div>
      )}
    </>
  );
}

/**
 * One agent, live: its task and progress, the steps so far (the board's: done, now, next), its open asks, its activity
 * as it happens (read-only), its last report, and message / stop.
 */
function LiveView({ id, f }: { id: string; f: Fleet }) {
  useAgentEvents(id);
  const a = agent(id)?.value;
  if (!a) return <div class="muted fl-none">This agent is gone.</div>;
  const x = [...f.attention, ...f.working, ...(f.manager ? [f.manager] : [])].find((w) => w.a.id === id);
  const w = taskOf(a.work);
  const title = x?.title ?? (w?.title || ownWords(a) || `Session in ${a.cwd || a.host}`);
  const steps = stepsOf(w);
  const todo = tasks.value.get(id) ?? [];
  const events = recent.value.agent === id ? recent.value.events.slice(-30) : [];
  return (
    <>
      <LiveCard a={a} x={x} title={title} />
      <LiveSteps steps={steps} todo={todo} />
      <Asks only={id} />
      <section class="fl-sec">
        <h3 class="ai-heading muted">Activity</h3>
        <div class="fl-term tile">
          {!events.length && <div class="muted">Nothing yet.</div>}
          {events.map((e) => (
            <Tool key={e.id} e={e} />
          ))}
        </div>
      </section>
      {a.report && (
        <div class="ag-report tile fl-report">
          <span class="muted">Last report </span>
          {a.report}
        </div>
      )}
      {a.state !== "gone" && <Actions a={a} />}
    </>
  );
}

/**
 * The Agents screen's content - the list, or one agent's live view - with its header. Its own component: PowOS AI (or
 * anything) can show it in place; [onClose] its back from the list.
 */
export function AgentsView({ id, onClose }: { id: string | null; onClose: () => void }) {
  useAgents();
  const f = fleet();
  const scroller = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => scroller.current?.scrollTo(0, 0), [id]);
  const back = () => (id ? (agentsView.value = { id: null }) : onClose());
  return (
    <>
      {needsBoard(f) && <BoardFeed />}
      <header class="ag-top">
        <button type="button" class="session-back" onClick={back}>
          ‹
        </button>
        <span class="ai-title">{id ? "Agent" : "Agents"}</span>
        <span class={f.attention.length ? "fl-need fl-head" : "muted fl-head"}>{headline(f)}</span>
        <span class={`ag-live ${live.value ? "on" : ""}`}>{live.value ? "● live" : "○"}</span>
      </header>
      <div class="ag-scroll" ref={scroller}>
        {id ? <LiveView id={id} f={f} /> : <List f={f} />}
      </div>
    </>
  );
}

function Screen({ picked }: { picked: string | null }) {
  useEffect(() => {
    // Its live updates move the page with no finger on it: 120 Hz for them as for a swipe (refresh.ts).
    const el = document.querySelector(".ag-screen");
    if (!el) return;
    const watch = new MutationObserver(holdRefresh);
    watch.observe(el, { childList: true, subtree: true, characterData: true });
    return () => watch.disconnect();
  }, []);
  return (
    <div class="ag-screen tile sheet" {...own}>
      <AgentsView id={picked && agent(picked) ? picked : null} onClose={closeAgents} />
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
