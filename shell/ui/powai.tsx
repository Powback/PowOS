/**
 * The PowOS AI page: left of home's first page, the whole screen (home, its bar and dock slide away for it). What
 * waits on the user (one card each, what to do), the conversation - the last ask, its steps as they run, its answer -
 * the work in progress (the agents' tasks, live from the powos-agents module's work board: `powos agents task ...`),
 * the agents at work (PowOS's tmux sessions,
 * each with the task its pane's title names, a spinner's mark while it works; a tap opens its terminal), what they told
 * you lately, the whole conversation (folded), and a field to ask it (the mic: hold to talk and send, tap to dictate).
 */
import { useEffect, useRef, useState } from "preact/hooks";
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import { chat, openSession, page, sessionView, stored } from "../state.ts";
import { Pill, hearing, type MicTarget } from "./bar.tsx";
import { ago } from "./time.ts";
import { openAgents } from "../agents.ts";
import { DbConnection as AgentsDb } from "../vendor/powos-agents.js";
import { useDb, useRows } from "../apps/stdb.ts";
import type { AgentMail, AgentSession, ChatItem } from "../types.ts";
import { AppBuild, NewAppAsk, newAppAsk } from "./appbuild.tsx";
import { Units } from "./units.tsx";
import { Item } from "./chat.tsx";
import { Said, Thread, ToolRun, toolLabel } from "./rich.tsx";
import { askQueued, openAssistant } from "./assistant.ts";

const sessions = signal<AgentSession[]>([]);
const mail = signal<AgentMail[]>([]);

powos.on("ai.sessions", (s: AgentSession[]) => (sessions.value = s));
powos.on("ai.mail", (m: AgentMail[]) => (mail.value = m));

/** How often the agents at work are listed again while the page shows. */
const REFRESH_MS = 5000;

/** Claude Code titles its pane with a braille spinner frame while it works (and a mark when it's done). */
const working = (s: AgentSession) => /^[⠀-⣿]/.test(s.title);
const task = (s: AgentSession) => s.title.replace(/^[⠀-⣿✳*·\s]+/, "") || s.command;
const folder = (path: string) => path.split("/").filter(Boolean).at(-1) ?? "~";

// What's typed and not sent yet: kept across reloads (an update mustn't lose it).
const draft = stored("powai.draft");

const send = () => {
  const text = draft.value.trim();
  if (!text) return;
  draft.value = "";
  // false: not into the app switcher - doing that briefly showed the chat activity over home (a black screen).
  powos.ai.send(text, false);
};

const pageMic: MicTarget = {
  typed: () => draft.value,
  heard: (full, sendIt) => {
    draft.value = full;
    if (sendIt) send();
  },
};

/** The latest turn: what was asked, the steps since, and the answer so far. */
function lastTurn(items: ChatItem[]) {
  const at = items.findLastIndex((i) => i.kind === "user");
  if (at < 0) return null;
  const after = items.slice(at + 1);
  return {
    // The question, not the screen text the assistant sends along with it (assist.tsx).
    asked: (items[at] as { text: string }).text.split("\n\n[What's on my screen right now")[0],
    steps: after.filter((i) => i.kind === "tool") as Extract<ChatItem, { kind: "tool" }>[],
    // The answer: what it said after its last step (a reply and the question it ends on are two items).
    answer: after.slice(after.findLastIndex((i) => i.kind !== "assistant" && i.kind !== "note") + 1).filter((i) => i.kind === "assistant").map((i) => (i as { text: string }).text).join("\n\n") || null,
    notes: after.filter((i) => i.kind === "note") as Extract<ChatItem, { kind: "note" }>[],
  };
}

export function Now() {
  // "Create app": its own thread's view (steps, the finished app), or the question that starts one.
  if (chat.value.thread?.kind === "app") return <AppBuild />;
  if (newAppAsk.value) return <NewAppAsk />;
  const { busy, items } = chat.value;
  const turn = lastTurn(items);
  if (!turn) return <div class="ai-empty muted">Ask PowOS AI anything - about PowOS, the phone, your projects.</div>;
  return (
    <section class="ai-card tile">
      <div class="ai-asked">{turn.asked}</div>
      <ToolRun tools={turn.steps} />
      {turn.answer && (
        <div class="ai-answer">
          <Said text={turn.answer} reply={null} />
        </div>
      )}
      {turn.notes.map((n, i) => (
        <div key={i} class={`ai-note ${n.error ? "error" : "muted"}`}>
          {n.text}
        </div>
      ))}
      {busy && !turn.answer && <div class="ai-thinking muted">thinking…</div>}
    </section>
  );
}

