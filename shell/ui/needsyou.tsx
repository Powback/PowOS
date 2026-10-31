/**
 * What really waits on the user, from the board's facts (the user, 2026-10-31 20:12: "It says it needs me, but how am I
 * supposed to answer?" ... "I answered a bunch of them" ... "those things that have been like fixed shipped"): a board
 * task needs the user only while it has an open try line nobody answered, or waits on them (`waiting`) with something to
 * ask. Done, held by a live agent, confirmed by a passing check of its shipped fix, or answered (here, in the chat's try
 * message, or as the user's check on the board) - never. The CLI's `truth` rule (lib/ai/agents/powos-agents-cli truth())
 * on the page's own rows: its STDB rows carry no truth/why column.
 *
 * ONE selector for every place that says "needs you": Progress's Needs you card and area chips (aiprogress.tsx) and the
 * wide page's Try this column (aipanes.tsx). An answer goes through trycard.tsx's TryLine - the same calls as the chat's
 * present_try card (recordVerdict / doneAsk / sendCantMail / answerMail) and the same answers store, so the row leaves at
 * once and comes back with one plain line when the call failed.
 */
import { useRef } from "preact/hooks";
import { signal } from "@preact/signals";
import { boardState, type BoardCheck } from "../agents.ts";
import { board, checks, noteOf, youChecks, type WorkRow } from "./aiboard.tsx";
import { answers, Said, TryLine, type Answer, type TryItem } from "./trycard.tsx";

/** try: works / still broken; do: done / can't; ask: the question's options or their words. */
export type NeedKind = "try" | "do" | "ask";
export interface Need {
  w: WorkRow;
  kind: NeedKind;
  /** The one plain sentence: what to try, what to do, or the question. */
  line: string;
}

/** A board write lands a moment after the answer that caused it (the CLI's works -> work_try): still the same ask. */
const SLACK_MS = 120_000;
/** The check a user verdict is recorded as (ShellBridge.callVerdict: `--name you`). */
const USER_CHECK = "you";
const DECIDING = new Set(["PASS", "FAIL", "none"]);

/** [w]'s checks that decide, oldest first. */
const decidingOf = (w: WorkRow, cs: BoardCheck[]) => cs.filter((c) => c.task === w.id && DECIDING.has(c.state)).sort((a, b) => Number(a.at) - Number(b.at));

/** Asked again since [at] (ms): the row changed after the answer, past the answer's own write. */
const askedSince = (w: WorkRow, at: number) => Number(w.updated) > at + SLACK_MS;

/** Answered: here / in the chat (not asked again since), or the user's own check is the last word on the board. */
function isAnswered(w: WorkRow, cs: BoardCheck[], said: Record<string, Answer>) {
  const a = said[w.id];
  if (a && !askedSince(w, a.at ?? Infinity)) return true;
  const last = decidingOf(w, cs).at(-1);
  return !!last && last.name === USER_CHECK && !askedSince(w, Number(last.at));
}

/** The fix shipped and its check passed: what the CLI's truth calls done - nothing left for the user to try. */
function confirmed(w: WorkRow, cs: BoardCheck[]) {
  const last = decidingOf(w, cs).at(-1);
  return !!last && last.state === "PASS" && last.shipped !== false && !!w.commits && w.commits !== "[]";
}

/** A question: it ends with a question mark. */
const QUESTION = /\?\s*(\([^)]*\))?\s*$/;
/** A question's options, when it names them: "... (A / B / C)" at its end. */
function optionsOf(note: string): string[] | undefined {
  const m = /\(([^)]+)\)\s*$/.exec(note);
  const opts = m?.[1].split(/\s*[/|]\s*/).filter(Boolean) ?? [];
  return opts.length >= 2 && opts.length <= 4 ? opts : undefined;
}

/** What [w] asks of the user (null: nothing - no try line, not waiting on them, or nothing said). */
function askOf(w: WorkRow): Omit<Need, "w"> | null {
  const t = w.tryLine?.trim();
  if (t) return { kind: "try", line: t };
  if (w.status !== "waiting") return null;
  const n = noteOf(w);
  if (!n) return null;
  if (QUESTION.test(n)) return { kind: "ask", line: n };
  return { kind: youChecks(w) ? "try" : "do", line: n };
}

/** Nobody else is on it: no live agent holds it, no passing check confirmed it, the user hasn't answered it. */
const waitsOnUser = (w: WorkRow, cs: BoardCheck[], said: Record<string, Answer>) =>
  boardState(w, cs) !== "working" && !confirmed(w, cs) && !isAnswered(w, cs, said);

