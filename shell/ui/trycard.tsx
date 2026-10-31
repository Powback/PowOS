/**
 * Things to try, as the manager's own chat message (the user, 2026-10-31: "it should be streamlined... I don't like the
 * idea of putting the ready to try thing in whatever boxes"): the comms tool `present_try {title, items: [{id, line,
 * do?}]}` (lib/ai/comms/comms-mcp.py) becomes a ```try block in the conversation (manager.py _rich_block), drawn here
 * as one left-side message - "2 things ready" and a line per board task, each with works / still broken (a thing to do:
 * done / can't / problem), "still broken" opening the reply line (BrokenReply: words, mic, a screenshot). The answer
 * is recorded on the board task as the AI page's board did (recordVerdict: bridge ai.verdict = a user check, FAIL with
 * the words, + the manager's inbox naming the task); shown at once, put back with one plain line if it failed.
 *
 * Registered with rich.tsx's block table on import (rich.tsx can't import this: brokenreply.tsx imports rich.tsx).
 */
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import { askQueued } from "./assistant.ts";
import { BrokenReply, clearBroken, type Broken } from "./brokenreply.tsx";
import { blocks } from "./rich.tsx";

/** A board task as a verdict needs it. */
export interface Tried {
  id: string;
  title: string;
}

/** The manager's mail for a "still broken" reply: the task id first, so it lands linked to the task. */
export const brokenMail = (t: Tried, b: Broken) =>
  `Still broken (task ${t.id}): ${t.title}. The user tried it: "${b.text}"${b.image ? ` - their screenshot: ${b.image}` : ""}`;

/** The told-the-manager fallback (a host without ai.verdict): the same words, in the one conversation. */
const verdictAsk = (t: Tried, works: boolean, b?: Broken) =>
  works
    ? `Works: ${t.title} (task ${t.id}) - I tried it: a user PASS for what was ready, close it if nothing else is open`
    : `${b ? brokenMail(t, b) : `Still broken: ${t.title} (task ${t.id}) - I tried it`} - reopen it with a user FAIL`;

/**
 * The user's verdict on a shipped task: the board's CLI records it (bridge ai.verdict: a user check, FAIL with their
 * words); "still broken" with a reply also goes to the manager's inbox with the task id (agents.message). An older
 * host (no ai.verdict): told to the manager in the conversation. Resolves false when it couldn't be saved.
 */
export function recordVerdict(t: Tried, works: boolean, b?: Broken): Promise<boolean> {
  const send = powos.ai.verdict;
  if (!send) return Promise.resolve((askQueued(verdictAsk(t, works, b)), true));
  const line = b ? `still broken: ${b.text}`.slice(0, 300) : undefined;
  return send(t.id, works, line).then(
    () => {
      if (b) powos.agents.message("manager", brokenMail(t, b)).catch((e) => console.warn(`agents.message ${t.id}:`, e));
      return true;
    },
    (e) => {
      if (/no such call/.test(String(e))) return (askQueued(verdictAsk(t, works, b)), true);
      console.warn(`ai.verdict ${t.id}:`, e);
      return false;
    },
  );
}

/** The manager's mail for "can't / problem" on a thing to do: the task id first, as brokenMail. */
export const cantMail = (t: Tried, b: Broken) =>
  `Can't do it / problem (task ${t.id}): ${t.title}. The user says: "${b.text}"${b.image ? ` - their screenshot: ${b.image}` : ""}`;

/** "Done" on a thing to do: told to the manager in the one conversation (it owns the board). */
export const doneAsk = (t: Tried) => `Done: ${t.title} (task ${t.id})`;

/** "Can't / problem" sent: to the manager's inbox; an older host (the call fails): told in the conversation. */
export function sendCantMail(t: Tried, b: Broken) {
  const mail = cantMail(t, b);
  powos.agents.message("manager", mail).catch((e) => (console.warn(`agents.message ${t.id}:`, e), askQueued(mail)));
}

/** One item of a ```try block: a board task and the plain sentence of what to try (or, [do], what to do). */
interface TryItem {
  id: string;
  line: string;
  do?: boolean;
}
interface TryBlock {
  title?: string;
  items: TryItem[];
}

/** How the user answered an item: kept across reloads (the message stays in the history; its answer with it). */
type Answer = { how: "works" | "broken" | "done" | "cant"; text?: string };
const KEY = "powos.ai.tried";
function load(): Record<string, Answer> {
  try {
    return JSON.parse(localStorage.getItem(KEY) || "{}") as Record<string, Answer>;
  } catch {
    return {};
  }
}
const answers = signal<Record<string, Answer>>(load());
function setAnswer(id: string, a: Answer | null) {
  const { [id]: _, ...rest } = answers.value;
  answers.value = a ? { ...rest, [id]: a } : rest;
  try {
    localStorage.setItem(KEY, JSON.stringify(answers.value));
  } catch {
    // Private storage off: the answer still went to the board; only the mark under it is lost on a reload.
  }
}