/** The conversation before the last exchange, folded ("earlier"): the last exchange is open under it. */
function Earlier() {
  const [open, setOpen] = useState(false);
  const items = chat.value.items;
  const before = items.slice(0, Math.max(0, items.findLastIndex((i) => i.kind === "user")));
  if (!before.length) return null;
  return (
    <section class="ai-history">
      <button type="button" class="ai-fold" onClick={() => setOpen(!open)} aria-expanded={open}>
        {open ? "▾" : "▸"} earlier · {before.filter((i) => i.kind === "user").length}
      </button>
      {open && (
        <div class="chat ai-history-list">
          <Thread items={before} render={(item, reply) => <Item item={item} reply={reply} />} />
        </div>
      )}
    </section>
  );
}

/** A work board row (apps/agents `work`; u64s arrive as bigint). */
export interface WorkRow {
  id: string;
  title: string;
  owner: string;
  status: "working" | "blocked" | "waiting" | "done";
  /** One line: for a "waiting" item, what the user is to do ("Plug the phone into the Mac for the kernel test"). */
  note: string;
  created: bigint | number;
  updated: bigint | number;
  done: bigint | number;
  /** "" on rows from before projects (the module's column default). */
  project: string;
}
/** The board as last seen: shown at once when the page comes back, before the socket has caught up. */
export const board = signal<WorkRow[]>([]);
const boardLive = signal(false);
/** The board has been read at least once (until then an empty list means "not known yet", not "nothing"). */
export const boardSeen = signal(false);
/** Done this long ago or less: under "done recently". */
const RECENT_MS = 24 * 3600 * 1000;
/** Ages show only past this: anything younger is "now-ish" and says nothing. */
const DAY_S = 86400;
/** Needs-you cards shown at once (the conversation stays in view); the rest behind "N more". */
const NEEDS_SHOWN = 3;
/** More open items than this: grouped by project, a quiet header each. */
const GROUP_OVER = 6;
const sec = (ms: bigint | number) => Number(ms) / 1000;

/** Subscribed only while the page shows: the socket goes 5 s after it's left (apps/stdb.ts), so home holds none. */
function WorkFeed() {
  const db = useDb("powos-agents", AgentsDb);
  const rows = useRows<WorkRow>(db, "work", "SELECT * FROM work");
  useEffect(() => {
    if (db.status !== "connected") return;
    if (rows.length) {
      board.value = rows;
      boardSeen.value = true;
      return;
    }
    // Empty: the subscription's first rows come a moment after the connection, so the board as last seen stays
    // until it's still empty a while later.
    const t = window.setTimeout(() => {
      board.value = [];
      boardSeen.value = true;
    }, 1500);
    return () => clearTimeout(t);
  }, [rows, db.status]);
  useEffect(() => {
    boardLive.value = db.status === "connected";
  }, [db.status]);
  return null;
}

/**
 * Answered here, until the board says so (the manager marks it): id -> the `updated` it had, so a later change to
 * the item (asked again) shows it again.
 */
const answered = signal<Record<string, number>>({});
const isAnswered = (w: WorkRow) => answered.value[w.id] === Number(w.updated);

/**
 * Done / skip: told to the manager in the one conversation (it owns the board; the page's database connection
 * can't write it), and the card goes at once.
 */
function answer(w: WorkRow, how: "done" | "skip") {
  answered.value = { ...answered.value, [w.id]: Number(w.updated) };
  askQueued(how === "done" ? `Done: ${w.note || w.title} (task ${w.id})` : `Skip for now: ${w.note || w.title} (task ${w.id})`);
}

/** What waits on the user: one card each, saying what to do; a tap asks about it, done / skip answer it. */
function NeedsYou() {
  const [all, setAll] = useState(false);
  const items = board.value.filter((w) => w.status === "waiting" && !isAnswered(w)).sort((a, b) => Number(b.updated) - Number(a.updated));
  if (!items.length) return null;
  const shown = all ? items : items.slice(0, NEEDS_SHOWN);
  return (
    <section class="ai-needs">
      <h3 class="ai-heading">needs you</h3>
      {shown.map((w) => (
        <div key={w.id} class="ai-need tile">
          <button type="button" class="ai-need-body" onClick={() => openAssistant({ text: `About "${w.title}": ` })}>
            <span class="ai-need-do">{w.note || w.title}</span>
            {w.note && <span class="ai-need-what">{w.title}</span>}
          </button>
          <span class="ai-need-acts">
            <button type="button" class="ai-need-act" onClick={() => answer(w, "skip")}>
              skip
            </button>
            <button type="button" class="ai-need-act" onClick={() => answer(w, "done")}>
              done
            </button>
          </span>
        </div>
      ))}
      {items.length > shown.length && (
        <button type="button" class="ai-fold" onClick={() => setAll(true)}>
          ▸ {items.length - shown.length} more
        </button>
      )}
    </section>
  );
}

