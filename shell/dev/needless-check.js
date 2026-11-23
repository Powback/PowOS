/**
 * needless-renders (the user, 11-07: "reactscan catches it fine" - the rs overlay's outlines): what the render scan
 * flags as needless on home - props/state/hooks equal, no signal - while the usual updates arrive: a notification
 * list, PowOS AI's board, the bar's text, a page change to the AI page and back. The offenders of the user's traces
 * (perf-1793970543446 / -527979, 11-06: Icon 208 of 212 needless, Send 94 of 95, LiveBar, PowOS AI's status
 * sections rebuilt equal) must render only when their content changes. Before the fix (gate, 821x883): 406 renders,
 * 164 needless; after: ~242, ~22 (PillSend 10).
 */
const FIXED = ["Icon", "Send", "LiveBar", "ThinBar", "WorkRowLive", "WorkingNow", "NeedsAttention", "RecentlyDone", "NeedStack", "UpNext", "SevChip"];

const list = () => ({ available: true, items: [1, 2, 3].map((i) => ({ key: `n${i}`, app: "gate", title: `T${i}`, text: `x${i}`, when: 1, icon: null, actions: [] })) });

/** Five rounds of the updates home gets anyway; the scan's report over them. */
async function rounds() {
  const R = await importShim("./ui/renderscan.ts"), S = await importShim("./state.ts"), B = await importShim("./ui/aiboard.tsx");
  R.startScan("needless");
  try {
    for (let i = 0; i < 5; i++) {
      window.__mockEvents.emit("notifications.changed", list());
      B.board.value = B.board.value.map((w) => ({ ...w }));
      S.query.value = "ab".slice(0, i % 3);
      await window.__gw.frames(3);
      S.page.value = i % 2 ? 0 : -1;
      await window.__gw.sleep(400);
    }
    return R.renderReport();
  } finally {
    R.stopScan("needless");
    S.query.value = "";
    S.page.value = 0;
  }
}

export async function needlessRenders() {
  await window.__gw.settled();
  const r = await rounds();
  const row = (x) => `${x.name} ${x.renders}r ${x.needless}n (${x.changed})`;
  window.__needless = `renders ${r.renders}, needless ${r.needlessRenders}: ${r.needless.map(row).join("; ") || "none"}`;
  const bad = r.needless.filter((x) => FIXED.includes(x.name) && x.needless > 1);
  const fails = bad.length ? [`needless renders again in ${bad.map(row).join("; ")}`] : [];
  if (r.needlessRenders > 40) fails.push(`home's needless renders ${r.needlessRenders} (want <= 40; 164 before the fix): ${r.needless.slice(0, 6).map(row).join("; ")}`);
  return fails;
}

/**
 * home-swipes (the user, 11-23: "everything keeps redrawing"; perf-1795459755191: 27.5 s of page swipes on home, 406
 * commits, 2383 renders - the bar's pill 116x, its parts 116x each, Seams 37 of 38 needless, PowOS AI's page re-rendered
 * on every page change, its status page refetched on every visit): page swipes the way gesture.ts drives them (a finger
 * on the track: pageDrag per move, the page set, the drag ended), between home's pages and PowOS AI's, then home left
 * alone. A swipe between home's own pages must not re-render the bar's pill at all; idle home commits nothing.
 */
export async function homeSwipes() {
  await window.__gw.settled();
  const R = await importShim("./ui/renderscan.ts"), S = await importShim("./state.ts"), G = await importShim("./ui/gesture.ts");
  const swipe = async (to) => {
    for (const dx of [-12, -40, -90]) { G.pageDrag.value = dx; await window.__gw.frames(1); }
    G.pageDrag.value = null;
    S.page.value = to;
    await window.__gw.sleep(350);
  };
  S.page.value = 0;
  await window.__gw.sleep(400);
  R.startScan("swipes");
  let home, ai, idle;
  try {
    // Home's own pages (needs two: the gate's home has the app library after its pages - page 1 is that, or page 2).
    R.reset();
    for (let i = 0; i < 6; i++) await swipe(i % 2 ? 0 : 1);
    home = R.renderReport();
    // To PowOS AI's page and back.
    R.reset();
    for (let i = 0; i < 6; i++) await swipe(i % 2 ? 0 : -1);
    ai = R.renderReport();
    // Left alone.
    S.page.value = 0;
    await window.__gw.sleep(800);
    R.reset();
    await window.__gw.sleep(3000);
    idle = R.renderReport();
  } finally {
    R.stopScan("swipes");
    G.pageDrag.value = null;
    S.page.value = 0;
  }
  return swipeFails(home, ai, idle);
}

/** homeSwipes' verdicts on its three reports. */
function swipeFails(home, ai, idle) {
  const count = (r, names) => r.byCount.filter((x) => names.includes(x.name)).reduce((n, x) => n + x.renders, 0);
  const PILL = ["Pill", "Lead", "GrowField", "PillSend"];
  const fails = [];
  const line = (r) => `${r.commits} commits, ${r.renders} renders, ${r.needlessRenders} needless (pill ${count(r, PILL)}; ${r.byCount.slice(0, 6).map((x) => `${x.name} ${x.renders}`).join(", ")})`;
  window.__swipes = `home pages x6: ${line(home)} | AI page x6: ${line(ai)} | idle 3 s: ${line(idle)}`;
  if (count(home, PILL) > 0) fails.push(`swipes between home's pages re-rendered the bar's pill ${count(home, PILL)}x (want 0): ${line(home)}`);
  // Each swipe to or from the AI page changes the bar's role: its hint and glyph (one pill render), the hint then fitted
  // to the field (useFittedHint, one more) - two per swipe at most (before: 3 per swipe, its parts 3 each).
  if (count(ai, ["Pill"]) > 12) fails.push(`6 swipes to PowOS AI's page and back rendered the pill ${count(ai, ["Pill"])}x (want <= 12): ${line(ai)}`);
  if (home.needlessRenders > 6) fails.push(`swipes between home's pages: ${home.needlessRenders} needless renders (want <= 6): ${line(home)}`);
  if (ai.needlessRenders > 12) fails.push(`swipes to PowOS AI's page: ${ai.needlessRenders} needless renders (want <= 12): ${line(ai)}`);
  if (idle.commits > 2) fails.push(`idle home committed ${idle.commits}x in 3 s (want <= 2): ${line(idle)}`);
  return fails;
}
