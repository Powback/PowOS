// The AI page's header counts (ui/aistatus.tsx Hero, ui/aiboard.tsx boardCounts; gate.mjs ai-counts-*; board
// ai-progress-header-show-open-vs-done-task-counts, the user 11-25 circling "Done this month 30%": the percentage
// meant nothing, they want how many tasks are open and how many done). Against a mock board of every state - working,
// waiting, queued, blocked, done today / this week / older, and the parked backlog / stale ones that count as neither:
// the header reads "N open · M done", the folded summary's "done today" is the same count's, and a tap on a count
// filters the list to exactly those tasks (again: the whole page back). Imported with importShim.
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const text = (el) => (el?.textContent ?? "").replace(/\s+/g, " ").trim();
const H = 3_600_000;

/** The mock board's rows: [id, status, title, done ago (ms, done rows)]. 9 open, 6 done (5 this week), 2 parked. */
const ROWS = [
  ["c-work1", "working", "Switcher follows the finger"],
  ["c-work2", "working", "Steam menus open under the cursor"],
  ["c-wait", "waiting", "Kernel test", 0, "Plug the phone into the Mac once"],
  ["c-q1", "queued", "Lock screen media control"],
  ["c-q2", "queued", "Battery saver in the shade"],
  ["c-q3", "queued", "Widgets snap to the grid"],
  ["c-block", "blocked", "Rooted camera HAL"],
  ["c-idle1", "working", "Clipboard history"],
  ["c-idle2", "working", "Night light schedule"],
  ["c-done1", "done", "Media card redesign", 0.5 * H],
  ["c-done2", "done", "Dock divider", 0.25 * H],
  ["c-done3", "done", "Shade blur on OxygenOS", 30 * H],
  ["c-done4", "done", "Home recovers when blank", 3 * 24 * H],
  ["c-done5", "done", "App drawer A-Z scrub", 6 * 24 * H],
  ["c-done6", "done", "Windows raise on tap", 20 * 24 * H],
  ["c-back", "backlog", "Watch face sync"],
  ["c-stale", "stale", "Old tablet layout"],
];
export const WANT = { open: 9, done: 6 };

/** The mock board on the page (no daily driver row: the header the user saw), a fleet with two working agents. */
export async function aiCountsSetup() {
  const S = await importShim("./state.ts");
  const P = await importShim("./ui/powai.tsx");
  const now = Date.now();
  P.board.value = ROWS.map(([id, status, title, ago = 0, note = ""]) => ({
    id, title, status, note, owner: "coder", project: "Windows", created: now - 48 * H, updated: now - (ago || H), done: status === "done" ? now - ago : 0,
    progressDone: 0, progressTotal: 0, step: "", steps: "", commits: "", images: "", activity: now - (ago || H), tryLine: "",
  }));
  P.boardSeen.value = true;
  S.aiScreen.value = "chat";
  S.page.value = -1;
  await sleep(700);
  return S;
}

/** The status screen (folded: the stacked one; unfolded: the left column). */
const screen = () => document.querySelector(".ai-screen.status") ?? document.querySelector(".ai-screen .ai-left");
export const tapCount = async (k) => {
  screen().querySelector(`.ais-top .ais-tally[data-count="${k}"]`)?.click();
  await sleep(1000); // the list's rise (--spring-slow) settled: the shots show it whole
};

/** [sel]'s elements under [root] (none without a root), each mapped by [f]. */
const each = (root, sel, f) => (root ? [...root.querySelectorAll(sel)] : []).map(f);
const one = (root, sel) => (root ? root.querySelector(sel) : null);

/** The header's state: its counts, its line, a ring, which count is pressed. */
function lookTop(scr) {
  const top = one(scr, ".ais-top");
  return {
    title: text(one(top, ".ais-title")),
    line: text(one(top, ".ais-line")),
    ring: !!one(top, ".ais-ring"),
    pressed: each(top, ".ais-tally[aria-pressed=true]", (b) => b.dataset.count),
  };
}