/** One open item: a dot, its title (up to two lines), its age past a day; a tap shows its note. */
function WorkLine({ w, open, onTap }: { w: WorkRow; open: boolean; onTap: () => void }) {
  const at = sec(w.status === "done" && Number(w.done) ? w.done : w.updated);
  return (
    <button type="button" class={`ai-item ${w.status}`} onClick={onTap} aria-expanded={open}>
      <span class={`ai-dot ${w.status === "working" ? "on" : ""}`} />
      <span class="ai-item-main">
        <span class="ai-item-title">{w.title}</span>
        {open && w.note && <span class="ai-item-note">{w.note}</span>}
      </span>
      {Date.now() / 1000 - at > DAY_S && <span class="ai-item-age">{ago(at)}</span>}
    </button>
  );
}

/** A folded line ("paused · 3"): a tap opens what it holds. */
function Fold({ label, rows, opened, tap }: { label: string; rows: WorkRow[]; opened: string | null; tap: (id: string) => void }) {
  const [open, setOpen] = useState(false);
  if (!rows.length) return null;
  return (
    <>
      <button type="button" class="ai-fold" onClick={() => setOpen(!open)} aria-expanded={open}>
        {open ? "▾" : "▸"} {label} · {rows.length}
      </button>
      {open && rows.map((w) => <WorkLine key={w.id} w={w} open={opened === w.id} onTap={() => tap(w.id)} />)}
    </>
  );
}

const projectOf = (w: WorkRow) => w.project || "Other";

/**
 * In progress: what's being worked on, newest first - a dot and the title each. Grouped by project only when there are
 * many. What's paused (blocked) and what's done lately are folded lines under it.
 */
function Work({ shown }: { shown: boolean }) {
  const [opened, setOpened] = useState<string | null>(null);
  const all = [...board.value].sort((a, b) => Number(b.updated) - Number(a.updated));
  const working = all.filter((w) => w.status === "working");
  const paused = all.filter((w) => w.status === "blocked");
  const now = Date.now();
  const done = all.filter((w) => w.status === "done" && now - Number(w.done || w.updated) < RECENT_MS);
  const tap = (id: string) => setOpened(opened === id ? null : id);
  // Groups in the order of their newest activity (working is newest first, so first seen = newest).
  const groups = new Map<string, WorkRow[]>();
  for (const w of working) groups.set(projectOf(w), [...(groups.get(projectOf(w)) ?? []), w]);
  const grouped = working.length > GROUP_OVER && groups.size > 1;
  return (
    <section class="ai-work-list">
      {shown && <WorkFeed />}
      <h3 class="ai-heading">
        in progress
        {!boardLive.value && shown && <span> · connecting…</span>}
      </h3>
      {grouped
        ? [...groups].map(([p, ws]) => (
            <div key={p} class="ai-group">
              <div class="ai-group-name">{p}</div>
              {ws.map((w) => (
                <WorkLine key={w.id} w={w} open={opened === w.id} onTap={() => tap(w.id)} />
              ))}
            </div>
          ))
        : working.map((w) => <WorkLine key={w.id} w={w} open={opened === w.id} onTap={() => tap(w.id)} />)}
      {!working.length && <div class="ai-work-empty muted">{boardSeen.value ? "nothing in progress" : "…"}</div>}
      <Fold label="paused" rows={paused} opened={opened} tap={tap} />
      <Fold label="done recently" rows={done} opened={opened} tap={tap} />
    </section>
  );
}

function AtWork() {
  const list = [...sessions.value].sort((a, b) => Number(working(b)) - Number(working(a)) || b.activity - a.activity);
  if (!list.length) return null;
  return (
    <section>
      <h3 class="ai-heading muted">at work</h3>
      {list.map((s) => (
        <button
          type="button"
          key={s.name}
          class={`ai-session tile ${sessionView.value?.name === s.name ? "opened" : ""}`}
          onClick={(e) => openSession(s.name, e.currentTarget as HTMLElement, task(s))}
        >
          <span class={`ai-dot ${working(s) ? "on" : ""}`} />
          <span class="ai-session-main">
            <span class="ai-session-task">{task(s)}</span>
            <span class="ai-session-meta muted">
              {s.name} · {folder(s.path)} · {ago(s.activity)}
            </span>
          </span>
        </button>
      ))}
    </section>
  );
}