/** The item whose reply line is open (one at a time), and the one plain line of a save that failed. */
const replying = signal<string | null>(null);
const failed = signal<Record<string, string>>({});

const taskOf = (it: TryItem): Tried => ({ id: it.id, title: it.line });

/** works / still broken pressed (still broken: with the reply): shown at once, put back if it couldn't be saved. */
async function tryVerdict(it: TryItem, works: boolean, b?: Broken) {
  replying.value = null;
  failed.value = { ...failed.value, [it.id]: "" };
  setAnswer(it.id, works ? { how: "works" } : { how: "broken", text: b?.text });
  if (await recordVerdict(taskOf(it), works, b)) return b && clearBroken(it.id);
  setAnswer(it.id, null);
  failed.value = { ...failed.value, [it.id]: "couldn't save that - try again in a moment" };
  if (b) replying.value = it.id;
}

/** done / can't on a thing to do: to the manager (it owns the board), marked at once. */
function doVerdict(it: TryItem, b?: Broken) {
  replying.value = null;
  if (!b) {
    setAnswer(it.id, { how: "done" });
    return askQueued(doneAsk(taskOf(it)));
  }
  setAnswer(it.id, { how: "cant", text: b.text });
  clearBroken(it.id);
  sendCantMail(taskOf(it), b);
}

const SAID: Record<Answer["how"], string> = { works: "you said it works", broken: "you said it's still broken", done: "you did it", cant: "you said you can't" };

/** One item: its sentence, then its buttons - or, answered, what the user said. */
function TryLine({ it }: { it: TryItem }) {
  const a = answers.value[it.id];
  const open = replying.value === it.id;
  const second = it.do ? "can't / problem" : "still broken";
  const onSend = (b: Broken) => (it.do ? doVerdict(it, b) : void tryVerdict(it, false, b));
  return (
    <div class={`try-item ${a ? "answered" : ""}`}>
      <div class="try-line">{it.line}</div>
      {a ? (
        <div class="try-said muted">
          {SAID[a.how]}
          {a.text ? `: "${a.text}"` : ""}
        </div>
      ) : (
        <div class="try-acts">
          <button type="button" class="ai-act" onClick={() => (it.do ? doVerdict(it) : void tryVerdict(it, true))}>
            {it.do ? "done" : "works"}
          </button>
          <button type="button" class="ai-act" aria-expanded={open} onClick={() => (replying.value = open ? null : it.id)}>
            {second}
          </button>
        </div>
      )}
      {failed.value[it.id] && <div class="try-said error">{failed.value[it.id]}</div>}
      {!a && open && <BrokenReply id={it.id} onSend={onSend} onCancel={() => (replying.value = null)} />}
    </div>
  );
}

/** "2 things ready" when the manager gave no title. */
const titleOf = (t: TryBlock) => t.title?.trim() || `${t.items.length} thing${t.items.length === 1 ? "" : "s"} ready to try`;

/** The manager's message: its title and a line per task, on the left like everything it says. */
export function TryCard({ t }: { t: TryBlock }) {
  return (
    <div class="msg assistant try">
      <div class="try-title">{titleOf(t)}</div>
      {t.items.map((it) => (
        <TryLine key={it.id} it={it} />
      ))}
    </div>
  );
}

/** A ```try body as the manager sent it: only items with a task id and a sentence. */
function read(body: string): TryBlock | null {
  try {
    const t = JSON.parse(body) as TryBlock;
    const items = (Array.isArray(t.items) ? t.items : []).filter((i) => i && typeof i.id === "string" && typeof i.line === "string" && i.id && i.line.trim());
    return items.length ? { title: typeof t.title === "string" ? t.title : undefined, items } : null;
  } catch {
    return null;
  }
}

blocks.try = (body) => {
  const t = read(body);
  return t ? <TryCard t={t} /> : null;
};

/** Things to try still unanswered in [texts] (the manager's messages): the strip's "N to try", each task once. */
export function untried(texts: string[]): number {
  const bodies = texts.flatMap((t) => [...t.matchAll(/```try\s*\n([\s\S]*?)(?:\n```|$)/g)].map((m) => m[1]));
  const ids = bodies.flatMap((b) => read(b)?.items ?? []).map((it) => it.id);
  return new Set(ids.filter((id) => !answers.value[id])).size;
}
