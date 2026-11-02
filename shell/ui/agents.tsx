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
import { fleet, headline, ownWords, restartNote, shorten, stepsOf, taskOf, titleOf, workingNow, workRows, type Fleet, type Step, type WorkLite, type Worker } from "../fleet.ts";
import { DbConnection as AgentsDb } from "../vendor/powos-agents.js";
import { useDb, useRows } from "../apps/stdb.ts";
import { takeTap } from "./taps.ts";
import type { Agent, AgentConvoItem, AgentEvent, AgentTask, ChatItem, HomeItem } from "../types.ts";
import { TermButton, useSessions } from "./terms.tsx";
import { Item } from "./chat.tsx";
import { Thread } from "./rich.tsx";

/** "4m", "1h 5m": how long [ms] milliseconds took. */
export const took = (ms: number) => {
  const m = Math.round(ms / 60_000);
  if (m < 1) return `${Math.max(1, Math.round(ms / 1000))}s`;
  return m < 60 ? `${m}m` : `${Math.floor(m / 60)}h${m % 60 ? ` ${m % 60}m` : ""}`;
};

/**
 * Words only a machine reads (the user, 11-01: "wtf is up with the activity of this agent" - "ran: cd ~/pw/…" ×9,
 * "SubagentHandback", "tail -3 /tmp/…"): a path, a shell command, a tool's internal name. Never shown.
 */
