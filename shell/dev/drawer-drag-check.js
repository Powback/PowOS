/**
 * PERF-P5 (perf-scenarios 11-02 18:13: the first touchmove of each launcher drag 107 / 49 / 31 ms of script + 52 / 32 /
 * 23 ms of forced layout; AppCell + AppIcon 211 renders, Node 315, Tile 102 in a launcher open): scripted drawer drags
 * up from home and back down, the launcher mounted by the first. During the second no app cell, icon, tile or Home
 * renders (the drag drives --p / Web Animations only), and its moves read no style or size (the followers' keyframes
 * were built at the down).
 */
function drawerDragTouch() {
  const H = innerHeight, x = innerWidth * 0.75;
  const tgt = document.elementFromPoint(x, H * 0.7);
  const fire = (type, y) => {
    const t = new Touch({ identifier: 9, target: tgt, clientX: x, clientY: y });
    const init = { touches: type === "touchend" ? [] : [t], changedTouches: [t], bubbles: true, cancelable: true };
    // The gate's Chromium has no touch input: Preact bound home's onTouchStart as "TouchStart" there - both names.
    for (const name of [type, `Touch${type.slice(5, 6).toUpperCase()}${type.slice(6)}`]) tgt.dispatchEvent(new TouchEvent(name, init));
  };
  return { H, fire };
}

/** Counts getComputedStyle and size reads while [fn] runs: each one after a write is a forced style recalc / layout. */
function countReads(fn) {
  let n = 0;
  const gcs = window.getComputedStyle;
  const props = [[HTMLElement.prototype, "offsetWidth"], [HTMLElement.prototype, "offsetHeight"], [Element.prototype, "clientHeight"], [Element.prototype, "clientWidth"]];
  const saved = props.map(([o, k]) => Object.getOwnPropertyDescriptor(o, k));
  window.getComputedStyle = function (...a) { n++; return gcs.apply(this, a); };
  props.forEach(([o, k], i) => Object.defineProperty(o, k, { ...saved[i], get() { n++; return saved[i].get.call(this); } }));
  try { fn(); } finally {
    window.getComputedStyle = gcs;
    props.forEach(([o, k], i) => Object.defineProperty(o, k, saved[i]));
  }
  return n;
}

/** One drag up 16 moves and back down; [during] runs after the moves, before the release. Per move: its reads. */
async function drawerDrag(during) {
  const { H, fire } = drawerDragTouch();
  let y = H * 0.7;
  fire("touchstart", y);
  await window.__gw.frames(1);
  const reads = [];
  for (let i = 0; i < 16; i++) {
    y -= 8;
    reads.push(countReads(() => fire("touchmove", y)));
    await window.__gw.frames(1);
  }
  const out = { reads, drove: document.querySelector(".home .launcher")?.getAnimations().some((a) => a.id === "drawer") ?? false, home: document.querySelector(".home")?.className, ...during?.() };
  fire("touchmove", H * 0.95);
  fire("touchend", H * 0.95);
  await window.__gw.sleep(500);
  await window.__gw.settled();
  return out;
}

export async function drawerDragRenders() {
  const S = await window.__gw.mod("./state.ts");
  await window.__gw.settled();
  const warm = await drawerDrag();
  const Gd = await window.__gw.mod("./ui/grid.tsx");
  const { effect } = await window.__gw.mod("@preact/signals");
  const geo = [];
  // Home's grid as laid out (rows, cell size): a change re-renders every tile.
  const stopGeo = effect(() => { const g = Gd.geometry.value; geo.push(`${g.rows} rows ${g.width}x${Math.round(g.height)}`); });
  window.__powosRenders.start();
  window.__powosRenders.reset();
  const run = await drawerDrag(() => ({ rows: window.__powosRenders.top(500).byCount }));
  window.__powosRenders.stop();
  stopGeo();
  const n = (name) => run.rows.filter((r) => r.name === name || r.name === `memo(${name})`).reduce((a, r) => a + r.renders, 0);
  const counts = ["AppCell", "AppIcon", "Tile", "Home", "AppList"].map((k) => [k, n(k)]);
  window.__drawerDrag = `during the drag: ${counts.map(([k, v]) => `${k} ${v}`).join(", ")} renders; style/size reads per move ${run.reads.join(",")}; home's grid re-laid ${geo.length - 1}x`;
  console.warn(`[gate] drawer-drag-renders: ${window.__drawerDrag}`);
  const fails = [];
  if (!warm.drove || !run.drove) fails.push(`PERF-P5: the drag didn't drive the launcher (no drawer animation on .launcher; home "${run.home}")`);
  if (counts.some(([, v]) => v > 0)) fails.push(`PERF-P5: the drag re-rendered the app list or home (${window.__drawerDrag})`);
  if (geo.length > 1) fails.push(`PERF-P5: the drag re-laid home's grid ${geo.length - 1}x (${geo.slice(-2).join(" -> ")}): every tile re-rendered`);
  if (Math.max(...run.reads) > 0) fails.push(`PERF-P5: a drag move read style or size ${Math.max(...run.reads)}x (forced layout; want 0: built at the down)`);
  if (S.drawer.value !== 0) fails.push("PERF-P5: the drag back down didn't leave the drawer shut");
  return fails;
}


