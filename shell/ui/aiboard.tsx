/**
 * The work board as the AI page showed it before it became one chat (the user, 2026-10-31: "a bunch of different boxes
 * ... stacked on top of each other"): now only behind its ⋯ menu, as Progress where the powos-progress app isn't
 * installed (aimenu.tsx). The agents' tasks live from the powos-agents module's work board (`powos agents task ...`),
 * grouped by what each means for the user: needs you, ready to try (works / still broken), being worked on, waiting
 * for an agent; paused, done lately and friction folded under it. Things to try reach the user as the manager's chat
 * messages instead (trycard.tsx); a verdict here and there is the same call (recordVerdict).
 */
import { useEffect, useState } from "preact/hooks";
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import { ago } from "./time.ts";
import { boardState, useAgents, type BoardCheck } from "../agents.ts";
import { DbConnection as AgentsDb } from "../vendor/powos-agents.js";
import { checkAlive, useDb, useRows } from "../apps/stdb.ts";
import type { VerifyState } from "../types.ts";
import { imageUrl, openFull } from "./rich.tsx";
import { askQueued } from "./assistant.ts";
import { BrokenReply, clearBroken, type Broken } from "./brokenreply.tsx";
import { doneAsk, recordVerdict, sendCantMail } from "./trycard.tsx";

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
export function WorkFeed() {
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
  askQueued(how === "done" ? doneAsk({ id: w.id, title: noteOf(w) || w.title }) : `Skip for now: ${noteOf(w) || w.title} (task ${w.id})`);
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


/** A review image: a small thumbnail (a tap: full screen); nothing where the page can't load it - never its file name. */
function Review({ path, title }: { path: string; title: string }) {
  const [failed, setFailed] = useState(false);
  const url = imageUrl(path);
  if (!url || failed) return null;
  return (
    <button type="button" class="ai-img" onClick={() => openFull(title, <img class="ai-img-full" src={url} alt="" />)}>
      <img src={url} alt="" loading="lazy" onError={() => setFailed(true)} />
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

/**
 * The user tried a shipped task: recorded on the board (trycard.tsx recordVerdict - the same call as the chat's things
 * to try). Shown at once; a failed call puts the card back with one plain line.
 */
function verdict(w: WorkRow, works: boolean, b?: Broken): Promise<boolean> {
  verdictError.value = "";
  verdicts.value = { ...verdicts.value, [w.id]: { works, updated: Number(w.updated) } };
  return recordVerdict(w, works, b).then((ok) => {
    if (ok) return true;
    const { [w.id]: _, ...rest } = verdicts.value;
    verdicts.value = rest;
    // One plain line, never the CLI's text (the user, 2026-10-30: "I try to press like works, but it just shows me
    // like this error message"); the reason stays in the log.
    verdictError.value = `couldn't save that for "${w.title}" - try again in a moment`;
    return false;
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
  if (w.status !== "waiting" && w.status !== "working") return null;
  const v = verdictOf(w);
  // "works" on an epic: the slice is done, the rest still open - it leaves Ready to try, it doesn't go. "Still
  // broken" (here or on a Needs-you card): waiting for an agent.
  if (v) return v.works && !openRest(w) ? null : "free";
  if (w.status === "waiting") return isAnswered(w) ? null : "you";
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

/** A note that says nothing ("waiting on you"): the agents' placeholder, not what to do. */
const EMPTY_NOTE = /^\s*(waiting|needs?)\s+(on\s+)?(you|the user)\W*$/i;
const noteOf = (w: WorkRow) => (w.note && !EMPTY_NOTE.test(w.note) ? w.note.trim() : "");

/** A sentence that tells the user to do something: it starts with a verb of doing ("Open Health and allow ..."). */
const INSTRUCTION = /^(open|tap|press|hold|swipe|pull|drag|drop|switch|turn|enable|disable|set|pick|choose|decide|approve|allow|grant|log|sign|install|update|restart|reboot|plug|charge|connect|pair|send|give|answer|reply|tell|say|type|enter|look|watch|play|launch|start|run|use|go|move|resize|scroll|dictate|try|check|test|see|confirm|verify)\b/i;
/** A check: the ask is to try / look at something and say if it holds ("...: it should respond"). */
const CHECK = /\b(should|try|tried|check|test|see if|see whether|verify|does it|still works?|works?)\b/i;

/** What a Needs-you card says to do, in the imperative: its --try line, else its note when that is an instruction. */
function youDo(w: WorkRow): string {
  const t = w.tryLine?.trim();
  if (t) return t;
  const n = noteOf(w);
  return n && INSTRUCTION.test(n) ? n : "";
}

/**
 * Whether a Needs-you card asks the user to try or check something (works / still broken) rather than do a thing
 * (done / can't): its --try line or its changes say so, or its words read as a check; a plain instruction without a
 * check in it ("Open Health once and allow Health Connect") is a thing to do, and so is a card with nothing to go on
 * but a feature's name read as one shipped to look at (the user, 2026-10-31 01:44: "Needs you doesn't let me say that
 * it's broken").
 */
function youChecks(w: WorkRow): boolean {
  if (w.tryLine?.trim() || list<Commit>(w.commits).length > 0) return true;
  const n = noteOf(w);
  if (n) return CHECK.test(n) || !INSTRUCTION.test(n);
  return CHECK.test(w.title) || !INSTRUCTION.test(w.title);
}

/**
 * A Needs-you card's line under its title: what to do (youDo, when the title isn't already that), else the task's
 * name under its note, else a plain "it didn't say" - never the empty "waiting on you".
 */
function youState(w: WorkRow): string {
  const n = noteOf(w);
  const d = youDo(w);
  if (d && d !== n) return d;
  if (n) return w.title;
  return "no steps given - ask PowOS AI what to do";
}

/** A row's state in plain words per group: no hashes, no raw step text, no check jargon. */
const STATES: Record<Group, (w: WorkRow) => string> = {
  you: youState,
  // Only the plain line written for the user (--try): never the agents' step or note (hashes, file names, jargon).
  try: (w) => w.tryLine?.trim() || "ready to try",
  on: (w) => withStep(w, onState(w)),
  free: (w) => withStep(w, freeState(w)),
};

const plainState = (w: WorkRow, g: Group | null) =>
  g ? STATES[g](w) : w.status === "done" ? "done" : withStep(w, w.status === "blocked" ? "paused" : "");

/** A card that asks the user to try something: Ready to try, or a Needs-you card for something shipped (its try line, its changes). */
const asksToTry = (w: WorkRow, g: Group | null) => g === "try" || (g === "you" && youChecks(w));

/** The card whose "still broken" reply line is open (one at a time). */
const replying = signal<string | null>(null);

type Act = [label: string, act: () => void, quiet?: boolean];

/** The label that opens a card's reply line: "still broken" on one to try, "can't / problem" on a thing to do. */
const STILL_BROKEN = "still broken";
const CANT = "can't / problem";
const toggleReply = (w: WorkRow) => (replying.value = replying.value === w.id ? null : w.id);

/**
 * What the user can do about a row, beside its state: works / still broken on anything to try ("still broken" opens
 * the reply line; skip, quiet, on a Needs-you one), done / can't / skip on the other Needs-you cards ("can't" opens
 * the same reply line).
 */
function actsOf(w: WorkRow, g: Group | null): Act[] | null {
  const skip: Act = ["skip", () => answer(w, "skip"), true];
  if (asksToTry(w, g)) {
    const acts: Act[] = [["works", () => void verdict(w, true)], [STILL_BROKEN, () => toggleReply(w)]];
    return g === "you" ? [...acts, skip] : acts;
  }
  if (g === "you") return [["done", () => answer(w, "done")], [CANT, () => toggleReply(w)], skip];
  return null;
}

/** "Can't / problem" sent: to the manager's inbox (it owns the board), the card answered at once like done / skip. */
function sendCant(w: WorkRow, b: Broken) {
  replying.value = null;
  answered.value = { ...answered.value, [w.id]: Number(w.updated) };
  clearBroken(w.id);
  sendCantMail({ id: w.id, title: noteOf(w) || w.title }, b);
}

/** "Still broken" sent from the reply line: shown at once (the card moves), the line back with its words on a failure. */
async function sendBroken(w: WorkRow, b: Broken) {
  replying.value = null;
  if (await verdict(w, false, b)) clearBroken(w.id);
  else replying.value = w.id;
}

/** The reply line sent: "still broken" on a card to try, "can't / problem" on a thing to do. */
const sendReply = (w: WorkRow, g: Group | null, b: Broken) => (asksToTry(w, g) ? void sendBroken(w, b) : sendCant(w, b));

/** An open row's detail: its note, the steps done / now / next, the changes in words, its review images. */
function Details({ w, g }: { w: WorkRow; g: Group | null }) {
  const steps = list<Step>(w.steps);
  // A change with no subject says nothing to the user ("a change"): only the ones in words.
  const commits = list<Commit>(w.commits).filter((c) => c.subject?.trim());
  const images = list<string>(w.images).filter((p) => imageUrl(p));
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
            <li key={c.sha}>{c.subject}</li>
          ))}
        </ul>
      )}
      {images.length > 0 && (
        <div class="ai-imgs">
          {images.map((p) => (
            <Review key={p} path={p} title={w.title} />
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
          <span class="ai-item-title">{g === "you" ? noteOf(w) || w.title : w.title}</span>
          {!acts && <span class="ai-item-facts">{plainState(w, g)}</span>}
        </span>
      </button>
      {acts && (
        <div class="ai-item-line">
          <span class="ai-item-facts">{plainState(w, g)}</span>
          <span class="ai-item-acts">
            {acts.map(([label, act, quiet]) => (
              <button key={label} type="button" class={`ai-act ${quiet ? "quiet" : ""}`} onClick={act} aria-expanded={label === STILL_BROKEN || label === CANT ? replying.value === w.id : undefined}>
                {label}
              </button>
            ))}
          </span>
        </div>
      )}
      {acts && replying.value === w.id && <BrokenReply id={w.id} onSend={(b) => sendReply(w, g, b)} onCancel={() => (replying.value = null)} />}
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
export function Friction({ start = false }: { start?: boolean }) {
  const [open, setOpen] = useState(start);
  const fs = friction.value.filter((f) => f.status === "open").sort((a, b) => b.count - a.count || Number(b.last) - Number(a.last));
  if (!fs.length) return start ? <div class="ai-work-empty muted">no friction open</div> : null;
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
export function Work({ shown }: { shown: boolean }) {
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

