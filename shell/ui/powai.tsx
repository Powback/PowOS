/**
 * The PowOS AI page: left of home's first page, the whole screen (home, its bar and dock slide away for it). The
 * conversation - the last ask, its steps as they run, its answer - the work in progress (the agents' tasks, live from
 * the powos-agents module's work board: `powos agents task ...`), grouped by what each means for the user: needs you,
 * ready to try (works / still broken), being worked on, waiting for an agent;
 * the agents at work (PowOS's tmux sessions,
 * each with the task its pane's title names, a spinner's mark while it works; a tap opens its terminal), what they told
 * you lately, the whole conversation (folded; wide, in full), and a field to ask it (the mic: hold to talk and send, tap to dictate).
 */
import { useEffect, useRef, useState } from "preact/hooks";
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import { aiDraft, chat, openSession, page, sessionView } from "../state.ts";
import { Pill, hearing, type MicTarget } from "./bar.tsx";
import { ago } from "./time.ts";
import { md } from "./md.ts";
import { boardState, openAgents, useAgents, type BoardCheck } from "../agents.ts";
import { DbConnection as AgentsDb } from "../vendor/powos-agents.js";
import { checkAlive, useDb, useRows } from "../apps/stdb.ts";
import type { AgentMail, AgentSession, ChatItem, VerifyState } from "../types.ts";
import { AppBuild, NewAppAsk, newAppAsk } from "./appbuild.tsx";
import { Units } from "./units.tsx";
import { Item } from "./chat.tsx";
import { MailCard, Queued, Said, SentImages, Thread, ToolRun, mailOf, onLink, openFull, qaUrl, toolLabel } from "./rich.tsx";
import { askQueued, waiting } from "./assistant.ts";

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
const draft = aiDraft;

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
        <div class="chat ai-history-list tile">
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
      <div class="chat ai-history-list tile">
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
  /** The task it is a sub-task of ("" = none; `task set --parent`). */
  parent?: string;
  /** What the user can try now, one plain sentence (`task set --try`): its Ready-to-try line ("" = none). */
  tryLine?: string;
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
const sec = (ms: bigint | number) => Number(ms) / 1000;

const WORK_QUERY = "SELECT * FROM work";
/** The board's facts (apps/agents work_check: each task's phone checks, synced from the verify queue) and friction. */
export const checks = signal<BoardCheck[]>([]);
/** A friction row (apps/agents `friction`: what got in an agent's way; `powos friction`). */
interface FrictionRow {
  id: string;
  area: string;
  kind: string;
  title: string;
  count: number;
  status: string;
  last: bigint | number;
}
const friction = signal<FrictionRow[]>([]);
const CHECKS_QUERY = "SELECT * FROM work_check";
const FRICTION_QUERY = "SELECT * FROM friction";

/** The checks and friction while the board shows (no table on an older module: no rows, nothing breaks). */
function FactsFeed({ db }: { db: ReturnType<typeof useDb> }) {
  const cs = useRows<BoardCheck>(db, "work_check", CHECKS_QUERY);
  const fr = useRows<FrictionRow>(db, "friction", FRICTION_QUERY);
  useEffect(() => {
    if (db.status === "connected") checks.value = cs;
  }, [cs, db.status]);
  useEffect(() => {
    if (db.status === "connected") friction.value = fr;
  }, [fr, db.status]);
  return null;
}

/** Subscribed only while the page shows: the socket goes 5 s after it's left (apps/stdb.ts), so home holds none. */
function WorkFeed() {
  const db = useDb("powos-agents", AgentsDb);
  const rows = useRows<WorkRow>(db, "work", WORK_QUERY);
  // Which agent holds which task (live, from the hooks): a row says "working" only while one does.
  useAgents();
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
  return <FactsFeed db={db} />;
}