/**
 * HZ-VOTE (perf-1793639664326, 11-02: the 120 Hz vote must hold from a gesture's touchstart through its settle): the
 * launcher's drawer settle after the finger lets go is a Web Animation (gesture.ts "drawer"), which fires no
 * transition/animation event - refresh.ts must still tell the host ("boost 1" to PowosNative) while it plays and give
 * it back ("boost 0") after it lands plus its tail. The scene's page has a recording PowosNative (gate.mjs).
 */
export async function drawerSettleHoldsRefresh() {
  const S = await window.__gw.mod("./state.ts");
  const G = await window.__gw.mod("./ui/gesture.ts");
  const log = window.__nativeMsgs;
  const fails = [];
  if (!log) return ["HZ-VOTE: no recording PowosNative on the page (gate.mjs evaluateOnNewDocument)"];
  await window.__gw.settled();
  await drawerDrag();
  await window.__gw.sleep(800);
  const { H, fire } = drawerDragTouch();
  const last = (t) => log.filter(([at]) => at <= t).at(-1)?.[1] ?? "none";
  let y = H * 0.7;
  fire("touchstart", y);
  await window.__gw.frames(1);
  for (let i = 0; i < 16; i++) {
    y -= 8;
    fire("touchmove", y);
    await window.__gw.frames(1);
  }
  const before = performance.now();
  const idleBefore = last(before);
  const busy = document.getAnimations().filter((a) => a.playState === "running").map((a) => `${a.id || a.animationName || a.transitionProperty}:${a.effect?.target?.className?.toString().slice(0, 24)}`);
  // Back down part way, slowly (no fling): the release settles the drawer shut from there, on its Web Animation.
  for (let i = 0; i < 8; i++) {
    y += 8;
    fire("touchmove", y);
    await window.__gw.frames(1);
  }
  fire("touchend", y);
  const end = performance.now();
  await window.__gw.sleep(G.SETTLE_MS / 3);
  const mid = performance.now();
  const drawerAnims = document.getAnimations().filter((a) => a.id === "drawer").map((a) => `${a.playState}@${Math.round(a.currentTime ?? -1)}/${Math.round(Number(a.effect?.getComputedTiming().endTime))}`);
  const settling = drawerAnims.some((x) => x.startsWith("running"));
  const during = last(mid);
  await window.__gw.sleep(G.SETTLE_MS + 300 + 400);
  const after = last(performance.now());
  window.__hzVote = `before release: ${idleBefore}; settle running ${settling} at +${Math.round(mid - end)} ms: ${during}; landed + tail: ${after}; msgs ${JSON.stringify(log.map(([t, m]) => [Math.round(t - end), m]).slice(-6))}; running at release ${JSON.stringify(busy.slice(0, 8))}; drawer anims after ${JSON.stringify(drawerAnims.slice(0, 4))}; drawer ${S.drawer.value}`;
  console.warn(`[gate] drawer-settle-refresh: ${window.__hzVote}`);
  if (!settling) fails.push(`HZ-VOTE: no running "drawer" Web Animation after the release - the scene didn't drive a settle (${window.__hzVote})`);
  else if (during !== "boost 1") fails.push(`HZ-VOTE: the drawer's settle ran with the 120 Hz vote off (${window.__hzVote})`);
  if (after !== "boost 0") fails.push(`HZ-VOTE: the vote wasn't given back after the settle landed (${window.__hzVote})`);
  if (S.drawer.value !== 0) S.drawer.value = 0;
  return fails;
}
