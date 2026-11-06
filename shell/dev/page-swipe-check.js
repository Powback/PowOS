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

/** Counts getComputedStyle, rect and size reads while [fn] runs and the microtasks after it (Preact's renders, effects). */
async function countReads(fn) {
  let n = 0;
  const where = [];
  const note = () => { n++; if (where.length < 3) where.push((new Error().stack ?? "").split("\n").slice(2, 4).map((l) => l.trim()).join(" < ")); };
  const gcs = window.getComputedStyle, rect = Element.prototype.getBoundingClientRect;
  const props = [[HTMLElement.prototype, "offsetWidth"], [HTMLElement.prototype, "offsetHeight"], [Element.prototype, "clientHeight"], [Element.prototype, "clientWidth"]];
  const saved = props.map(([o, k]) => Object.getOwnPropertyDescriptor(o, k));
  window.getComputedStyle = function (...a) { note(); return gcs.apply(this, a); };
  Element.prototype.getBoundingClientRect = function () { note(); return rect.call(this); };
  props.forEach(([o, k], i) => Object.defineProperty(o, k, { ...saved[i], get() { note(); return saved[i].get.call(this); } }));
  try {
    fn();
    for (let i = 0; i < 6; i++) await Promise.resolve();
  } finally {
    window.getComputedStyle = gcs;
    Element.prototype.getBoundingClientRect = rect;
    props.forEach(([o, k], i) => Object.defineProperty(o, k, saved[i]));
  }
  return { n, where };
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
  await window.__gw.sleep(600);
  const after = window.__powosRenders.top(500);
  return { moves, rendered, end, after };
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
  return [...fails, ...judge(runs)];
}

/** The two measured swipes' verdict: reads in a move or the release, renders while the finger moved. */
function judge(runs) {
  const fails = [];
  const moveReads = runs.flatMap((r) => r.moves.map((m) => m.n));
  const endReads = runs.map((r) => r.end.n);
  // Per move: a component rendering in half the swipe's 9 moves or more. A live row's own clock (PowOS AI's working-now
  // timers) renders once or twice in that time on its own, the swipe or not - under the gate's load, more frames apart.
  const during = runs.flatMap((r) => r.rendered.filter((x) => x.renders >= 5).map((x) => `${x.name} ${x.renders}`));
  const after = runs.map((r) => r.after.byCount.reduce((a, x) => a + x.renders, 0));
  window.__pageSwipe = `reads per move ${moveReads.join(",")}; at the release ${endReads.join(",")}; renders during the moves: ${during.join(", ") || "none"}; after each release ${after.join(",")} (${runs.map((r) => r.after.byCount.slice(0, 4).map((x) => `${x.name} ${x.renders}`).join(" ")).join(" | ")})`;
  console.warn(`[gate] page-swipe-perf: ${window.__pageSwipe}`);
  const firstMove = runs.flatMap((r) => r.moves).find((m) => m.n);
  if (Math.max(...moveReads) > 0) fails.push(`HP4: a page-swipe move read style or size ${Math.max(...moveReads)}x (a forced layout after the track's write; first: ${firstMove?.where[0]})`);
  const firstEnd = runs.find((r) => r.end.n)?.end;
  if (Math.max(...endReads) > 0) fails.push(`HP4: a page-swipe release read style or size ${Math.max(...endReads)}x (the 64 ms forced layout on touchend; first: ${firstEnd?.where.join(" ; ")})`);
  if (during.length) fails.push(`HP4: components rendered while the finger moved the pages: ${during.join(", ")}`);
  return fails;
}