/**
 * "Test now" on a task with a phone check waiting for a free window (agents.ts boardState "awaiting check") hands the
 * phone over: the queue runs it at once (powos.ai.verifyGo); its result lands on the board's checks.
 * Tapped "test now" (task id, or "all"): when. "testing…" shows until the check runs out of the queue, or this long.
 */
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
  [testing.value[w.id], testing.value.all].some((t) => t !== undefined && Date.now() - t < TESTING_MS);

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

/**
 * "Open Health once and allow Health Connect" answers itself: once Health Connect has granted everything (status
 * `missing` empty) - checked when such a card shows and on every grant (the bridge's "powos:health-granted").
 * HACK: the task is the manager's free text, so it is matched by wording; the real fix is a board task carrying a
 * machine-checkable "done when" (e.g. `health.missing == 0`) that the board resolves itself.
 */
const HEALTH_TASK = /health connect/i;
function useHealthTaskDone(items: WorkRow[]) {
  const ids = items.filter((w) => HEALTH_TASK.test(`${w.title} ${w.note ?? ""}`)).map((w) => w.id);
  const key = ids.join(",");
  useEffect(() => {
    const h = powos.health;
    if (!h || !ids.length) return;
    let live = true;
    const check = () =>
      void h
        .status()
        .then((s) => {
          if (!live || s.state !== "ok" || s.missing.length) return;
          for (const w of board.value) if (ids.includes(w.id) && w.status === "waiting" && !isAnswered(w)) answer(w, "done");
        })
        .catch(() => {});
    check();
    window.addEventListener("powos:health-granted", check);
    return () => {
      live = false;
      window.removeEventListener("powos:health-granted", check);
    };
  }, [key]);
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

/** Under a queued check's row: "test now" (gone once tapped, or on a host that can't). */
function CheckActs({ w }: { w: WorkRow }) {
  if (boardState(w, checks.value) !== "awaiting check") return null;
  return isTesting(w) || !canTest.value ? null : (
    <button type="button" class="ai-test" onClick={() => testNow(w.id)}>
      test now
    </button>
  );
}

/**
 * "test all" on the in-progress header while phone checks are queued ("testing…" once tapped); "checks paused · resume"
 * instead while the runner is paused or silent - both write the go flag (verifyGo "all"), which also ends a pause.
 */
function TestAll({ rows }: { rows: WorkRow[] }) {
  const queued = rows.filter((w) => boardState(w, checks.value) === "awaiting check");
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

/**
 * The board's groups, in this order (the user, 2026-10-30: "let's group the PowOS AI in-progress things" - by what each
 * task means for them): what waits on them, what's shipped for them to try, what an agent is on, and what nobody is
 * on yet (folded: nothing for the user to do there).
 */
type Group = "you" | "try" | "on" | "free";
const GROUPS: { key: Group; name: string; folded?: boolean }[] = [
  { key: "you", name: "Needs you" },
  { key: "try", name: "Ready to try" },
  { key: "on", name: "Being worked on" },
  { key: "free", name: "Waiting for an agent", folded: true },
];
/**
 * The areas inside each group (but Needs you), in this order - the board's project names (the CLI's AREAS, `task set
 * --project`); the board's old "PowOS · ..." projects that name one area map to it, anything else is "Other".
 */
const AREAS = ["Windows", "Home & launcher", "Shade & lock", "Games", "Performance", "Kernel & system", "AI page", "Apps", "Agents & tooling"];
const OLD_AREAS: Record<string, string> = {
  "PowOS · kernel": "Kernel & system",
  "PowOS · games": "Games",
  "PowOS · AI page": "AI page",
  "PowOS · desktop mode": "Windows",
  "PowOS · apps platform": "Apps",
  "PowOS · AI": "Agents & tooling",
};
const OTHER = "Other";
const areaOf = (w: WorkRow) => (AREAS.includes(w.project) ? w.project : OLD_AREAS[w.project] ?? OTHER);

/** Rows an area shows before "N more". */
const GROUP_SHOWN = 5;
/** The check a verdict is recorded as (ShellBridge.callVerdict: `--name you`). */
const USER_CHECK = "you";
/** Results that decide (SKIP / INVALID say nothing about the fix). */
const DECIDING = new Set(["PASS", "FAIL", "none"]);

/** [w]'s latest deciding check, or the result the queue wrote into its step before the sweeper synced it. */
function lastResult(w: WorkRow): { ok: boolean; you: boolean } | null {
  const c = checks.value.filter((x) => x.task === w.id && DECIDING.has(x.state)).sort((a, b) => Number(a.at) - Number(b.at)).pop();
  if (c) return { ok: c.state !== "FAIL", you: c.name === USER_CHECK };
  const r = resultOf(w.step ?? "");
  return r ? { ok: r.ok, you: false } : null;
}

/**
 * "works" / "still broken", sent and not yet on the board: id -> the verdict and the `updated` the row had. Shown at
 * once (works: the row goes, or an epic with more open moves to "Waiting for an agent"; still broken: it moves there),
 * dropped when the board moves the row
 * or the call fails (then the row is back where it was, with the reason).
 */
const verdicts = signal<Record<string, { works: boolean; updated: number }>>({});
const verdictError = signal("");
const verdictOf = (w: WorkRow) => {
  const v = verdicts.value[w.id];
  return v && v.updated === Number(w.updated) ? v : null;
};

/** The user tried a shipped task: the board's CLI records it (bridge ai.verdict); an older host: told to the manager. */
function verdict(w: WorkRow, works: boolean) {
  verdictError.value = "";
  verdicts.value = { ...verdicts.value, [w.id]: { works, updated: Number(w.updated) } };
  const viaManager = () =>
    askQueued(works ? `Works: ${w.title} (task ${w.id}) - I tried it: a user PASS for what was ready, close it if nothing else is open` : `Still broken: ${w.title} (task ${w.id}) - I tried it, reopen it with a user FAIL`);
  const send = powos.ai.verdict;
  if (!send) return viaManager();
  send(w.id, works).catch((e) => {
    if (/no such call/.test(String(e))) return viaManager();
    const { [w.id]: _, ...rest } = verdicts.value;
    verdicts.value = rest;
    // One plain line, never the CLI's text (the user, 2026-10-30: "I try to press like works, but it just shows me like
    // this error message"); the reason stays in the log.
    console.warn(`ai.verdict ${w.id}:`, e);
    verdictError.value = `couldn't save that for "${w.title}" - try again in a moment`;
  });
}

/**
 * What else is open on [w] besides the slice it's on: its planned steps and its open sub-tasks (the CLI's open_items -
 * such a task can't close). "works" on it records the slice and the task stays (powos agents task works).
 */
function openRest(w: WorkRow): number {
  const next = list<Step>(w.steps).filter((x) => x.state === "next").length;
  return next + board.value.filter((x) => x.parent === w.id && x.status !== "done").length;
}

/** tools/phone/verify/queue.sh's step marker (the CLI's QUEUED_STEP): a check's state, not a slice. */
const QUEUED_STEP = "phone check queued";

/** The slice an epic has ready to try: its current step, in its own words (a queue's verify line isn't one). */
function sliceOf(w: WorkRow): string {
  const steps = list<Step>(w.steps).filter((x) => x.text && !resultOf(x.text) && x.text !== QUEUED_STEP);
  return steps.find((x) => x.state === "current")?.text ?? "";
}

/** Which group an open row is in (null: not on the board's groups - paused, done, answered). */
function groupOf(w: WorkRow): Group | null {
  if (w.status === "waiting") return isAnswered(w) ? null : "you";
  if (w.status !== "working") return null;
  const v = verdictOf(w);
  // "works" on an epic: the slice is done, the rest still open - it leaves Ready to try, it doesn't go.
  if (v) return v.works && !openRest(w) ? null : "free";
  return workingGroup(w);
}

/** An open task's group: an agent on it or a phone test waiting; else shipped (to try) or failed / never pushed. */
function workingGroup(w: WorkRow): Group {
  const s = boardState(w, checks.value);
  if (s === "working" || s === "awaiting check") return "on";
  const last = lastResult(w);
  const shipped = last ? last.ok : !!w.commits && w.commits !== "[]";
  // An epic (planned steps / sub-tasks still open) is to try only while a slice of it is ready, never as a whole.
  return shipped && (!openRest(w) || sliceOf(w)) ? "try" : "free";
}

/** "step 3 of 8" (the step it's on, not the ones done), "" untracked. */
function stepOf(w: WorkRow) {
  const total = w.progressTotal ?? 0;
  if (!total) return "";
  const done = Math.min(w.progressDone ?? 0, total);
  return done >= total ? "all steps done" : `step ${done + 1} of ${total}`;
}

const withStep = (w: WorkRow, state: string) => [state, stepOf(w)].filter(Boolean).join(" · ");

/** Being worked on: an agent, or a phone test (waiting for a free window, or running now). */
const onState = (w: WorkRow) =>
  boardState(w, checks.value) !== "awaiting check" ? "an agent is on it" : isTesting(w) ? "being tested on the phone now" : "waiting for a test on the phone";

/** What the user last said about [w] here (sent, or their check on the board): "" if nothing. */
function userSaid(w: WorkRow, last: { ok: boolean; you: boolean } | null) {
  const v = verdictOf(w);
  const works = v ? v.works : last?.you ? last.ok : null;
  if (works === null) return "";
  return works ? "you said the last part works · more to do" : "you said it's still broken";
}

/** Nobody on it: the user said it's still broken, its last test failed, or nobody has started. */
function freeState(w: WorkRow) {
  const last = lastResult(w);
  const said = userSaid(w, last);
  if (said) return said;
  return last && !last.ok ? "its last test failed" : "nobody on it yet";
}

/** A row's state in plain words per group: no hashes, no raw step text, no check jargon. */
const STATES: Record<Group, (w: WorkRow) => string> = {
  you: (w) => (w.note ? w.title : "waiting on you"),
  // Only the plain line written for the user (--try): never the agents' step or note (hashes, file names, jargon).
  try: (w) => w.tryLine?.trim() || "ready to try",
  on: (w) => withStep(w, onState(w)),
  free: (w) => withStep(w, freeState(w)),
};

const plainState = (w: WorkRow, g: Group | null) =>
  g ? STATES[g](w) : w.status === "done" ? "done" : withStep(w, w.status === "blocked" ? "paused" : "");

/** What the user can do about a row, beside its state: done / skip (needs you), works / still broken (ready to try). */
function actsOf(w: WorkRow, g: Group | null): [string, () => void][] | null {
  if (g === "you") return [["done", () => answer(w, "done")], ["skip", () => answer(w, "skip")]];
  if (g === "try") return [["works", () => verdict(w, true)], ["still broken", () => verdict(w, false)]];
  return null;
}

/** An open row's detail: its note, the steps done / now / next, the changes in words, its review images. */
function Details({ w, g }: { w: WorkRow; g: Group | null }) {
  const steps = list<Step>(w.steps);
  const commits = list<Commit>(w.commits);
  const images = list<string>(w.images);
  return (
    <div class="ai-item-more">
      {w.note && g !== "you" && <p class="ai-item-note">{w.note}</p>}
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
  );
}

/**
 * One task: a dot, its title (what to do, for one that needs the user) and its state in plain words under it, with
 * what the user can do about it at that line's end (actsOf) or "test now" under a queued phone test. A tap: Details.
 */
function WorkLine({ w, g, open, onTap }: { w: WorkRow; g: Group | null; open: boolean; onTap: () => void }) {
  const on = g === "on" && boardState(w, checks.value) === "working";
  const acts = actsOf(w, g);
  return (
    <div class={`ai-item ${w.status} ${g ?? ""}`}>
      <button type="button" class="ai-item-row" onClick={onTap} aria-expanded={open}>
        <span class={`ai-dot ${on ? "on" : ""}`} />
        <span class="ai-item-main">
          <span class="ai-item-title">{g === "you" ? w.note || w.title : w.title}</span>
          {!acts && <span class="ai-item-facts">{plainState(w, g)}</span>}
        </span>
      </button>
      {acts && (
        <div class="ai-item-line">
          <span class="ai-item-facts">{plainState(w, g)}</span>
          <span class="ai-item-acts">
            {acts.map(([label, act]) => (
              <button key={label} type="button" class="ai-act" onClick={act}>
                {label}
              </button>
            ))}
          </span>
        </div>
      )}
      {g === "on" && !open && <CheckActs w={w} />}
      {open && <Details w={w} g={g} />}
    </div>
  );
}

/** One area inside a group: its name and count (a tap folds it), its first GROUP_SHOWN rows, the rest behind "N more". */
function AreaList({ name, rows, g, opened, tap }: { name: string; rows: WorkRow[]; g: Group; opened: string | null; tap: (id: string) => void }) {
  const [open, setOpen] = useState(true);
  const [all, setAll] = useState(false);
  const shown = all ? rows : rows.slice(0, GROUP_SHOWN);
  return (
    <div class="ai-area">
      <button type="button" class="ai-area-fold" onClick={() => setOpen(!open)} aria-expanded={open}>
        <span class="ai-area-caret">{open ? "▾" : "▸"}</span>
        <span class="ai-area-title">{name}</span>
        <span class="ai-group-count">{rows.length}</span>
      </button>
      {open && shown.map((w) => <WorkLine key={w.id} w={w} g={g} open={opened === w.id} onTap={() => tap(w.id)} />)}
      {open && rows.length > GROUP_SHOWN && (
        <button type="button" class="ai-group-more" onClick={() => setAll(!all)} aria-expanded={all}>
          {all ? "show fewer" : `${rows.length - GROUP_SHOWN} more`}
        </button>
      )}
    </div>
  );
}

/** [rows] by area, in AREAS order, Other last (each keeps its newest-first order). */
function byArea(rows: WorkRow[]): [string, WorkRow[]][] {
  const m = new Map<string, WorkRow[]>([...AREAS, OTHER].map((a) => [a, []]));
  for (const w of rows) m.get(areaOf(w))!.push(w);
  return [...m].filter(([, r]) => r.length);
}

/** One group: its name and count (a tap folds it), its rows by area (Needs you: flat, every row). */
function GroupList({ name, rows, g, folded, opened, tap }: { name: string; rows: WorkRow[]; g: Group; folded?: boolean; opened: string | null; tap: (id: string) => void }) {
  const [open, setOpen] = useState(!folded);
  if (!rows.length) return null;
  return (
    <div class={`ai-group ${g}`}>
      <button type="button" class="ai-group-fold" onClick={() => setOpen(!open)} aria-expanded={open}>
        <span class="ai-group-title">{name}</span>
        <span class="ai-group-count">{rows.length}</span>
        <span class="ai-group-caret">{open ? "▾" : "▸"}</span>
      </button>
      {open && g === "you" && rows.map((w) => <WorkLine key={w.id} w={w} g={g} open={opened === w.id} onTap={() => tap(w.id)} />)}
      {open && g !== "you" && byArea(rows).map(([a, r]) => <AreaList key={a} name={a} rows={r} g={g} opened={opened} tap={tap} />)}
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
      {open && rows.map((w) => <WorkLine key={w.id} w={w} g={null} open={opened === w.id} onTap={() => tap(w.id)} />)}
    </>
  );
}

/** Friction lines shown when the fold opens: the most frequent first. */
const FRICTION_SHOWN = 8;

/** "friction · N": what keeps getting in the agents' way (open, most frequent first) - a tap opens the list. */
function Friction() {
  const [open, setOpen] = useState(false);
  const fs = friction.value.filter((f) => f.status === "open").sort((a, b) => b.count - a.count || Number(b.last) - Number(a.last));
  if (!fs.length) return null;
  return (
    <>
      <button type="button" class="ai-fold" onClick={() => setOpen(!open)} aria-expanded={open}>
        {open ? "▾" : "▸"} friction · {fs.length}
      </button>
      {open &&
        fs.slice(0, FRICTION_SHOWN).map((f) => (
          <div key={f.id} class="ai-item">
            <span class="ai-item-main">
              <span class="ai-item-title">{f.title}</span>
              <span class="ai-item-facts">{[`${f.count}×`, f.area, f.kind, `${ago(sec(f.last))} ago`].join(" · ")}</span>
            </span>
          </div>
        ))}
    </>
  );
}

/**
 * In progress, grouped by what each task means for the user (GROUPS), newest activity first in each. What's paused
 * (blocked) and what's done lately are folded lines under it.
 */
function Work({ shown }: { shown: boolean }) {
  const [opened, setOpened] = useState<string | null>(null);
  const all = [...board.value].sort((a, b) => Number(b.activity || b.updated) - Number(a.activity || a.updated));
  const groups = new Map<Group, WorkRow[]>(GROUPS.map((x) => [x.key, []]));
  for (const w of all) {
    const g = groupOf(w);
    if (g) groups.get(g)!.push(w);
  }
  useHealthTaskDone(groups.get("you")!);
  const paused = all.filter((w) => w.status === "blocked");
  const now = Date.now();
  const done = all.filter((w) => w.status === "done" && now - Number(w.done || w.updated) < RECENT_MS);
  const tap = (id: string) => setOpened(opened === id ? null : id);
  const open = [...groups.values()].flat();
  return (
    <section class="ai-work-list">
      {shown && <WorkFeed />}
      <h3 class="ai-heading">
        in progress
        {!boardLive.value && shown && <span> · connecting…</span>}
        <TestAll rows={groups.get("on")!} />
      </h3>
      <TestError />
      {verdictError.value && <div class="ai-work-empty muted">{verdictError.value}</div>}
      {GROUPS.map((x) => (
        <GroupList key={x.key} name={x.name} g={x.key} folded={x.folded} rows={groups.get(x.key)!} opened={opened} tap={tap} />
      ))}
      {!open.length && <div class="ai-work-empty muted">{boardSeen.value ? "nothing in progress" : "…"}</div>}
      <Fold label="paused" rows={paused} opened={opened} tap={tap} />
      <Fold label="done recently" rows={done} opened={opened} tap={tap} />
      <Friction />
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
          <div class="ai-mail-text md" onClick={onLink} dangerouslySetInnerHTML={{ __html: md(m.text) }} />
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
    </header>
  );
}

/**
 * What PowOS AI shows (the page now, the AI panel next - the same content in whatever holds it): the conversation (the
 * last exchange open, the earlier folded), the work board (in progress in its groups, needs you first; paused and done
 * folded), units, the agents. [shown]: on screen - its feeds run only then. [part]: the
 * wide page's two panes - "talk" (the conversation) and "side" (needs you, the board, the agents); none = all of it,
 * in one column.
 */
function AiContent({ shown, part }: { shown: boolean; part?: "talk" | "side" }) {
  const talk = part !== "side";
  const side = part !== "talk";
  useAiRefresh(shown && side);
  return (
    <>
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
      {!wide && <AiHeader />}
      {wide ? (
        <>
          {/* Wide, the header heads the left pane and scrolls away with it (the user, 2026-10-30: "This part doesn't
              need to be sticky"); one column, it still floats over the page. */}
          <div class="ai-scroll ai-side">
            <AiHeader />
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