/** The board's rows that really wait on the user, newest first. */
export function needsYou(rows: WorkRow[] = board.value, cs: BoardCheck[] = checks.value, said: Record<string, Answer> = answers.value): Need[] {
  const out: Need[] = [];
  for (const w of rows) {
    const ask = w.status === "done" || w.status === "blocked" ? null : askOf(w);
    if (ask && waitsOnUser(w, cs, said)) out.push({ w, ...ask });
  }
  return out.sort((a, b) => Number(b.w.updated) - Number(a.w.updated));
}

/** The ids waiting on the user (the area chips and dots). */
export const needIds = (needs: Need[] = needsYou()) => new Set(needs.map((n) => n.w.id));

/** A need as trycard.tsx's item: the same controls and the same calls as the chat's try card. */
export function itemOf(n: Need): TryItem {
  return n.kind === "ask" ? { id: n.w.id, line: n.line, ask: true, options: optionsOf(n.line) } : { id: n.w.id, line: n.line, do: n.kind === "do" };
}

/** The row open (one at a time): kept by id so a failed answer puts the row back open, with its line. */
const opened = signal<string | null>(null);

const KIND_WORDS: Record<NeedKind, string> = { try: "to try", do: "to do", ask: "question" };

/** One needs-you row: the task's name and what kind of ask; a tap opens its sentence and its answer controls in place. */
function NeedRow({ n }: { n: Need }) {
  const open = opened.value === n.w.id;
  return (
    <li class={`aip-need ${open ? "open" : ""}`} data-task={n.w.id} data-kind={n.kind}>
      <button type="button" class="aip-need-row" aria-expanded={open} onClick={() => (opened.value = open ? null : n.w.id)}>
        <span class="aip-dot waiting" aria-hidden="true" />
        <span class="aip-need-title">{n.w.title}</span>
        <span class="aip-need-kind">{KIND_WORDS[n.kind]}</span>
      </button>
      {open && (
        <div class="aip-need-more">
          <div class="aip-need-line">{n.line}</div>
          <TryLine it={itemOf(n)} at="board" bare />
        </div>
      )}
    </li>
  );
}

/** A row answered while the card shows: collapsed to what the user said (no longer counted, no controls). */
function SaidRow({ n, a }: { n: Need; a: Answer }) {
  return (
    <li class="aip-need answered" data-task={n.w.id}>
      <div class="aip-need-row">
        <span class="aip-dot" aria-hidden="true" />
        <span class="aip-need-title">{n.w.title}</span>
      </div>
      <div class="aip-need-more">
        <Said a={a} />
      </div>
    </li>
  );
}

/**
 * The rows to draw: the open asks, and those answered here since the card showed (in place, collapsed to the answer)
 * - an answer takes the row out of the count at once without it jumping away under the finger.
 */
function useRows(needs: Need[]): [Need, Answer | undefined][] {
  const seen = useRef(new Map<string, Need>());
  for (const n of needs) seen.current.set(n.w.id, n);
  const open = new Set(needs.map((n) => n.w.id));
  const said = answers.value;
  return [...seen.current.values()].filter((n) => open.has(n.w.id) || said[n.w.id]).map((n) => [n, open.has(n.w.id) ? undefined : said[n.w.id]]);
}

/** The rows as a list (open asks and those just answered), each answered in place. */
function NeedList({ rows }: { rows: [Need, Answer | undefined][] }) {
  return (
    <ul class="aip-need-list">
      {rows.map(([n, a]) => (a ? <SaidRow key={n.w.id} n={n} a={a} /> : <NeedRow key={n.w.id} n={n} />))}
    </ul>
  );
}

/** Progress's Needs you card: one row per task that waits on the user (not drawn when none does or did). */
export function NeedsYouCard({ needs }: { needs: Need[] }) {
  const rows = useRows(needs);
  if (!rows.length) return null;
  return (
    <section class="aip-area aip-needs tile open" aria-label="Needs you">
      <div class="aip-area-row aip-needs-head">
        <span class="aip-area-name">Needs you</span>
        {needs.length > 0 && <span class="aip-chip">{needs.length}</span>}
      </div>
      <NeedList rows={rows} />
    </section>
  );
}

/** The folded status page's section of asks (aistatus.tsx): its heading and the same rows, no card; none: not drawn. */
export function NeedSection({ title, sec, needs }: { title: string; sec: string; needs: Need[] }) {
  const rows = useRows(needs);
  if (!rows.length) return null;
  return (
    <section class="ais-sec" data-sec={sec} aria-label={title}>
      <h3 class="ais-h">
        {title}
        {needs.length > 0 && <span class="ais-n">{needs.length}</span>}
      </h3>
      <NeedList rows={rows} />
    </section>
  );
}

/** The wide page's Try this: the same open asks, each with its sentence and controls (its id once, newest first). */
export function TryThis({ needs }: { needs: Need[] }) {
  return (
    <div class="ai-ctx-try">
      {needs.slice(0, 6).map((n) => (
        <TryLine key={n.w.id} it={itemOf(n)} at="col" />
      ))}
    </div>
  );
}
