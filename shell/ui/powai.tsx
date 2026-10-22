/**
 * The PowOS AI page: left of home's first page, the whole screen (home, its bar and dock slide away for it). What
 * waits on the user (one card each, what to do), the conversation - the last ask, its steps as they run, its answer -
 * the work in progress (the agents' tasks, live from the powos-agents module's work board: `powos agents task ...`),
 * the agents at work (PowOS's tmux sessions,
 * each with the task its pane's title names, a spinner's mark while it works; a tap opens its terminal), what they told
 * you lately, the whole conversation (folded; wide, in full), and a field to ask it (the mic: hold to talk and send, tap to dictate).
 */
import { useEffect, useRef, useState } from "preact/hooks";
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import { chat, openSession, page, sessionView, stored } from "../state.ts";
import { Pill, hearing, type MicTarget } from "./bar.tsx";
import { ago } from "./time.ts";
import { boardState, openAgents, useAgents, useStallClock } from "../agents.ts";
import { DbConnection as AgentsDb } from "../vendor/powos-agents.js";
import { checkAlive, useDb, useRows } from "../apps/stdb.ts";
import type { AgentMail, AgentSession, ChatItem, VerifyState } from "../types.ts";
import { AppBuild, NewAppAsk, newAppAsk } from "./appbuild.tsx";
import { Units } from "./units.tsx";
import { Item } from "./chat.tsx";
import { MailCard, Queued, Said, SentImages, Thread, ToolRun, mailOf, openFull, qaUrl, toolLabel } from "./rich.tsx";
import { askQueued, openAssistant, waiting } from "./assistant.ts";

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
  // The one queue (assistant.ts): mid-turn it waits as a queued bubble, here and in every other chat.
  askQueued(text);
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
    full: (items[at] as { text: string }).text,
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
      <div class="ai-asked">
        {turn.asked}
        <SentImages text={turn.full} />
      </div>
      <ToolRun tools={turn.steps} />
      {turn.answer && (
        <div class="ai-answer">
          <Said text={turn.answer} reply={null} />
        </div>
      )}
      {turn.notes.map((n, i) =>
        !n.error && mailOf(n.text) ? (
          <MailCard key={i} text={n.text} />
        ) : (
          <div key={i} class={`ai-note ${n.error ? "error" : "muted"}`}>
            {n.text}
          </div>
        ),
      )}
      {busy && !turn.answer && <div class="ai-thinking muted">thinking…</div>}
      {waiting.value.length > 0 && (
        <div class="ai-queued">
          <Queued />
        </div>
      )}
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

/** Exchanges the wide page shows at first, and how many more each time its top comes near. */
const HISTORY_STEP = 20;

/**
 * Wide, the conversation before the last exchange in full - no fold. Only the newest HISTORY_STEP exchanges are drawn;
 * older ones as the top comes near (a sentinel, IntersectionObserver on the pane). The pane is column-reverse (CSS
 * .ai-talk), so it opens at the newest, stays there as a reply streams in, and holds still when older ones arrive above.
 */