const TECHNICAL = /(^|[\s"'(])(~\/|\.{0,2}\/[\w.-]+\/|\/tmp\b)|\b[\w-]+\.(tsx?|m?js|py|kt|sh|log|json|md)\b|\b(cd|tail|head|cat|grep|rg|git|ls|rm|sed|awk|perl|bash|sh|npm|npx|make|adb|ssh|curl)\s|__|&&|\|/;
/** [h] when it's plain words, else "". */
const plain = (h: string) => (h && !TECHNICAL.test(h) ? h : "");
const isHandback = (name: string) => /handback/i.test(name);

/** Plain sentences for the non-tool events, by kind; any hint that isn't plain words is left out. */
const KIND_SENTENCE: Record<string, (h: string) => string> = {
  prompt: (h) => (h ? `asked: ${h}` : "was asked something"),
  stop: () => "finished its turn",
  sub_start: (h) => (h ? `started a helper: ${h}` : "started a helper"),
  sub_stop: (h) => (h ? `helper done: ${h}` : "a helper finished"),
  fail: () => "a step failed",
  compact: () => "tidied up its notes",
  notify: (h) => h || "notified you",
};

/** A non-tool event (or the hand-back) as a short plain sentence for the timeline. */
function sentence(e: AgentEvent) {
  const h = plain(e.hint && e.hint !== e.name ? e.hint : "");
  if (e.kind === "tool") return h ? `handed back: ${h}` : "handed back its report";
  return (KIND_SENTENCE[e.kind] ?? (() => "did something"))(h);
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

/** The timeline's rows: each run of tool calls one quiet "N steps" line, the rest (and the hand-back) a plain sentence. */
type Row = { key: number; ts: number; text: string; fail?: boolean } | { key: number; ts: number; steps: number; failed: number };
type Steps = Extract<Row, { steps: number }>;
const fails = (e: AgentEvent) => (e.ok === false ? 1 : 0);
/** [e] folded into [last] when that's a steps line; else a new one. */
function addStep(out: Row[], e: AgentEvent) {
  const last = out.at(-1);
  const n = Math.max(1, e.n);
  if (!last || !("steps" in last)) return void out.push({ key: e.id, ts: e.ts, steps: n, failed: fails(e) });
  const s: Steps = last;
  s.steps += n;
  s.failed += fails(e);
  s.ts = e.ts;
}
function activityRows(events: AgentEvent[]): Row[] {
  const out: Row[] = [];
  for (const e of events)
    if (e.kind === "tool" && !isHandback(e.name)) addStep(out, e);
    else out.push({ key: e.id, ts: e.ts, text: sentence(e), fail: e.kind === "fail" });
  return out;
}

const stepsText = (r: Steps, now: boolean) =>
  `${now ? "working" : "worked"} · ${r.steps} step${r.steps > 1 ? "s" : ""}${r.failed ? ` · ${r.failed} failed` : ""}`;
function ActivityRow({ r, now }: { r: Row; now: boolean }) {
  const steps = "steps" in r;
  const fail = !steps && r.fail;
  return (
    <div class={`ag-tool ${steps ? "ag-quiet" : ""} ${fail ? "fail" : ""}`}>
      <span class="muted">{clock(r.ts)}</span> {steps ? stepsText(r, now) : r.text}
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
export function BoardFeed() {
  const db = useDb("powos-agents", AgentsDb);
  const rows = useRows<WorkLite>(db, "work", "SELECT * FROM work");
  useEffect(() => {
    if (db.status === "connected" && rows.length) workRows.value = new Map(rows.map((r) => [r.id, r]));
  }, [rows, db.status]);
  return null;
}
export const needsBoard = (f: Fleet) => [...f.working, ...f.attention, ...(f.manager ? [f.manager] : [])].some((x) => !!x.a.work);

/** The one action of an attention line: restart (the manager does it), allow the open ask, or open its live view. */
export function act(x: Worker) {
  if (x.action === "restart") powos.agents.message("manager", restartNote(x));
  else if (x.action === "answer") {
    const ask = asks.value.find((k) => k.agent === x.a.id && k.answer == null);
    if (ask) powos.agents.answer(ask.id, "allow");
  } else openAgents(x.a.id);
}
export const ACT_LABEL = { restart: "restart", answer: "allow", open: "open" } as const;

/** A thin progress bar: step [done + 1] of [total] (nothing without a plan). */
export function Bar({ done, total }: { done: number; total: number }) {
  if (!total) return null;
  return (
    <div class="fl-bar" role="progressbar" aria-valuemin={0} aria-valuemax={total} aria-valuenow={done}>
      <i style={{ width: `${Math.max(4, (100 * done) / total)}%` }} />
    </div>
  );
}
const stepLabel = (x: Worker) => (!x.total ? "" : x.done >= x.total ? "all steps done" : `step ${x.done + 1} of ${x.total}`);

/** A tile's inner box (px) and type size: what picks its lines (the theme font, --font-body: proportional by default, ~0.55 em a char). */
interface Box {
  w: number;
  h: number;
  font: number;
}
/** About how many characters a line of [b] holds (an estimate for picking words). */
const cols = (b: Box, scale = 1) => Math.max(4, Math.floor(b.w / (0.55 * b.font * scale)) - 1);

let pen: CanvasRenderingContext2D | null | undefined;
/** [text]'s width (px) in the theme font (--font-body: UI or Mono, Settings > Style) at [px], [weight]; ~0.55 em a char unmeasurable. */
function textWidth(text: string, px: number, weight = 400) {
  pen ??= document.createElement("canvas").getContext("2d");
  if (!pen) return text.length * 0.55 * px;
  pen.font = `${weight} ${px}px ${getComputedStyle(document.documentElement).getPropertyValue("--font-body") || "sans-serif"}`;
  return pen.measureText(text).width;
}

/** [text] cut at a word (with "…") so one line of it fits [w] px at [px]: never cut mid-word or by the box. */
function fitLine(text: string, w: number, px: number, weight = 400) {
  const words = text.split(" ");
  for (let k = words.length; k > 0; k--) {
    const t = k === words.length ? text : `${words.slice(0, k).join(" ").replace(/[\s,.;:-]+$/, "")}…`;
    if (textWidth(t, px, weight) <= w) return t;
  }
  return shorten(text, Math.max(2, Math.floor(w / (0.55 * px))));
}

/** A row's height in em at most: padding, the title's line, a bar under it; [second]: the step's line too. */
const tileEm = (second: boolean) => 0.5 + 1.35 + 0.45 + (second ? 0.85 * 1.35 + 0.25 : 0);

/** shorten(), but never inside a word while the text has a space before [max] ("Can't…", not "Can't sta…"). */
function atWord(text: string, max: number) {
  if (text.length <= max) return text;
  const at = text.slice(0, Math.max(1, max - 1)).lastIndexOf(" ");
  return at > 0 ? `${text.slice(0, at).replace(/[\s,.;:-]+$/, "")}…` : shorten(text, max);
}

const ICON = { restart: "↻", answer: "allow", open: "›" } as const;

/** A widget row's words: the first line (a stuck one: why; the manager: what it does) and the step's line under it. */
function tileWords(x: Worker, manager?: boolean): [string, string] {
  if (x.reason) return [x.reason, x.title];
  return manager ? [`Manager: ${x.now}`, ""] : [x.title, x.now];
}

/** A row's one button: a stuck one's action ([wide]: its word, else its icon), the phone manager's stop; "" none. */
function tileLabel(x: Worker, wide: boolean, manager?: boolean) {
  if (x.reason) return x.action ? (wide ? ACT_LABEL[x.action] : ICON[x.action]) : "";
  return manager && x.a.host === "phone" && x.a.state === "working" && x.a.pid > 1 ? "■" : "";
}

/** A row's title room (px): the row less its button, if any (0.85 em type, 0.45 em padding a side, 0.4 em gap). */
const titleRoom = (box: Box, label: string) => box.w - (label ? textWidth(label, 0.85 * box.font, 700) + 1.3 * box.font : 0);

/**
 * One agent at work, as a widget row: its task on one line (a stuck one: why, in red, and its one action), its step now
 * when the widget has room ([second]), and a thin progress bar UNDER the title when the task has progress (none without)
 * - each line whole, cut only by an ellipsis. A plain row on the widget's glass, set apart by space alone - never a card
 * in the card (the design principles' "no boxes in boxes", the manager 11-01 19:20).
 */
function Tile({ x, box, manager, second }: { x: Worker; box: Box; manager?: boolean; second: boolean }) {
  const bad = !!x.reason;
  const label = tileLabel(x, cols(box) >= 30, manager);
  const [first, next] = tileWords(x, manager);
  return (
    <div role="button" tabIndex={0} class={`fl-tile ${bad ? "bad" : ""}`} onPointerUp={takeTap} onClick={() => openAgents(x.a.id)}>
      <div class="fl-t1">
        <span class="fl-t1-text">{fitLine(first, titleRoom(box, label), box.font, 600)}</span>
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
      {!bad && x.total > 0 && <Bar done={x.done} total={x.total} />}
      {second && next && <div class="fl-t2 muted">{fitLine(next, box.w, 0.85 * box.font)}</div>}
    </div>
  );
}

/** A session that finished lately, in the widget's spare rows: muted, its title and (with room) what it reported. */
function DoneRow({ a, box, second }: { a: Agent; box: Box; second: boolean }) {
  const next = a.report || `done ${since(a.last)} ago`;
  return (
    <div role="button" tabIndex={0} class="fl-tile fl-done muted" onPointerUp={takeTap} onClick={() => openAgents(a.id)}>
      <div class="fl-t1">
        <span class="fl-t1-text">{fitLine(`✓ ${titleOf(a, taskOf(a.work))}`, box.w, box.font, 600)}</span>
      </div>
      {second && <div class="fl-t2">{fitLine(next, box.w, 0.85 * box.font)}</div>}
    </div>
  );
}

/** The type size the widget's rows need: never above [font], small enough that [rows] rows of [em] fit [h] (≥ 10 px). */
const rowFont = (font: number, h: number, rows: number, em: number) => Math.max(10, Math.min(font, h / (rows * (em + 0.3) - 0.3)));

/** [want] rows in [c] columns of [w]x[h] at up to [font]: the type they fit at, and whether the step's line fits too. */
function inColumns(c: number, { w, h, font }: { w: number; h: number; font: number }, want: number) {
  const r0 = Math.max(1, Math.ceil(want / c));
  const second = rowFont(font, h, r0, tileEm(true)) >= font;
  const tf = rowFont(font, h, r0, tileEm(second));
  // A column narrower than ~8 em at that size holds no words worth reading: this many columns doesn't fit.
  const roomy = (w - 0.3 * tf * (c - 1)) / c >= 8 * tf;
  return { c, second, tf: roomy ? tf : 0 };
}

/**
 * The widget's rows: [n0] (from its cell span) of [count], in the columns (1-3) that keep their type largest - a short
 * wide widget lays 4 out 2x2, never 4 squeezed in one column (the user, 11-01 18:26: every line clipped top and bottom)
 * - each at its text's own height, the step's line only when they fit with it at full size; any that still can't fit
 * at 10 px aren't drawn.
 */
function rowsLayout(size: { w: number; h: number; font: number }, n0: number, count: number) {
  const want = size.w ? Math.min(n0, count) : 0;
  const tries = [1, 2, 3].filter((c) => c === 1 || c <= want).map((c) => inColumns(c, size, want));
  const best = tries.reduce((a, b) => (b.tf > a.tf ? b : a));
  const { c, second } = best;
  const tf = best.tf || tries[0].tf || 10;
  const fit = Math.max(1, Math.floor((size.h + 0.3 * tf) / ((tileEm(second) + 0.3) * tf)));
  const n = Math.min(want, c * fit);
  return { c, n, second, tf, slots: c * fit };
}

/** The widget list's class: [rows] agents' rows, each at its own height, the rest empty glass (the preview's fill checks told so). */
const listAttrs = (rows: boolean) => (rows ? { class: "ag-list rows", "data-sparse": "" } : { class: "ag-list" });

/** The sessions done lately for the widget's spare rows: [slots] less the [shown] working ones (none working: none). */
const spareDone = (f: Fleet, shown: number, slots: number) => (shown ? f.doneToday.slice(0, slots - shown) : []);

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
      {(HINT.length + 2) * 0.55 * font <= w ? HINT : "No agent working"}
    </div>
  );
}

/**
 * Home's Agents widget (grid.tsx draws it for a "panel" item named "agents"), on the phone's home and the desktop's.
 * It fills its tile at every size (shell/dev/preview.sh checks it): as many tiles as its cell span holds (a tile per
 * two cells across per row - the same count at any cell height), its columns from the width (~13 em a tile), the
 * rows sharing the height. 2x2 shows
 * the count and the top task.
 */
export function AgentsPanel({ item }: { item: HomeItem }) {
  useAgents();
  const [tw, th] = item.cell ? [item.cell.w, item.cell.h] : (item.size ?? item.minSize ?? [4, 2]);
  const plain = document.documentElement.dataset.mode === "desktop" || (tw <= 3 && th <= 2);
  const f = fleet();
  const mgr = f.manager && f.manager.a.state === "working" ? [f.manager] : [];
  const work = [...workingNow(f), ...mgr].sort((x, y) => y.a.last - x.a.last);
  const all = [...f.attention, ...work];
  const list = useRef<HTMLDivElement>(null);
  const [size, setSize] = useState({ w: 0, h: 0, font: 14 });
  useLayoutEffect(() => {
    const el = list.current;
    if (!el) return;
    const measure = () => {
      // The panel's type (.ag-in's cqmin size): the list's own is the fitted row size set below.
      const font = parseFloat(getComputedStyle(el.parentElement ?? el).fontSize) || 14;
      const next = { w: el.clientWidth, h: el.clientHeight, font };
      setSize((s) => (s.w === next.w && s.h === next.h && s.font === next.font ? s : next));
    };
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  const { w, h, font } = size;
  // How many rows: from the widget's cell span, never its pixels - a row per two cells across per row (4x2: four), 2x2
  // the top task alone; rowsLayout fits them, each at its text's own height.
  const n0 = tw <= 2 && th <= 2 ? 1 : Math.max(1, Math.floor(tw / 2) * th);
  const { c, n, second, tf, slots } = rowsLayout(size, n0, all.length);
  const shown = all.slice(0, n);
  // Rows keep their own height, top-aligned (never stretched to the tile, the manager 11-01 19:20); the rows to spare
  // show what finished lately, muted - none finished: the glass stays empty.
  const done = spareDone(f, shown.length, slots);
  const box: Box = { w: (w - 0.6 * tf * (c - 1)) / c - 0.2 * tf, h, font: tf };
  return (
    <div class="tile ag-panel">
      {needsBoard(f) && <BoardFeed />}
      <div class="ag-in">
        <div class="ag-head">
          <span>Agents</span>{" "}
          <span class={f.attention.length ? "fl-need" : "muted"}>{headline(f)}</span>
        </div>
        <div ref={list} {...listAttrs(shown.length > 0)} data-fit={`${n}+${done.length} rows in ${c} col at ${Math.round(tf)} px in ${w}x${h} (${Math.round(font)} px)`} style={{ fontSize: `${tf}px`, gridTemplateColumns: `repeat(${c}, minmax(0, 1fr))` }}>
          {shown.map((x) => (
            <Tile key={x.a.id} x={x} box={box} manager={mgr[0] === x} second={second} />
          ))}
          {done.map((a) => (
            <DoneRow key={a.id} a={a} box={box} second={second} />
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

/** A working agent's card: its task, the bar and step N of M, what it's doing now, how long, the device; its terminal's button. */
function WorkCard({ x }: { x: Worker }) {
  return (
    <div class="fl-card tile" role="button" tabIndex={0} onClick={() => openAgents(x.a.id)}>
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
        <TermButton a={x.a} />
      </div>
    </div>
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
        <TermButton a={x.a} />
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
function List({ f, foot }: { f: Fleet; foot?: preact.ComponentChildren }) {
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
        <h3 class="ai-heading muted">Working now ({workingNow(f).length})</h3>
        {!workingNow(f).length && <div class="muted fl-none">No agent is working right now.</div>}
        {workingNow(f).map((x) => (
          <WorkCard key={x.a.id} x={x} />
        ))}
      </section>
      <Folded f={f} />
      {foot}
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
 * A user turn of an agent's conversation: its words as PowOS AI's chat draws them, each pasted block folded to
 * "pasted text ▸" (a tap opens it).
 */
function ConvoUser({ item }: { item: { text: string; pasted?: string[] } }) {
  const [open, setOpen] = useState(false);
  const pasted = item.pasted ?? [];
  return (
    <div class="msg user ag-said">
      {item.text}
      {pasted.length > 0 && (
        <button type="button" class="ag-paste" aria-expanded={open} onClick={() => setOpen(!open)}>
          {pasted.length > 1 ? `${pasted.length} pasted texts` : "pasted text"} {open ? "▾" : "▸"}
        </button>
      )}
      {open && pasted.map((t, i) => <pre key={i} class="ag-paste-body">{t}</pre>)}
    </div>
  );
}

/** Thread's [render] for a conversation: one function (rich.tsx EntryView compares it), the user's turns with their pastes folded. */
const renderConvo = (item: Exclude<ChatItem, { kind: "tool" }>, reply: string | null) =>
  item.kind === "user" ? <ConvoUser item={item} /> : <Item item={item} reply={reply} />;

/** The one status chip under a conversation: what the agent is waiting on, or that it's at it; gone: none. */
const WAITING: Partial<Record<Agent["state"], string>> = {
  idle: "waiting for your input",
  needs_you: "waiting for your approval",
  blocked: "stuck - waiting for you",
  paused: "paused",
  working: "working…",
};

/** Kept at the newest as the conversation grows, unless scrolled up to read. */
function useAtEnd(n: number) {
  const ref = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const box = ref.current?.closest<HTMLElement>(".ag-scroll, .ai-scroll");
    if (!box || !n) return;
    const near = box.scrollHeight - box.scrollTop - box.clientHeight < 160 || box.scrollTop === 0;
    if (near) box.scrollTop = box.scrollHeight;
  }, [n]);
  return ref;
}

/**
 * A transcript as the user reads it: the hand-back as its summary (a reply), the tool calls' raw output dropped (their
 * folded "N steps" row opens to plain verbs only: never a command, a path or a log).
 */
const readable = (items: AgentConvoItem[]): AgentConvoItem[] =>
  items.map((i) =>
    i.kind !== "tool"
      ? i
      : isHandback(i.name)
        ? { kind: "assistant", text: plain(i.hint) ? `Handed back: ${i.hint}` : "Handed back its report." }
        : { kind: "tool", name: i.name, hint: "", ok: i.ok },
  );

/**
 * An agent's conversation (the user, 11-01 17:10: "Can't I show the chat properly here?"): its transcript (powos-agentsd
 * convo_of) drawn with PowOS AI's chat - the user's turns as bubbles, the agent's replies in Markdown, tool calls folded
 * into one quiet "N steps" row - and one status chip at the end.
 */
function Convo({ a, items: raw }: { a: Agent; items: AgentConvoItem[] }) {
  const items = readable(raw);
  const ref = useAtEnd(items.length + (items.at(-1)?.kind === "assistant" ? 1 : 0));
  const chip = WAITING[a.state];
  return (
    <section class="fl-sec ag-convo" aria-label="Conversation">
      <div class="ai-chat-in" ref={ref}>
        {!items.length && <div class="muted">Nothing said yet.</div>}
        <Thread items={items} render={renderConvo} />
        {chip && <div class={`ag-wait ${a.state}`}>{chip}</div>}
      </div>
    </section>
  );
}

/** A host without conversations yet (an older APK): the hook events, as before. */
function Activity({ events, working }: { events: AgentEvent[]; working: boolean }) {
  const rows = activityRows(events);
  return (
    <section class="fl-sec">
      <h3 class="ai-heading muted">Activity</h3>
      <div class="fl-term tile ag-activity">
        {!rows.length && <div class="muted">Nothing yet.</div>}
        {rows.map((r, i) => (
          <ActivityRow key={r.key} r={r} now={working && i === rows.length - 1} />
        ))}
      </div>
    </section>
  );
}

/**
 * One agent, live: its task and progress, the steps so far (the board's: done, now, next), its open asks, its
 * conversation as it happens, and message / open terminal / stop at the bottom.
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
  const r = recent.value.agent === id ? recent.value : null;
  return (
    <>
      <LiveCard a={a} x={x} title={title} />
      <LiveSteps steps={steps} todo={todo} />
      <Asks only={id} />
      {r?.convo ? <Convo a={a} items={r.convo} /> : <Activity events={r?.events.slice(-60) ?? []} working={a.state === "working"} />}
      {!r?.convo && a.report && (
        <div class="ag-report tile fl-report">
          <span class="muted">Last report </span>
          {a.report}
        </div>
      )}
      <div class="ag-foot">
        {a.state !== "gone" && <Actions a={a} />}
        <TermButton a={a} />
      </div>
    </>
  );
}

/** One agent live with no header of its own (the folded AI page's agent screen: its header is the page's). */
export function AgentLive({ id }: { id: string }) {
  useAgents();
  useSessions(true);
  return <LiveView id={id} f={fleet()} />;
}

/**
 * The Agents screen's content - the list, or one agent's live view - with its header. Its own component: PowOS AI (or
 * anything) can show it in place; [onClose] its back from the list; [foot]: under the list (the AI page's Agents tab:
 * every host's terminals); [list]: the list drawn instead of the cards (the AI page's Agents tab: aipanes.tsx's rows in
 * the Progress design). The sessions are read while it shows, for its cards' "Open terminal".
 */
export function AgentsView(props: { id: string | null; onClose: () => void; foot?: preact.ComponentChildren; list?: (f: Fleet) => preact.ComponentChildren }) {
  const { id, onClose, foot, list } = props;
  useAgents();
  useSessions(true);
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
        {id ? <LiveView id={id} f={f} /> : list ? list(f) : <List f={f} foot={foot} />}
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
