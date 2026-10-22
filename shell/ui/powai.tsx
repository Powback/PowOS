/**
 * The PowOS AI page: left of home's first page, the whole screen (home, its bar and dock slide away for it). What
 * PowOS AI is doing now - the last ask, its steps as they run, its answer - the work in progress (the agents' tasks, one
 * line each, live from the powos-agents module's work board: `powos agents task ...`), the agents at work (PowOS's tmux sessions,
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

/** The whole conversation, folded under the latest turn: PowOS AI's history (the chat surface shows its newest). */
function History() {
  const [open, setOpen] = useState(false);
  const items = chat.value.items;
  if (items.length < 2) return null;
  return (
    <section class="ai-history">
      <button type="button" class="ai-work ai-work-fold muted" onClick={() => setOpen(!open)}>
        {open ? "▾" : "▸"} earlier · {Math.max(0, items.filter((i) => i.kind === "user").length - 1)}
      </button>
      {open && (
        <div class="chat ai-history-list">
          <Thread items={items} render={(item, reply) => <Item item={item} reply={reply} />} />
        </div>
      )}
    </section>
  );
}

/** A work board row (apps/agents `work`; u64s arrive as bigint). */
interface WorkRow {
  id: string;
  title: string;
  owner: string;
  status: "working" | "blocked" | "waiting" | "done";
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

/** Older than this, a row shows its age; younger, it's just "now-ish" - no number. */
const DAY_MS = 24 * 3600 * 1000;
const ageOf = (w: WorkRow) => Date.now() - Number(w.status === "done" && Number(w.done) ? w.done : w.updated);

/** A row of the board: a status dot and the title (two lines, never cut short); a tap shows its note and details. */
function WorkLine({ w, open, onTap }: { w: WorkRow; open: boolean; onTap: () => void }) {
  const old = ageOf(w) > DAY_MS;
  return (
    <button type="button" class={`ai-work ${w.status} ${open ? "open" : ""}`} onClick={onTap}>
      <span class="ai-work-line">
        <span class={`ai-dot ${w.status === "working" ? "on" : ""} ${w.status}`} />
        <span class="ai-work-title">{w.title}</span>
        {old && <span class="ai-work-meta muted">{ago(sec(w.status === "done" && Number(w.done) ? w.done : w.updated))}</span>}
      </span>
      {open && (
        <span class="ai-work-detail muted">
          {w.note && <span class="ai-work-note">{w.note}</span>}
          <span>
            {w.owner || "nobody yet"} · started {ago(sec(w.created))} ago · {w.id}
          </span>
        </span>
      )}
    </button>
  );
}

/** Needs-you cards set aside here ("later"): until they change (a new note brings one back). */
const skipped = stored("powai.needs.skipped", "{}");
const skippedMap = (): Record<string, number> => {
  try {
    return JSON.parse(skipped.value);
  } catch {
    return {};
  }
};

/**
 * What waits on you, first and only when there's something: one card per item - what to do, in plain words (the
 * task's note), what it's about under it. "done" tells PowOS AI (the board is the agents' to change - it updates it);
 * "later" sets the card aside until the task changes.
 */
function NeedsYou() {
  const later = skippedMap();
  const items = board.value
    .filter((w) => w.status === "waiting" && later[w.id] !== Number(w.updated))
    .sort((a, b) => Number(b.updated) - Number(a.updated));
  if (!items.length) return null;
  const skip = (w: WorkRow) => (skipped.value = JSON.stringify({ ...skippedMap(), [w.id]: Number(w.updated) }));
  return (
    <section class="ai-needs">
      <h3 class="ai-heading">needs you · {items.length}</h3>
      {items.map((w) => (
        <div key={w.id} class="ai-need tile">
          <div class="ai-need-do">{w.note || w.title}</div>
          {w.note && <div class="ai-need-about muted">{w.title}</div>}
          <div class="ai-need-acts">
            <button type="button" class="ai-need-act" onClick={() => powos.ai.send(`Done: ${w.title} (${w.id})`, false)}>
              done
            </button>
            <button type="button" class="ai-need-act quiet" onClick={() => skip(w)}>
              later
            </button>
          </div>
        </div>
      ))}
    </section>
  );
}

/** More than this many in progress: grouped by project, under quiet headers. */
const GROUP_OVER = 6;
const projectOf = (w: WorkRow) => w.project || "Other";
/** A project's name as a header: its last part (PowOS's prefix dropped). */
const projectName = (p: string) => (p.split("·").at(-1) ?? p).trim();

/**
 * In progress: a calm list - a dot and a title per task, newest activity first; grouped by project (quiet headers)
 * only past GROUP_OVER. Paused ones (blocked) fold under one line, done lately under another.
 */
function Work({ shown }: { shown: boolean }) {
  const [opened, setOpened] = useState<string | null>(null);
  const [showPaused, setShowPaused] = useState(false);
  const [showDone, setShowDone] = useState(false);
  const all = [...board.value].sort((a, b) => Number(b.updated) - Number(a.updated));
  const active = all.filter((w) => w.status === "working");
  const paused = all.filter((w) => w.status === "blocked");
  const done = all.filter((w) => w.status === "done" && ageOf(w) < RECENT_MS);
  const tap = (id: string) => setOpened(opened === id ? null : id);
  const line = (w: WorkRow) => <WorkLine key={w.id} w={w} open={opened === w.id} onTap={() => tap(w.id)} />;
  const groups = new Map<string, WorkRow[]>();
  for (const w of active) groups.set(projectOf(w), [...(groups.get(projectOf(w)) ?? []), w]);
  const grouped = active.length > GROUP_OVER && groups.size > 1;
  return (
    <section class="ai-work-list tile">
      <h3 class="ai-heading ai-work-head">
        in progress
        {!boardLive.value && shown && <span class="muted"> · connecting…</span>}
      </h3>
      <div class="ai-work-box">
        {grouped
          ? [...groups].map(([p, ws]) => (
              <div key={p} class="ai-work-group">
                <div class="ai-work-group-head muted">{projectName(p)}</div>
                {ws.map(line)}
              </div>
            ))
          : active.map(line)}
        {!active.length && <div class="ai-work-empty muted">{boardSeen.value ? "nothing in progress" : "…"}</div>}
        {paused.length > 0 && (
          <button type="button" class="ai-work ai-work-fold muted" onClick={() => setShowPaused(!showPaused)}>
            {showPaused ? "▾" : "▸"} paused · {paused.length}
          </button>
        )}
        {showPaused && paused.map(line)}
        {done.length > 0 && (
          <button type="button" class="ai-work ai-work-fold muted" onClick={() => setShowDone(!showDone)}>
            {showDone ? "▾" : "▸"} done recently · {done.length}
          </button>
        )}
        {showDone && done.map(line)}
      </div>
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
 * What PowOS AI shows (the page now, the AI panel next - the same content in whatever holds it): the latest turn, the
 * whole conversation folded, the work board, units, the agents. [shown]: on screen - its feeds run only then.
 */
export function AiContent({ shown }: { shown: boolean }) {
  useAiRefresh(shown);
  return (
    <>
      {/* What waits on you first; then the conversation (its last exchange open, earlier folded); then the board. */}
      <NeedsYou />
      <Now />
      <History />
      {shown && <WorkFeed />}
      {/* The board: in progress, what's installed and running, the agents - one surface, its parts by spacing. */}
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