function History() {
  const [count, setCount] = useState(HISTORY_STEP);
  const top = useRef<HTMLDivElement>(null);
  const items = chat.value.items;
  const end = Math.max(0, items.findLastIndex((i) => i.kind === "user"));
  const asks = items.slice(0, end).flatMap((i, at) => (i.kind === "user" ? [at] : []));
  const from = asks.length > count ? asks[asks.length - count] : 0;
  useEffect(() => {
    const el = top.current;
    const pane = el?.closest(".ai-scroll");
    if (!el || !pane || from === 0) return;
    const io = new IntersectionObserver((e) => e[0].isIntersecting && setCount((c) => c + HISTORY_STEP), {
      root: pane,
      rootMargin: "600px 0px 0px 0px",
    });
    io.observe(el);
    return () => io.disconnect();
  }, [from]);
  if (!end) return null;
  return (
    <section class="ai-history">
      <div ref={top} />
      <div class="chat ai-history-list">
        <Thread items={items.slice(from, end)} render={(item, reply) => <Item item={item} reply={reply} />} />
      </div>
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
  /** How far along (`--progress N/M`; 0/0: no bar). Absent on bindings from before the progress columns. */
  progressDone?: number;
  progressTotal?: number;
  /** The current step, one line ("" = none). */
  step?: string;
  /** JSON: [{text, state: "done" | "current" | "next"}] in order ("" = []). */
  steps?: string;
  /** JSON: [{sha, subject}] oldest first ("" = []). */
  commits?: string;
  /** JSON: [path] - review images, e.g. /home/powos/design-qa/x.png ("" = []). */
  images?: string;
  /** When it last moved (ms; 0 on old rows: `updated`). */
  activity?: bigint | number;
}

/** A JSON-array column ("" or bad = none). */
function list<T>(json: string | undefined): T[] {
  try {
    const v = JSON.parse(json || "[]");
    return Array.isArray(v) ? v : [];
  } catch {
    return [];
  }
}
type Step = { text: string; state: "done" | "current" | "next" };
type Commit = { sha: string; subject: string };
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

const WORK_QUERY = "SELECT * FROM work";

/** Subscribed only while the page shows: the socket goes 5 s after it's left (apps/stdb.ts), so home holds none. */
function WorkFeed() {
  const db = useDb("powos-agents", AgentsDb);
  const rows = useRows<WorkRow>(db, "work", WORK_QUERY);
  // Which agent holds which task (live, from the hooks): a row says "working" only while one does.
  useAgents();
  useStallClock(board.value.filter((w) => w.status === "working"));
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
  // Coming into sight on a connection that was already there: is it still alive (a socket Doze cut silently brought
  // no update again - the board went stale after edits)?
  useEffect(() => {
    const look = () => document.hidden || checkAlive("powos-agents", WORK_QUERY);
    look();
    document.addEventListener("visibilitychange", look);
    return () => document.removeEventListener("visibilitychange", look);
  }, []);
  return null;
}

/**
 * The verify queue's marker on a task (tools/phone/verify/queue.sh QUEUED_STEP): a phone check of it waits for a free
 * window. "Test now" hands the phone over: the queue runs it at once (powos.ai.verifyGo); its result replaces the step
 * ("verify PASS: ..." / "verify FAIL rc=N: ...", a FAIL with a screenshot as the task's last review image).
 */
const QUEUED_STEP = "phone check queued";
const checkQueued = (w: WorkRow) => w.status === "working" && w.step === QUEUED_STEP;
/** Tapped "test now" (task id, or "all"): when. "testing…" shows until the step changes, or this long. */
const testing = signal<Record<string, number>>({});
const TESTING_MS = 20 * 60_000;
const testError = signal("");
/**
 * The host has verify.go (the APK with VerifyRun): asked once with an empty id, which a new host refuses as a bad id
 * and an older one as "no such call" - nothing written either way. Until it says so, no "test now" / "test all".
 */
const canTest = signal(false);
let probed = false;
function probeTest() {
  if (probed) return;
  probed = true;
  powos.ai
    .verifyGo?.("")
    .then(
      () => (canTest.value = true),
      (e) => (canTest.value = !/no such call/.test(String(e))),
    );
}
const isTesting = (w: WorkRow) =>
  checkQueued(w) && [testing.value[w.id], testing.value.all].some((t) => t !== undefined && Date.now() - t < TESTING_MS);

function testNow(id: string) {
  testError.value = "";
  testing.value = { ...testing.value, [id]: Date.now() };
  const go = powos.ai.verifyGo;
  const failed = () => {
    const { [id]: _, ...rest } = testing.value;
    testing.value = rest;
    testError.value = "test now needs the newer app";
  };
  if (!go) return failed();
  go(id).catch(failed);
}

/**
 * The runner's state (VerifyRun.kt state: its heartbeat file on the phone): paused by the user (the pill's tap), or
 * no beat for STALE_S (killed, the Mac asleep) - then the queued checks wait on nothing, and the header says
 * "checks paused · resume". Hosts without verify.state never answer: nothing shows.
 */
const runner = signal<VerifyState | null>(null);
powos.on("verify.state", (s: VerifyState) => (runner.value = s));
const STALE_S = 45;
const ASK_MS = 15_000;
const isPaused = (s: VerifyState | null) => !!s && (s.state === "paused" || s.age < 0 || s.age > STALE_S);
/** While checks are queued and the page shows: the runner's state now and every ASK_MS (one root `stat` each). */
function useRunnerState(on: boolean) {
  useEffect(() => {
    if (!on) return;
    const ask = () => document.hidden || powos.ai.verifyState?.().catch(() => undefined);
    ask();
    const t = setInterval(ask, ASK_MS);
    document.addEventListener("visibilitychange", ask);
    return () => {
      clearInterval(t);
      document.removeEventListener("visibilitychange", ask);
    };
  }, [on]);
}

function TestError() {
  return testError.value ? <div class="ai-work-empty muted">{testError.value}</div> : null;
}

/** A check's result as the queue wrote it into the step: passed / failed and its one line (the log path dropped). */
function resultOf(step: string): { ok: boolean; line: string } | null {
  const m = /^verify (PASS|FAIL)(?: rc=\d+)?: ?(.*?)(?: \(log [^)]*\))?$/.exec(step);
  return m ? { ok: m[1] === "PASS", line: m[2].replace(/^FAIL:?\s*/, "") } : null;
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

const fileName = (path: string) => path.split("/").pop() ?? path;

/** A review image: its picture (a tap: full screen), or its name where the page can't load it (an older host). */
function Review({ path }: { path: string }) {
  const [failed, setFailed] = useState(false);
  const url = qaUrl(path);
  if (!url || failed) return <span class="ai-img-name">{fileName(path)}</span>;
  return (
    <button type="button" class="ai-img" onClick={() => openFull(fileName(path), <img class="ai-img-full" src={url} alt="" />)}>
      <img src={url} alt={fileName(path)} loading="lazy" onError={() => setFailed(true)} />
    </button>
  );
}

/** The step it's on; a queued phone check ("testing…" once test now was tapped), or a check's result in one line. */
function StepLine({ w, count }: { w: WorkRow; count: string }) {
  const result = resultOf(w.step ?? "");
  const pre = count && w.step ? `${count} · ` : count;
  if (!w.step) return <span class="ai-item-step">{pre}</span>;
  if (checkQueued(w)) return <span class="ai-item-step muted">{pre}{isTesting(w) ? "testing… don't touch the phone" : QUEUED_STEP}</span>;
  if (!result) return <span class="ai-item-step">{pre}{w.step}</span>;
  return <span class={`ai-item-step ai-result ${result.ok ? "ok" : "bad"}`}>{pre}{result.ok ? "check passed" : `check failed: ${result.line}`}</span>;
}

/** Under a row: "test now" while its phone check is queued; a failed check's screenshot (its last verify-*.png). */
function CheckActs({ w, images }: { w: WorkRow; images: string[] }) {
  if (checkQueued(w))
    return isTesting(w) || !canTest.value ? null : (
      <button type="button" class="ai-test" onClick={() => testNow(w.id)}>
        test now
      </button>
    );
  const shot = resultOf(w.step ?? "")?.ok === false ? images.filter((p) => /\/verify-[^/]*\.png$/.test(p)).pop() : undefined;
  return shot ? (
    <div class="ai-imgs ai-result-shot">
      <Review path={shot} />
    </div>
  ) : null;
}

/**
 * "test all" on the in-progress header while phone checks are queued ("testing…" once tapped); "checks paused · resume"
 * instead while the runner is paused or silent - both write the go flag (verifyGo "all"), which also ends a pause.
 */
function TestAll({ rows }: { rows: WorkRow[] }) {
  const queued = rows.filter(checkQueued);
  useEffect(probeTest, []);
  useRunnerState(queued.length > 0 && canTest.value);
  if (!queued.length || !canTest.value) return null;
  if (isPaused(runner.value) && !queued.every(isTesting))
    return (
      <button type="button" class="ai-test ai-test-all" onClick={() => testNow("all")}>
        checks paused · resume
      </button>
    );
  return queued.some((w) => !isTesting(w)) ? (
    <button type="button" class="ai-test ai-test-all" onClick={() => testNow("all")}>
      test all
    </button>
  ) : (
    <span class="ai-test-all muted">testing…</span>
  );
}

/** An open item's state in words ("working" only while a live agent holds it); null for blocked/waiting/done. */
const rowState = (w: WorkRow) => (w.status === "working" ? boardState(w, checkQueued(w)) : null);

/** Above a tracked row's title: the thin bar and "1/4 · the step". */
function Progress({ w, done, total }: { w: WorkRow; done: number; total: number }) {
  if (!total && !w.step) return null;
  return (
    <span class="ai-item-progress">
      {total > 0 && (
        <span class="ai-bar" role="progressbar" aria-valuenow={done} aria-valuemax={total}>
          <span style={{ width: `${(100 * done) / total}%` }} />
        </span>
      )}
      <StepLine w={w} count={total > 0 ? `${done}/${total}` : ""} />
    </span>
  );
}

/**
 * One open item: when it's tracked, a thin bar and "3/10 · <step>" above; a dot and its title (up to two lines);
 * then "owner · 2 commits · 2h ago" (untracked: the owner, its age past a day). A tap shows its note, the steps done /
 * now / next, the commits in plain words and its review images.
 */
function WorkLine({ w, open, onTap }: { w: WorkRow; open: boolean; onTap: () => void }) {
  const total = w.progressTotal ?? 0;
  const done = Math.min(w.progressDone ?? 0, total);
  const steps = list<Step>(w.steps);
  const commits = list<Commit>(w.commits);
  const images = list<string>(w.images);
  const moved = sec(Number(w.activity) || (w.status === "done" && Number(w.done) ? w.done : w.updated));
  const tracked = total > 0 || !!w.step || commits.length > 0;
  // Who has it: "free" when nobody does (the board's "" or the catch-all "coder"), so a free task shows as one.
  const who = !w.owner || w.owner === "coder" ? "free" : w.owner;
  // "working" only while a live agent holds it; else queued / awaiting check / stalled (agents.ts boardState).
  const state = rowState(w);
  const facts = [state, who, commits.length > 0 && `${commits.length} commit${commits.length > 1 ? "s" : ""}`, ago(moved) === "now" ? "just now" : `${ago(moved)} ago`].filter(Boolean).join(" · ");
  return (
    <div class={`ai-item ${w.status}`}>
      <button type="button" class="ai-item-row" onClick={onTap} aria-expanded={open}>
        <Progress w={w} done={done} total={total} />
        <span class={`ai-dot ${state === "working" ? "on" : ""}`} />
        <span class="ai-item-main">
          <span class="ai-item-title">{w.title}</span>
          {tracked ? <span class="ai-item-facts">{facts}</span> : <span class="ai-item-facts">{[state, who].filter(Boolean).join(" · ")}</span>}
        </span>
        {!tracked && Date.now() / 1000 - moved > DAY_S && <span class="ai-item-age">{ago(moved)}</span>}
      </button>
      {!open && <CheckActs w={w} images={images} />}
      {open && (
        <div class="ai-item-more">
          {w.note && <p class="ai-item-note">{w.note}</p>}
          {steps.length > 0 && (
            <ol class="ai-steps">
              {steps.map((x, i) => (
                <li key={i} class={x.state}>
                  <span class="ai-step-mark">{x.state === "done" ? "✓" : ""}</span>
                  {x.text}
                </li>
              ))}
            </ol>
          )}
          {commits.length > 0 && (
            <ul class="ai-commits">
              {commits.map((c) => (
                <li key={c.sha}>{c.subject || "a change"}</li>
              ))}
            </ul>
          )}
          {images.length > 0 && (
            <div class="ai-imgs">
              {images.map((p) => (
                <Review key={p} path={p} />
              ))}
            </div>
          )}
        </div>
      )}
    </div>
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
        <TestAll rows={working} />
      </h3>
      <TestError />
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
function AiHeader() {
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
 * progress; paused and done folded), units, the agents. [shown]: on screen - its feeds run only then. [part]: the
 * wide page's two panes - "talk" (the conversation) and "side" (needs you, the board, the agents); none = all of it,
 * in one column.
 */
function AiContent({ shown, part }: { shown: boolean; part?: "talk" | "side" }) {
  const talk = part !== "side";
  const side = part !== "talk";
  useAiRefresh(shown && side);
  return (
    <>
      {side && <NeedsYou />}
      {part === "talk" ? <History /> : talk && <Earlier />}
      {talk && <Now />}
      {/* The board: work in progress, what's installed and running, the agents - one surface, its parts by spacing. */}
      {side && <section class="ai-board tile">
        <Work shown={shown} />
        <Units shown={shown} />
        <button type="button" class="ai-session tile" onClick={() => openAgents()}>
          <span class="ai-dot" />
          <span class="ai-session-main">
            <span class="ai-session-task">Agents</span>
            <span class="ai-session-meta muted">what every agent is on: tree, tasks, tools, comms</span>
          </span>
        </button>
      </section>}
      {side && <AtWork />}
      {side && <FromAgents />}
    </>
  );
}

/** Its compose field: ask PowOS AI right here (the mic: hold to talk and send, tap to dictate). */
function AiCompose() {
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
        aria-label="Ask PowOS AI"
        enterKeyHint="send"
        autocomplete="off"
      />
    </form>
  );
}

/** The page's width, not the device's, picks the layout: two panes from WIDE_PX (the inner screen, a wide window). */
const WIDE_PX = 700;
function useWide() {
  const ref = useRef<HTMLDivElement>(null);
  const [wide, setWide] = useState(false);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setWide(el.clientWidth >= WIDE_PX));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  return [ref, wide] as const;
}

/**
 * PowOS AI's screen, wherever it's held - its page beside home, the pull-up panel on home and over apps (home.tsx,
 * pull.tsx): one component, so every change lands in all of them. The header, then by the holder's width (useWide, never
 * the device's): narrow one column; wide what needs the user and the board (left), the conversation at reading width
 * with its pill (right, by the right thumb), each pane its own scroll. [pill] false: the holder's own pill asks (home's
 * bar under a narrow panel); wide always has its own, under the conversation.
 */
export function AiView({ shown, cls, pill = true }: { shown: boolean; cls: string; pill?: boolean }) {
  const [ref, wide] = useWide();
  return (
    <div ref={ref} class={`${cls} ai-view ${wide ? "wide" : ""}`}>
      <AiHeader />
      {wide ? (
        <>
          <div class="ai-scroll ai-side">
            <AiContent shown={shown} part="side" />
          </div>
          <div class="ai-scroll ai-talk">
            <div class="ai-talk-in">
              <AiContent shown={shown} part="talk" />
            </div>
          </div>
        </>
      ) : (
        <div class="ai-scroll">
          <AiContent shown={shown} />
        </div>
      )}
      {(pill || wide) && <AiCompose />}
    </div>
  );
}

/** Its page, to the left of home. */
export function PowAiPage() {
  const shown = page.value === -1;
  return <AiView shown={shown} cls={`ai-screen ${shown ? "shown" : ""}`} />;
}
