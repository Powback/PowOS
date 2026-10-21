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
import { Mic, hearing, type MicTarget } from "./bar.tsx";
import { ago } from "./time.ts";
import { openAgents } from "../agents.ts";
import { DbConnection as AgentsDb } from "../vendor/powos-agents.js";
import { useDb, useRows } from "../apps/stdb.ts";
import type { AgentMail, AgentSession, ChatItem } from "../types.ts";
import { AppBuild, NewAppAsk, newAppAsk } from "./appbuild.tsx";
import { Units } from "./units.tsx";
import { Item } from "./chat.tsx";
import { Said, Thread, ToolRun, toolLabel } from "./rich.tsx";
import { GrowField } from "./grow.tsx";

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
        {open ? "▾" : "▸"} the whole conversation · {items.filter((i) => i.kind === "user").length} asked
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
const board = signal<WorkRow[]>([]);
const boardLive = signal(false);
/** The board has been read at least once (until then an empty list means "not known yet", not "nothing"). */
const boardSeen = signal(false);
/** Done this long ago or less: under "done recently". */
const RECENT_MS = 24 * 3600 * 1000;
const STATUS: Record<WorkRow["status"], string> = { working: "working", blocked: "blocked", waiting: "waiting on you", done: "done" };
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

function WorkLine({ w, open, onTap }: { w: WorkRow; open: boolean; onTap: () => void }) {
  return (
    <button type="button" class={`ai-work ${w.status} ${open ? "open" : ""}`} onClick={onTap}>
      <span class="ai-work-line">
        <span class={`ai-dot ${w.status === "working" ? "on" : ""} ${w.status}`} />
        <span class="ai-work-title">{w.title}</span>
        <span class="ai-work-meta">
          {w.owner && <span class="muted">{w.owner} · </span>}
          <span class="ai-work-status">{STATUS[w.status] ?? w.status}</span>
          <span class="muted"> · {ago(sec(w.status === "done" && Number(w.done) ? w.done : w.updated))}</span>
        </span>
      </span>
      {open && (
        <span class="ai-work-detail muted">
          {w.note && <span class="ai-work-note">{w.note}</span>}
          <span>
            {w.owner ? `${w.owner} · ` : "nobody yet · "}started {ago(sec(w.created))} ago · last {ago(sec(w.updated))} ago · {w.id}
          </span>
        </span>
      )}
    </button>
  );
}

/** Which project the chips show ("" = all), and the project groups folded shut: kept across reloads. */
const workFilter = stored("powai.work.project");
const workClosed = stored("powai.work.closed", "[]");
const closedSet = () => {
  try {
    return new Set<string>(JSON.parse(workClosed.value));
  } catch {
    return new Set<string>();
  }
};
const projectOf = (w: WorkRow) => w.project || "Other";
/** A chip's label: short ("UI", "Apps", "STAI") - the project's last part, PowOS's prefix dropped. */
const SHORT: Record<string, string> = {
  "phone ui": "UI",
  "apps platform": "Apps",
  "shopping app": "Shopping",
  spacetimeai: "STAI",
};
const chipLabel = (p: string) => {
  const last = (p.split("·").at(-1) ?? p).trim();
  const known = SHORT[last.toLowerCase()];
  if (known) return known;
  const word = last.split(/\s+/)[0] ?? last;
  return word.charAt(0).toUpperCase() + word.slice(1, 10);
};

/**
 * Work in progress: every agent's task on one line each, grouped by project (a group folds; its header counts what's
 * working and what waits on you), newest activity first in a group and the group with the newest activity first. A
 * chip shows one project alone. What's done lately is folded below.
 */
function Work({ shown }: { shown: boolean }) {
  const [opened, setOpened] = useState<string | null>(null);
  const [showDone, setShowDone] = useState(false);
  const all = [...board.value].sort((a, b) => Number(b.updated) - Number(a.updated));
  const projects = [...new Set(all.filter((w) => w.status !== "done").map(projectOf))];
  const only = projects.includes(workFilter.value) ? workFilter.value : "";
  const mine = (w: WorkRow) => !only || projectOf(w) === only;
  const active = all.filter((w) => w.status !== "done" && mine(w));
  const now = Date.now();
  const done = all.filter((w) => w.status === "done" && mine(w) && now - Number(w.done || w.updated) < RECENT_MS);
  const tap = (id: string) => setOpened(opened === id ? null : id);
  const closed = closedSet();
  const toggle = (p: string) => {
    const c = closedSet();
    c.has(p) ? c.delete(p) : c.add(p);
    workClosed.value = JSON.stringify([...c]);
  };
  // Groups in the order of their newest activity (active is newest first, so first seen = newest).
  const groups = new Map<string, WorkRow[]>();
  for (const w of active) groups.set(projectOf(w), [...(groups.get(projectOf(w)) ?? []), w]);
  return (
    <section class="ai-work-list tile">
      {shown && <WorkFeed />}
      <h3 class="ai-heading ai-work-head">
        work in progress{active.length ? ` · ${active.length}` : ""}
        {!boardLive.value && shown && <span> · connecting…</span>}
      </h3>
      {projects.length > 1 && (
        <div class="ai-work-chips">
          {["", ...projects].map((p) => (
            <button
              type="button"
              key={p || "all"}
              title={p || "all projects"}
              class={`ai-work-chip surface ${only === p ? "on" : ""}`}
              onClick={() => (workFilter.value = p)}
            >
              {p ? chipLabel(p) : "All"}
            </button>
          ))}
        </div>
      )}
      <div class="ai-work-box">
        {[...groups].map(([p, ws]) => {
          const shut = closed.has(p) && !only;
          const working = ws.filter((w) => w.status === "working").length;
          const waiting = ws.filter((w) => w.status === "waiting").length;
          const blocked = ws.filter((w) => w.status === "blocked").length;
          return (
            <div key={p} class="ai-work-group">
              {!only && (
                <button type="button" class="ai-work ai-work-project" onClick={() => toggle(p)}>
                  <span class="ai-work-line">
                    <span class="ai-work-caret muted">{shut ? "▸" : "▾"}</span>
                    <span class="ai-work-title">{p}</span>
                    <span class="ai-work-meta muted">
                      {working} working
                      {waiting > 0 && <span class="ai-work-wait"> · {waiting} waiting</span>}
                      {blocked > 0 && <span class="ai-work-blocked"> · {blocked} blocked</span>}
                    </span>
                  </span>
                </button>
              )}
              {!shut && ws.map((w) => <WorkLine key={w.id} w={w} open={opened === w.id} onTap={() => tap(w.id)} />)}
            </div>
          );
        })}
        {!active.length && <div class="ai-work-empty muted">{boardSeen.value ? "nothing in progress" : "…"}</div>}
        {done.length > 0 && (
          <button type="button" class="ai-work ai-work-fold muted" onClick={() => setShowDone(!showDone)}>
            {showDone ? "▾" : "▸"} done recently · {done.length}
          </button>
        )}
        {showDone && done.map((w) => <WorkLine key={w.id} w={w} open={opened === w.id} onTap={() => tap(w.id)} />)}
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
          <div>{m.text}</div>
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
      <Now />
      <History />
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
      class="ai-compose pill tile"
      onSubmit={(e) => {
        e.preventDefault();
        send();
      }}
    >
      <GrowField
        inputRef={input}
        value={hearing(pageMic) ?? draft.value}
        onInput={(v) => (draft.value = v)}
        onFocus={() => powos.keyboard.show()}
        placeholder="ask PowOS AI"
        enterKeyHint="send"
        autocomplete="off"
      />
      <Mic target={pageMic} />
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