/** Read: out of the feed at once (the host's "ai.mail" confirms), its notification and inbox entry gone too. */
function readMail(m: AgentMail) {
  mail.value = mail.value.filter((x) => x !== m);
  // ?.: an APK from before mailRead (the page is hot-pushed ahead of it) has no such call.
  if (m.id) powos.ai.mailRead?.(m.id);
}

/** The unread mail agents sent the user: dismissed one by one (×) or all at once - read everywhere. */
function FromAgents() {
  if (!mail.value.length) return null;
  return (
    <section>
      <h3 class="ai-heading muted ai-mail-bar">
        <span>from agents</span>
        <button
          type="button"
          class="ai-mail-clear"
          onClick={() => {
            mail.value = [];
            powos.ai.mailClear?.();
          }}
        >
          clear all
        </button>
      </h3>
      {mail.value.slice(0, 5).map((m) => (
        <div key={m.id ?? `${m.from}-${m.time}`} class="ai-mail tile">
          <div class="ai-mail-head muted">
            <span>
              {m.from} · {ago(m.time)}
            </span>
            <button type="button" class="ai-mail-x" aria-label="mark read" onClick={() => readMail(m)}>
              ×
            </button>
          </div>
          <div class="ai-mail-text">{m.text}</div>
        </div>
      ))}
    </section>
  );
}

/** Its sessions and mail, read when it comes into view and every few seconds while it shows (not while hidden). */
function useAiRefresh(shown: boolean) {
  useEffect(() => {
    if (!shown) return;
    powos.ai.sessions();
    powos.ai.mail().then((m) => (mail.value = m));
    // Not while home is behind an app or the screen is off: asked again as it shows.
    const timer = window.setInterval(() => document.hidden || powos.ai.sessions(), REFRESH_MS);
    const vis = () => document.hidden || powos.ai.sessions();
    document.addEventListener("visibilitychange", vis);
    return () => {
      clearInterval(timer);
      document.removeEventListener("visibilitychange", vis);
    };
  }, [shown]);
}

/** Its header: the name and what the manager is doing. */
export function AiHeader() {
  const { busy, items } = chat.value;
  const step = busy ? [...items].reverse().find((i) => i.kind === "tool" && i.ok == null) : null;
  return (
    <header class="ai-top">
      <span class="ai-title">PowOS AI</span>
      <span class={`ai-state ${busy ? "busy" : ""}`}>
        {busy ? `working${step && step.kind === "tool" ? ` · ${toolLabel(step)}` : "…"}` : "ready"}
      </span>
      <button type="button" class="ai-open" onClick={() => powos.ai.open()}>
        open ↗
      </button>
    </header>
  );
}

/**
 * What PowOS AI shows (the page now, the AI panel next - the same content in whatever holds it): what needs the user
 * (only when something does), the conversation (the last exchange open, the earlier folded), the work board (in
 * progress; paused and done folded), units, the agents. [shown]: on screen - its feeds run only then.
 */
export function AiContent({ shown }: { shown: boolean }) {
  useAiRefresh(shown);
  return (
    <>
      <NeedsYou />
      <Earlier />
      <Now />
      {/* The board: work in progress, what's installed and running, the agents - one surface, its parts by spacing. */}
      <section class="ai-board tile">
        <Work shown={shown} />
        <Units shown={shown} />
        <button type="button" class="ai-session tile" onClick={() => openAgents()}>
          <span class="ai-dot" />
          <span class="ai-session-main">
            <span class="ai-session-task">Agents</span>
            <span class="ai-session-meta muted">what every agent is on: tree, tasks, tools, comms</span>
          </span>
        </button>
      </section>
      <AtWork />
      <FromAgents />
    </>
  );
}

/** Its compose field: ask PowOS AI right here (the mic: hold to talk and send, tap to dictate). */
export function AiCompose() {
  const input = useRef<HTMLTextAreaElement>(null);
  return (
    <form
      class="ai-compose"
      onSubmit={(e) => {
        e.preventDefault();
        send();
      }}
    >
      <Pill
        target={pageMic}
        inputRef={input}
        value={hearing(pageMic) ?? draft.value}
        onInput={(v: string) => (draft.value = v)}
        onFocus={() => powos.keyboard.show()}
        placeholder="ask PowOS AI"
        enterKeyHint="send"
        autocomplete="off"
      />
    </form>
  );
}

export function PowAiPage() {
  const shown = page.value === -1;
  return (
    <div class={`ai-screen ${shown ? "shown" : ""}`}>
      <AiHeader />
      <div class="ai-scroll">
        <AiContent shown={shown} />
      </div>
      <AiCompose />
    </div>
  );
}
