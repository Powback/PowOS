/**
 * Up next (the status page under Working now, folded and unfolded, and the Progress view): the board's queued tasks
 * in line - accepted by the coordinator, waiting for one of the agent slots (the user, 11-01 17:1x: "I should be able
 * to see the queue on the AI page"; `powos agents task set <id> --status queued`). Plain words only: the title, when
 * the user asked; a tap opens a row in place in Recently done's style (aistatus.tsx DoneRow) - their words, the note,
 * its place in line, since when it waits.
 */
import { memo, sameContent } from "./memo.ts";
import { useState } from "preact/hooks";
import { board, noteOf, SevChip, userAsks, type UserAsk, type WorkRow } from "./aiboard.tsx";
import { clockAt } from "./time.ts";

/**
 * The queue in line (the CLI's queue_of / queue_key: the same order): severity first; at one level the user's own
 * evidence (still broken, repeated asks) above infra-only reports; then the score; then oldest accepted first.
 */
export function upNext(rows: WorkRow[] = board.value) {
  const k = (w: WorkRow) => [-Number(w.severity || 0), Number(w.userScore || 0) > 0 ? -1 : 0, -Number(w.score || 0), Number(w.created)];
  return rows
    .filter((w) => w.status === "queued")
    .sort((a, b) => {
      const x = k(a), y = k(b);
      for (let i = 0; i < x.length; i++) if (x[i] !== y[i]) return x[i] - y[i];
      return a.id < b.id ? -1 : 1;
    });
}

/** The user's ask a task came from (the latest linked one), or none. */
const askOfTask = (w: WorkRow, asks: UserAsk[]) => asks.filter((a) => a.task === w.id).sort((a, b) => Number(b.at) - Number(a.at))[0];

/** A queued row opened: the user's words and when they asked, its note, its place in line, since when it waits. */
function NextDetail({ w, ask, pos }: { w: WorkRow; ask?: UserAsk; pos: number }) {
  const note = noteOf(w);
  return (
    <div class="ais-done-detail">
      {ask && (
        <div class="ais-done-fact" data-fact="ask">
          You asked {clockAt(Number(ask.at))}: "{ask.text.trim()}"
        </div>
      )}
      {note && <div class="ais-done-fact" data-fact="note">{note}</div>}
      <div class="ais-done-fact" data-fact="line">
        {pos === 1 ? "Next in line" : `Number ${pos} in line`} - starts when an agent is free
      </div>
      <div class="ais-done-fact" data-fact="since">Waiting since {clockAt(Number(w.created))}</div>
    </div>
  );
}

/** One queued task: its title and when the user asked for it (if they did); a tap opens it in place (NextDetail). */
function NextRow({ w, pos, open, onToggle }: { w: WorkRow; pos: number; open: boolean; onToggle: () => void }) {
  const ask = askOfTask(w, userAsks.value);
  return (
    <li class={`ais-next-item ${open ? "open" : ""}`} data-task={w.id}>
      <button type="button" class="ais-done-row" aria-expanded={open} onClick={onToggle}>
        <SevChip w={w} />
        <span class="ais-done-title">{w.title}</span>
        {ask && <span class="ais-when">{clockAt(Number(ask.at))}</span>}
      </button>
      {open && <NextDetail w={w} ask={ask} pos={pos} />}
    </li>
  );
}

/** Up next shows this many rows, then "N more". */
const NEXT_ROWS = 5;

/**
 * Up next: the queue in line. A busy page ([busy]) folds it to one line, "4 up next ▾", until tapped; otherwise it's
 * open with its heading a toggle (Recently done's). None queued: not drawn.
 */
// Memo by content: StatusPage rebuilds its lists/rows each render, equal (render scan 11-06/11-07: needless renders).
export const UpNext = memo(function UpNext({ rows, busy }: { rows: WorkRow[]; busy: boolean }) {
  const [open, setOpen] = useState<boolean | null>(null);
  const [all, setAll] = useState(false);
  const [openId, setOpenId] = useState<string | null>(null);
  if (!rows.length) return null;
  const shown = open ?? !busy;
  const list_ = all ? rows.slice(0, 30) : rows.slice(0, NEXT_ROWS);
  return (
    <section class="ais-sec" data-sec="next" aria-label="Up next">
      <h3 class="ais-h">
        <button type="button" class="ais-toggle" aria-expanded={shown} onClick={() => setOpen(!shown)}>
          {shown ? (
            <>
              Up next<span class="ais-n">{rows.length}</span>
            </>
          ) : (
            `${rows.length} up next`
          )}
          <span class="ais-chev" aria-hidden="true" />
        </button>
      </h3>
      {shown && (
        <ul class="ais-list ais-done ais-next">
          {list_.map((w, i) => (
            <NextRow key={w.id} w={w} pos={i + 1} open={openId === w.id} onToggle={() => setOpenId(openId === w.id ? null : w.id)} />
          ))}
          {rows.length > list_.length && (
            <li>
              <button type="button" class="ais-more" onClick={() => setAll(true)}>
                {rows.length - list_.length} more
              </button>
            </li>
          )}
        </ul>
      )}
    </section>
  );
}, sameContent);
