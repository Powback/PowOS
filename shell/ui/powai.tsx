/**
 * The PowOS AI page: left of home's first page, the whole screen (home, its bar and dock slide away for it). What
 * PowOS AI is doing now - the last ask, its steps as they run, its answer - the agents at work (PowOS's tmux sessions,
 * each with the task its pane's title names, a spinner's mark while it works; a tap opens its terminal), what they told
 * you lately, and a field to ask it (the mic: hold to talk and send, tap to dictate).
 */
import { useEffect, useRef } from "preact/hooks";
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import { chat, openSession, page, sessionView, stored } from "../state.ts";
import { Mic, hearing, type MicTarget } from "./bar.tsx";
import { ago } from "./time.ts";
import { openAgents } from "../agents.ts";
import type { AgentMail, AgentSession, ChatItem } from "../types.ts";

const sessions = signal<AgentSession[]>([]);
const mail = signal<AgentMail[]>([]);
// What's typed and not sent yet: kept across reloads (an update mustn't lose it).
const draft = stored("powai.draft");

powos.on("ai.sessions", (s: AgentSession[]) => (sessions.value = s));
powos.on("ai.mail", (m: AgentMail[]) => (mail.value = m));

/** How often the agents at work are listed again while the page shows. */
const REFRESH_MS = 5000;

/** Claude Code titles its pane with a braille spinner frame while it works (and a mark when it's done). */
const working = (s: AgentSession) => /^[⠀-⣿]/.test(s.title);
const task = (s: AgentSession) => s.title.replace(/^[⠀-⣿✳*·\s]+/, "") || s.command;
const folder = (path: string) => path.split("/").filter(Boolean).at(-1) ?? "~";

const send = () => {
  const text = draft.value.trim();
  if (!text) return;
  draft.value = "";
  powos.ai.send(text);
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
    answer: (after.filter((i) => i.kind === "assistant").at(-1) as { text: string } | undefined)?.text ?? null,
    notes: after.filter((i) => i.kind === "note") as Extract<ChatItem, { kind: "note" }>[],
  };
}

export function Now() {
  const { busy, items } = chat.value;
  const turn = lastTurn(items);
  if (!turn) return <div class="ai-empty muted">Ask PowOS AI anything - about PowOS, the phone, your projects.</div>;
  return (
    <section class="ai-card tile">
      <div class="ai-asked">{turn.asked}</div>
      {turn.steps.length > 0 && (
        <div class="ai-steps">
          {turn.steps.slice(-6).map((t, i) => (
            <div key={i} class="ai-step">
              <span class={t.ok == null ? "run" : t.ok ? "ok" : "fail"}>{t.ok == null ? "…" : t.ok ? "✓" : "✗"}</span>{" "}
              {t.name} <span class="muted">{t.hint}</span>
            </div>
          ))}
        </div>
      )}
      {turn.answer && <div class="ai-answer">{turn.answer}</div>}
      {turn.notes.map((n, i) => (
        <div key={i} class={`ai-note ${n.error ? "error" : "muted"}`}>
          {n.text}
        </div>
      ))}
      {busy && !turn.answer && <div class="ai-thinking muted">thinking…</div>}
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

export function PowAiPage() {
  const shown = page.value === -1;
  // Listed when the page comes into view, and again while it shows.
  useEffect(() => {
    if (!shown) return;
    powos.ai.sessions();
    powos.ai.mail().then((m) => (mail.value = m));
    const timer = window.setInterval(() => powos.ai.sessions(), REFRESH_MS);
    return () => clearInterval(timer);
  }, [shown]);
  const input = useRef<HTMLInputElement>(null);
  const { busy, items } = chat.value;
  const step = busy ? [...items].reverse().find((i) => i.kind === "tool" && i.ok == null) : null;
  return (
    <div class="ai-screen">
      <header class="ai-top">
        <span class="ai-title">PowOS AI</span>
        <span class={`ai-state ${busy ? "busy" : ""}`}>
          {busy ? `working${step && step.kind === "tool" ? ` · ${step.name}` : "…"}` : "ready"}
        </span>
        <button type="button" class="ai-open" onClick={() => powos.ai.open()}>
          open ↗
        </button>
      </header>
      <div class="ai-scroll">
        <Now />
        <button type="button" class="ai-session tile" onClick={() => openAgents()}>
          <span class="ai-dot" />
          <span class="ai-session-main">
            <span class="ai-session-task">Agents</span>
            <span class="ai-session-meta muted">what every agent is on: tree, tasks, tools, comms</span>
          </span>
        </button>
        <AtWork />
        <FromAgents />
      </div>
      <form
        class="ai-compose tile"
        onSubmit={(e) => {
          e.preventDefault();
          send();
        }}
      >
        <input
          ref={input}
          value={hearing(pageMic) ?? draft.value}
          onInput={(e) => (draft.value = (e.currentTarget as HTMLInputElement).value)}
          onFocus={() => powos.keyboard.show()}
          placeholder="ask PowOS AI"
          enterKeyHint="send"
          autocomplete="off"
        />
        <Mic target={pageMic} />
      </form>
    </div>
  );
}
