/**
 * HP4 (perf-1793970543446, 11-06, the user swiping home's widget pages: 53 janks, p5 24 fps; the top frames
 * "DIV.ontouchend vendor/preact.js 72 ms forced 64 ms", every touchmove 20-37 ms forced; Bar 96 renders, Pill / Lead /
 * GrowField / PillSend ~95 each over 21 swipes): scripted sideways swipes on home's pages, by real touch events (home's
 * own handlers). Per move and at the release: the style/size reads the handlers make (each one after the swipe's
 * transform writes is a forced style recalc / layout - want none: the widths come from ResizeObservers), and the
 * components that render with the finger's moves (want none: the track follows the finger by its transform only, never
 * a render - the bar's "sliding" is a boolean of the drag, not its every px).
 */
function pageSwipeTouch() {
  const W = innerWidth, y = innerHeight * 0.45;
  const tgt = document.elementFromPoint(W * 0.5, y);
  const fire = (type, x) => {
    const t = new Touch({ identifier: 12, target: tgt, clientX: x, clientY: y });
    const init = { touches: type === "touchend" ? [] : [t], changedTouches: [t], bubbles: true, cancelable: true };
    // The gate's Chromium has no touch input: Preact bound home's onTouchStart as "TouchStart" there - both names.
    for (const name of [type, `Touch${type.slice(5, 6).toUpperCase()}${type.slice(6)}`]) tgt.dispatchEvent(new TouchEvent(name, init));
  };
  return { W, fire };
}

/**
 * Wraps every style / rect / size read - getComputedStyle, getBoundingClientRect, offset / client / scroll sizes, and the
 * viewport's innerWidth / innerHeight / devicePixelRatio (each brings layout up to date: perf-1794158824368, 11-08, had
 * them as homeDotsAt's 710 ms and renderoverlay draw's 760 ms) - calling [note] with the reader's stack. Returns undo.
 */
function wrapReads(note) {
  const stack = () => (new Error().stack ?? "").split("\n").slice(3, 9).map((l) => l.trim()).join(" < ");
  const gcs = window.getComputedStyle, rect = Element.prototype.getBoundingClientRect;
  const own = (o, k) => { for (let p = o; p; p = Object.getPrototypeOf(p)) { const d = Object.getOwnPropertyDescriptor(p, k); if (d) return [p, d]; } return [o, undefined]; };
  const props = [[HTMLElement.prototype, "offsetWidth"], [HTMLElement.prototype, "offsetHeight"], [Element.prototype, "clientHeight"], [Element.prototype, "clientWidth"],
    [Element.prototype, "scrollHeight"], [Element.prototype, "scrollWidth"], [window, "innerWidth"], [window, "innerHeight"], [window, "devicePixelRatio"]]
    .map(([o, k]) => [...own(o, k), k]).filter(([, d]) => d?.get && d.configurable);
  window.getComputedStyle = function (...a) { note("getComputedStyle", stack()); return gcs.apply(this, a); };
  Element.prototype.getBoundingClientRect = function () { note("getBoundingClientRect", stack()); return rect.call(this); };
  props.forEach(([o, d, k]) => Object.defineProperty(o, k, { ...d, get() { note(k, stack()); return d.get.call(this); } }));
  return () => {
    window.getComputedStyle = gcs;
    Element.prototype.getBoundingClientRect = rect;
    props.forEach(([o, d, k]) => Object.defineProperty(o, k, d));
  };
}

/** Counts style, rect and size reads while [fn] runs and the microtasks after it (Preact's renders, effects). */
async function countReads(fn) {
  let n = 0;
  const where = [];
  const undo = wrapReads((k, at) => { n++; if (where.length < 3) where.push(`${k} ${at.split(" < ").slice(0, 2).join(" < ")}`); });
  try {
    fn();
    for (let i = 0; i < 6; i++) await Promise.resolve();
  } finally {
    undo();
  }
  return { n, where };
}

/**
 * Over [ms] after a release: the reads home's pull-region report makes (home.tsx claimStatic - re-run as the page
 * changes). Its walk of home read every element's sizes and style each time (perf-1794158824368: "scrolls
 * (ui/home.tsx:89)" 70-170 ms a run as each swipe settled); its scrollers are kept now, so a page change reads no style.
 */
async function regionReads(ms) {
  const r = { style: 0, size: 0, where: [] };
  const undo = wrapReads((k, at) => {
    if (!/claimStatic|homeScrollers/.test(at)) return;
    if (k === "getComputedStyle") r.style++;
    else r.size++;
    if (r.where.length < 2) r.where.push(`${k} ${at.split(" < ").slice(0, 3).join(" < ")}`);
  });
  try {
    await window.__gw.sleep(ms);
  } finally {
    undo();
  }
  return r;
}