/** The filtered list's state (list "" when none) and the page's sections, the folded summary. */
function lookList(scr) {
  const list = one(scr, "[data-sec^=count-]");
  const sum = one(scr, ".ais-sum");
  return {
    list: list ? list.dataset.sec : "",
    head: text(one(list, ".ais-h .ais-n")),
    items: each(list, ".ais-ck-item, .ais-done-item", (e) => e.dataset.task),
    groups: each(list, ".ais-ck-group", (g) => g.dataset.state),
    secs: each(scr, ".ais-sec[data-sec]", (e) => e.dataset.sec),
    sum: text(one(scr, ".ais-sum-text")),
    sumOpen: sum ? sum.getAttribute("aria-expanded") : "",
    shrunk: !!one(scr, ".ais-fold.shrunk"),
  };
}

const look = () => ({ ...lookTop(screen()), ...lookList(screen()) });
/** The [ok, why] pairs' failures. */
const failsOf = (pairs) => pairs.filter(([ok]) => !ok).map(([, why]) => why);
const has = (xs, ...want) => want.every((x) => xs.includes(x));

/** Before any tap: the counts, no percentage, the week on the line, folded the summary's "done today" the same count's. */
function plainFails(l, stacked) {
  const want = `${WANT.open} open · ${WANT.done} done`;
  const midnight = new Date().setHours(0, 0, 0, 0);
  const today = ROWS.filter(([, st, , ago]) => st === "done" && Date.now() - ago >= midnight).length;
  return failsOf([
    [l.title === want, `header reads "${l.title}", want "${want}" (backlog/stale in neither)`],
    [!l.ring, "a ring without a daily driver row (the month's share is gone)"],
    [!/%|this month/.test(l.title + l.line), `a percentage is still in the header: "${l.title}" / "${l.line}"`],
    [/(^|· )5 done this week$/.test(l.line), `the line "${l.line}" doesn't end in "5 done this week"`],
    [!stacked || new RegExp(`(^|· )${today} done today`).test(l.sum), `the folded summary "${l.sum}" doesn't say "${today} done today" (the header's count)`],
    [!l.list, `a filtered list (${l.list}) before any tap`],
  ]);
}

/** "open" tapped: exactly the open tasks, grouped, nothing else listed; folded, the sections open. */
function openFails(l, stacked) {
  const wrong = l.items.filter((id) => /c-(done|back|stale)/.test(id));
  return failsOf([
    [l.list === "count-open", `tapping "open" shows ${l.list || "no filtered list"}`],
    [l.head === String(WANT.open) && l.items.length === WANT.open, `the open list counts ${l.head} and shows ${l.items.length} rows, want ${WANT.open}`],
    [!wrong.length, `the open list shows ${wrong.join(", ")}`],
    [!l.secs.some((x) => ["working", "done", "next", "areas"].includes(x)), `filtered, the page still shows [${l.secs.join(", ")}]`],
    [has(l.groups, "waiting", "queued", "paused"), `the open list's groups are [${l.groups.join(", ")}], want needs you, up next and paused among them`],
    [l.pressed.join() === "open", `pressed counts: [${l.pressed.join(", ")}], want [open]`],
    [!stacked || (l.sumOpen === "true" && !l.shrunk), `folded, the sections aren't open under the tapped count (open ${l.sumOpen}, shrunk ${l.shrunk})`],
  ]);
}

/** "done" tapped: every done task, newest first. */
const doneFails = (l) =>
  failsOf([
    [l.list === "count-done" && l.items.length === WANT.done, `tapping "done" shows ${l.list || "nothing"} with ${l.items.length} rows, want ${WANT.done}`],
    [l.items.join() === "c-done2,c-done1,c-done3,c-done4,c-done5,c-done6", `done rows aren't newest first: ${l.items.join(", ")}`],
  ]);

/** "done" tapped again: the whole page back. */
const backFails = (l) =>
  failsOf([
    [!l.list, `tapping "done" again leaves ${l.list} (the page should come back)`],
    [l.secs.includes("done"), `unfiltered, no Recently done section ([${l.secs.join(", ")}])`],
  ]);

/** Every check, folded (the stacked page) or unfolded (the left column). Shots: shots.mjs ai-counts, -open, -done. */
export async function aiCountsCheck() {
  await aiCountsSetup();
  const stacked = !!document.querySelector(".ai-screen.status.stacked");
  const fails = plainFails(look(), stacked);
  await tapCount("open");
  fails.push(...openFails(look(), stacked));
  await tapCount("done");
  fails.push(...doneFails(look()));
  await tapCount("done");
  fails.push(...backFails(look()));
  return fails;
}