/** One sideways swipe [from] -> [to] (fractions of the width), 10 moves a frame apart; the moves' reads and renders. */
async function pageSwipe(from, to) {
  const { W, fire } = pageSwipeTouch();
  fire("touchstart", W * from);
  await window.__gw.frames(1);
  const moves = [];
  window.__powosRenders.reset();
  for (let i = 1; i <= 10; i++) {
    const r = await countReads(() => fire("touchmove", W * (from + ((to - from) * i) / 10)));
    moves.push(r);
    // The first move claims the swipe (the drag starts: one "sliding" render is the start's, not a move's).
    if (i === 1) window.__powosRenders.reset();
    await window.__gw.frames(1);
  }
  const rendered = window.__powosRenders.top(500).byCount.filter((r) => r.renders > 0);
  window.__powosRenders.reset();
  const end = await countReads(() => fire("touchend", W * to));
  const regions = await regionReads(600);
  const after = window.__powosRenders.top(500);
  return { moves, rendered, end, after, regions };
}

/**
 * From home's first page toward PowOS AI's (the whole screen slides: homeDotsAt took the width from innerWidth there - a
 * forced layout per move, its 710 ms in perf-1794158824368), then back to the start before the release (a flick back
 * cancels): the moves' reads.
 */
async function aiPeek() {
  const { W, fire } = pageSwipeTouch();
  fire("touchstart", W * 0.4);
  await window.__gw.frames(1);
  const moves = [];
  for (let i = 1; i <= 10; i++) {
    const x = W * (0.4 + (i <= 5 ? i : 10 - i) * 0.02);
    moves.push(await countReads(() => fire("touchmove", x)));
    await window.__gw.frames(1);
  }
  fire("touchend", W * 0.4);
  await window.__gw.sleep(600);
  return moves;
}

export async function pageSwipePerf() {
  const S = await window.__gw.mod("./state.ts");
  await window.__gw.settled();
  S.page.value = 0;
  await window.__gw.sleep(300);
  if (S.pageCount.value < 2) return [`HP4: home has ${S.pageCount.value} page(s) - nothing to swipe to`];
  await pageSwipe(0.8, 0.2);
  await pageSwipe(0.2, 0.8);
  window.__powosRenders.start();
  const fails = [];
  const runs = [];
  for (const [a, b, want] of [[0.8, 0.2, 1], [0.2, 0.8, 0]]) {
    const r = await pageSwipe(a, b);
    runs.push(r);
    if (S.page.value !== want) fails.push(`HP4: the swipe ${a}->${b} left home on page ${S.page.value}, want ${want}`);
  }
  window.__powosRenders.stop();
  await aiPeek();
  const peek = await aiPeek();
  if (S.page.value !== 0) fails.push(`HP4: a drag toward PowOS AI's page and back left home on page ${S.page.value}, want 0`);
  const peekReads = peek.map((m) => m.n);
  console.warn(`[gate] page-swipe-perf: toward PowOS AI's page, reads per move ${peekReads.join(",")}`);
  const firstPeek = peek.find((m) => m.n);
  if (firstPeek) fails.push(`HP4: a move toward PowOS AI's page read style or size ${Math.max(...peekReads)}x (first: ${firstPeek.where[0]})`);
  return [...fails, ...judge(runs)];
}

const home = () => document.querySelectorAll(".home *");

/** The two measured swipes' verdict: reads in a move or the release, renders while the finger moved. */
function judge(runs) {
  const fails = [];
  const moveReads = runs.flatMap((r) => r.moves.map((m) => m.n));
  const endReads = runs.map((r) => r.end.n);
  // Per move: a component rendering in half the swipe's 9 moves or more. A live row's own clock (PowOS AI's working-now
  // timers) renders once or twice in that time on its own, the swipe or not - under the gate's load, more frames apart.
  const during = runs.flatMap((r) => r.rendered.filter((x) => x.renders >= 5).map((x) => `${x.name} ${x.renders}`));
  const after = runs.map((r) => r.after.byCount.reduce((a, x) => a + x.renders, 0));
  const regions = runs.map((r) => r.regions);
  window.__pageSwipe = `reads per move ${moveReads.join(",")}; at the release ${endReads.join(",")}; region report after it ${regions.map((g) => `${g.style} style/${g.size} size`).join(", ")} (${home().length} home elements); renders during the moves: ${during.join(", ") || "none"}; after each release ${after.join(",")} (${runs.map((r) => r.after.byCount.slice(0, 4).map((x) => `${x.name} ${x.renders}`).join(" ")).join(" | ")})`;
  console.warn(`[gate] page-swipe-perf: ${window.__pageSwipe}`);
  const firstMove = runs.flatMap((r) => r.moves).find((m) => m.n);
  if (Math.max(...moveReads) > 0) fails.push(`HP4: a page-swipe move read style or size ${Math.max(...moveReads)}x (a forced layout after the track's write; first: ${firstMove?.where[0]})`);
  const firstEnd = runs.find((r) => r.end.n)?.end;
  if (Math.max(...endReads) > 0) fails.push(`HP4: a page-swipe release read style or size ${Math.max(...endReads)}x (the 64 ms forced layout on touchend; first: ${firstEnd?.where.join(" ; ")})`);
  // The settle's region report: the kept scrollers' sizes and rects only - no style read (no walk of home), and never
  // one read per element of home.
  const walked = regions.find((g) => g.style > 0 || g.size > home().length / 4);
  if (walked) fails.push(`HP5: home's region report re-walked home after a page swipe: ${walked.style} style / ${walked.size} size reads (first: ${walked.where.join(" ; ")})`);
  if (during.length) fails.push(`HP4: components rendered while the finger moved the pages: ${during.join(", ")}`);
  return fails;
}
