// The pet's movement, headless (shell/ui/petphys.ts + petai.ts): node --test shell/test/petphys.test.ts
// Every run goes through sim(), which fails the moment one step moves it further than a step can (no teleports).
import { test } from "node:test";
import assert from "node:assert/strict";
import { DT, FLOOR, MAX_STEP, NO_INPUT, T, makePet, scaleOf, standOn, step, atRest, type Input, type Pet, type Rect, type World } from "../ui/petphys.ts";
import { Driver, offFloor, plan } from "../ui/petai.ts";

const SIZE = 64;

/** A folded phone's home (CSS px): two columns of tiles 8 px apart, the search pill at the foot. */
function home(): World {
  const R = (key: string, l: number, t: number, r: number, b: number): Rect => ({ key, l, t, r, b });
  return {
    w: 384,
    h: 840,
    top: 32,
    rects: [
      R("clock", 12, 150, 372, 260),
      R("weather", 12, 268, 188, 420),
      R("lights", 196, 268, 372, 344),
      R("notes", 196, 352, 372, 520),
      R("board", 12, 428, 188, 600),
      R("music", 196, 528, 372, 610),
      R("bar", 24, 760, 360, 808),
    ],
  };
}

interface Run {
  maxStep: number;
  steps: number;
}

/** Steps [p] with [input] until [until] (or [max] steps); asserts no step moves it more than MAX_STEP. */
function sim(p: Pet, world: World | ((n: number) => World), input: (p: Pet, w: World, n: number) => Input | null, until: (p: Pet, n: number) => boolean, max = 2400): Run {
  let maxStep = 0;
  let n = 0;
  for (; n < max; n++) {
    const w = typeof world === "function" ? world(n) : world;
    const i = input(p, w, n);
    if (i === null) break;
    const px = p.x;
    const py = p.y;
    step(p, i, w);
    const d = Math.hypot(p.x - px, p.y - py);
    maxStep = Math.max(maxStep, d);
    assert.ok(d <= MAX_STEP, `step ${n} moved ${d.toFixed(1)} px (max ${MAX_STEP.toFixed(1)})`);
    assert.ok(Number.isFinite(p.x) && Number.isFinite(p.y), "position is a number");
    const { sx, sy } = scaleOf(p);
    assert.ok(sx >= 0.75 && sx <= 1.25 && sy >= 0.75 && sy <= 1.25, `scale ${sx},${sy} within 25%`);
    if (until(p, n)) break;
  }
  return { maxStep, steps: n };
}

const hold = (i: Partial<Input>) => () => ({ ...NO_INPUT, ...i });

test("lands on a tile's top edge, and settles to rest", () => {
  const w = home();
  const p = makePet(100, 60, SIZE);
  sim(p, w, hold({}), (q) => q.ground != null);
  assert.equal(p.ground, "clock");
  assert.equal(p.y, 150);
  sim(p, w, hold({}), (q) => atRest(q, w), 240);
  assert.ok(atRest(p, w), "comes to rest");
});

test("never tunnels: a max-speed fall onto a 1 px rect", () => {
  for (let offset = 0; offset < 13; offset += 0.7) {
    const w: World = { w: 384, h: 840, top: 0, rects: [{ key: "thin", l: 50, t: 500 + offset, r: 300, b: 501 + offset }] };
    const p = makePet(150, 40, SIZE);
    p.vy = T.maxFall;
    sim(p, w, hold({}), (q) => q.ground != null);
    assert.equal(p.ground, "thin", `offset ${offset}`);
    assert.equal(p.y, 500 + offset);
  }
});

test("variable jump height, coyote time and the jump buffer", () => {
  const w: World = { w: 384, h: 840, top: 0, rects: [] };
  const apex = (holdSteps: number) => {
    const p = makePet(190, 840, SIZE);
    standOn(p, null, w);
    let top = p.y;
    sim(p, w, (_q, _w, n) => ({ ...NO_INPUT, jump: n < holdSteps }), (q, n) => ((top = Math.min(top, q.y)), n > 5 && q.ground != null));
    return 840 - top;
  };
  const tap = apex(1);
  const full = apex(200);
  assert.ok(full > T.jumpH * 0.92 && full < T.jumpH * 1.08, `full jump ${full.toFixed(0)} px`);
  assert.ok(tap < full * 0.35, `a tap ${tap.toFixed(0)} px is a small hop`);
  assert.ok(apex(12) > tap && apex(12) < full, "held a while: in between");

  // Coyote: a jump pressed a few steps after walking off an edge still jumps.
  const w2: World = { w: 384, h: 840, top: 0, rects: [{ key: "a", l: 0, t: 400, r: 200, b: 500 }] };
  const p = makePet(190, 400, SIZE);
  standOn(p, w2.rects[0], w2);
  let offAt = -1;
  sim(p, w2, (q, _w, n) => {
    if (offAt < 0 && !q.ground) offAt = n;
    return { ...NO_INPUT, right: true, jump: offAt >= 0 && n === offAt + 5 };
  }, (q) => q.vy < 0);
  assert.ok(p.vy < 0, "jumped after leaving the edge");

  // Buffer: pressed just before landing, it jumps on touching down.
  const q = makePet(190, 700, SIZE);
  let landedOnce = false;
  sim(q, w, (r) => ({ ...NO_INPUT, jump: r.y > 830 && !landedOnce }), (r) => {
    if (r.ground) landedOnce = true;
    return landedOnce && r.vy < 0;
  });
  assert.ok(q.vy < 0, "buffered jump fired on landing");
});

test("slides down a wall it presses into, and kicks off it", () => {
  const w: World = { w: 384, h: 840, top: 0, rects: [{ key: "tower", l: 250, t: 200, r: 372, b: 800 }] };
  const p = makePet(200, 300, SIZE);
  // Falling beside the tower, pressing into it.
  const speeds: number[] = [];
  sim(p, w, hold({ right: true }), (q, n) => {
    if (q.wall === 1) speeds.push(q.vy);
    return n > 120;
  });
  assert.ok(speeds.length > 30, "touched the wall");
  assert.ok(Math.max(...speeds.slice(20)) <= T.wallSlide + 1, `slid at ${Math.max(...speeds.slice(20)).toFixed(0)} px/s`);
  // Wall jump: away from the wall and up.
  sim(p, w, (q, _w, n) => ({ ...NO_INPUT, right: true, jump: n < 5 }), (_q, n) => n >= 1);
  assert.ok(p.vy < -500 && p.vx < 0, `kicked off: vx ${p.vx.toFixed(0)} vy ${p.vy.toFixed(0)}`);
});

test("climbs a shaft by wall jumps", () => {
  // Two walls 70 px apart, 500 px tall: only wall jumps get it out the top.
  const w: World = {
    w: 384,
    h: 840,
    top: 0,
    rects: [
      { key: "lw", l: 0, t: 300, r: 150, b: 840 },
      { key: "rw", l: 220, t: 300, r: 384, b: 840 },
      { key: "ledge", l: 0, t: 200, r: 384, b: 210 },
    ],
  };
  const p = makePet(185, 840, SIZE);
  standOn(p, null, w);
  let side = 1;
  let wasJump = false;
  sim(p, w, (q) => {
    if (q.wall) side = q.wall;
    const jump = !wasJump && (q.ground != null || (q.wall !== 0 && q.vy > -150));
    wasJump = jump || (wasJump && q.rising);
    return { left: side < 0 && q.lock === 0 ? true : q.lock > 0 && q.wallSide > 0, right: side > 0 && q.lock === 0 ? true : q.lock > 0 && q.wallSide < 0, jump: jump || q.rising };
  }, (q) => q.y < 300);
  assert.ok(p.y < 300, `climbed to ${p.y.toFixed(0)}`);
});

test("stays continuous when its rect moves, jumps away, or goes", () => {
  // Moving slowly: carried, still standing on it.
  let rect: Rect = { key: "m", l: 100, t: 500, r: 260, b: 560 };
  const p = makePet(180, 500, SIZE);
  const w = (): World => ({ w: 384, h: 840, top: 0, rects: [rect] });
  standOn(p, rect, w());
  sim(p, (n) => ((rect = { ...rect, l: 100 + n * 0.8, r: 260 + n * 0.8, t: 500 - n * 0.5, b: 560 - n * 0.5 }), w()), hold({}), (_q, n) => n >= 100);
  assert.equal(p.ground, "m");
  assert.ok(Math.abs(p.x - (180 + 100 * 0.8)) < 2 && Math.abs(p.y - rect.t) < 1, "rode along");
  // A page swipe: the rect is 300 px away in one go - it doesn't snap there, it falls where it is.
  const x0 = p.x;
  rect = { ...rect, l: rect.l - 300, r: rect.r - 300 };
  const run = sim(p, w(), hold({}), (q) => q.ground != null && q.ground !== "m");
  assert.equal(p.ground, FLOOR);
  assert.ok(Math.abs(p.x - x0) < 1, "fell straight down");
  assert.ok(run.maxStep < T.maxFall * DT * 1.1, `max ${run.maxStep.toFixed(1)} px a step`);
  // Gone under it: falls to the floor.
  const q = makePet(180, 300, SIZE);
  let rects: Rect[] = [{ key: "g", l: 100, t: 300, r: 260, b: 360 }];
  standOn(q, rects[0], { w: 384, h: 840, top: 0, rects });
  sim(q, (n) => ((rects = n < 10 ? rects : []), { w: 384, h: 840, top: 0, rects }), hold({}), (r) => r.ground === FLOOR);
  assert.equal(q.ground, FLOOR);
  // A rect rising up through it (its top 60 px above its feet): carried up, a glide, not a jump.
  const s = makePet(180, 600, SIZE);
  let up: Rect = { key: "u", l: 100, t: 600, r: 260, b: 700 };
  standOn(s, up, { w: 384, h: 840, top: 0, rects: [up] });
  up = { ...up, t: 540, b: 640 };
  const r2 = sim(s, { w: 384, h: 840, top: 0, rects: [up] }, hold({}), (r) => r.y <= 540.01);
  assert.equal(s.ground, "u");
  assert.ok(r2.steps >= 9, "took several steps");
});

test("a shrinking screen moves it back in, a few px a step", () => {
  const p = makePet(800, 840, SIZE);
  const w: World = { w: 384, h: 840, top: 0, rects: [] };
  standOn(p, null, { ...w, w: 900 });
  const run = sim(p, w, hold({}), (q) => q.x + q.hw / 2 <= w.w + 0.01);
  assert.ok(run.steps > 50, "moved, not put");
  assert.ok(run.maxStep <= 4.01, `max ${run.maxStep.toFixed(1)} px a step`);
});

test("reaches 5 targets on home by pressing buttons only", () => {
  const w = home();
  const p = makePet(300, 760, SIZE);
  standOn(p, w.rects.find((r) => r.key === "bar")!, w);
  const goals = [
    { key: "music", x: 300 },
    { key: "clock", x: 60 },
    { key: "lights", x: 280 },
    { key: "board", x: 100 },
    { key: "bar", x: 330 },
  ];
  for (const g of goals) {
    let reached: boolean | null = null;
    const d = new Driver(g, (ok) => (reached = ok));
    const run = sim(p, w, (q) => d.input(q, w), () => false, 120 * 20);
    assert.equal(reached, true, `reached ${g.key} (route ${JSON.stringify(d.route?.hops.map((h) => h.to + ":" + h.mode))})`);
    assert.equal(p.ground, g.key);
    assert.ok(Math.abs(p.x - g.x) < 6, `${g.key}: at ${p.x.toFixed(0)}, wanted ${g.x}`);
    assert.ok(run.maxStep < T.maxFall * DT * 1.1, `max ${run.maxStep.toFixed(1)} px a step`);
    console.log(`  ${g.key}: ${(run.steps * DT).toFixed(2)} s, ${d.route!.hops.length} hops (${d.route!.hops.map((h) => h.mode).join(" ")}), max ${run.maxStep.toFixed(1)} px/step`);
  }
});

test("replans from where it is when the next rect of its route goes", () => {
  const base = home();
  const p = makePet(300, 760, SIZE);
  standOn(p, base.rects.find((r) => r.key === "bar")!, base);
  let reached: boolean | null = null;
  const d = new Driver({ key: "clock", x: 300 }, (ok) => (reached = ok));
  let gone: string | null = null;
  const world = (): World => (gone ? { ...base, rects: base.rects.filter((r) => r.key !== gone) } : base);
  sim(p, world, (q, w) => {
    // On its route's first surface: the next one is taken away (a widget removed, a page swiped under it).
    const hops = d.route?.hops;
    if (!gone && hops && hops.length > 2 && q.ground === hops[0].to) gone = hops[1].to;
    return d.input(q, w);
  }, () => false, 120 * 30);
  assert.ok(gone, "a rect of its route went");
  assert.equal(reached, true, `reached clock without ${gone}`);
  assert.equal(p.ground, "clock");
});

test("the phone's real home: from the pill up to a top tile (500 px up, no walls between) and back", () => {
  // As measured on the phone (404x899 CSS px, folded): two top tiles (their tops lowered under the status bar by
  // petperch.ts), the search pill 500 px below them, nothing in between.
  const w: World = {
    w: 404,
    h: 899,
    top: 24,
    rects: [
      { key: "today", l: 12, t: 92, r: 202, b: 262 },
      { key: "perf", l: 202, t: 92, r: 392, b: 194 },
      { key: "bar", l: 36, t: 759, r: 368, b: 807 },
    ],
  };
  const p = makePet(300, 759, SIZE);
  standOn(p, w.rects[2], w);
  for (const g of [{ key: "today", x: 100 }, { key: "perf", x: 300 }, { key: "bar", x: 200 }]) {
    let reached: boolean | null = null;
    const d = new Driver(g, (ok) => (reached = ok), 0.5);
    const run = sim(p, w, (q) => d.input(q, w), () => false, 120 * 20);
    assert.equal(reached, true, `reached ${g.key} (route ${JSON.stringify(d.route?.hops.map((h) => h.to + ":" + h.mode + (h.side ?? "")))})`);
    assert.equal(p.ground, g.key);
    console.log(`  real home -> ${g.key}: ${(run.steps * DT).toFixed(2)} s, ${d.route!.hops.map((h) => h.mode + (h.side ? " side" : "")).join(", ")}`);
  }
});

test("the phone's real home: today -> performance stays up on the tops (the recording's fall)", () => {
  const w: World = {
    w: 404,
    h: 899,
    top: 46,
    rects: [
      { key: "today", l: 12, t: 114, r: 202, b: 262 },
      { key: "perf", l: 202, t: 114, r: 392, b: 194 },
      { key: "bar", l: 36, t: 759, r: 368, b: 807 },
    ],
  };
  for (const x of [40, 107, 190]) {
    const p = makePet(x, 114, SIZE);
    standOn(p, w.rects[0], w);
    let reached: boolean | null = null;
    const d = new Driver({ key: "perf", x: 297 }, (ok) => (reached = ok), 0.5);
    let lowest = 0;
    sim(p, w, (q) => d.input(q, w), (q) => ((lowest = Math.max(lowest, q.y)), false), 120 * 10);
    assert.equal(reached, true, `from x=${x}`);
    assert.ok(lowest <= 114.01, `from x=${x}: never below the tops (lowest ${lowest.toFixed(0)})`);
  }
});

test("the phone's real home: off the screen's foot to a perch within 2 s, from each corner and the middle", () => {
  const w: World = {
    w: 404,
    h: 899,
    top: 46,
    rects: [
      { key: "today", l: 12, t: 114, r: 202, b: 262 },
      { key: "perf", l: 202, t: 114, r: 392, b: 194 },
      { key: "bar", l: 36, t: 759, r: 368, b: 807 },
    ],
  };
  for (const x of [20, 202, 384]) {
    const p = makePet(x, 899, SIZE);
    standOn(p, null, w);
    const d = new Driver(offFloor(w, p)!, () => {}, 0.5);
    const run = sim(p, w, (q) => d.input(q, w), (q) => q.ground != null && q.ground !== FLOOR, 120 * 2);
    assert.ok(p.ground && p.ground !== FLOOR, `from x=${x}: on ${p.ground} after ${(run.steps * DT).toFixed(2)} s`);
    console.log(`  floor x=${x} -> ${p.ground} in ${(run.steps * DT).toFixed(2)} s`);
  }
});

test("an unreachable goal: as near as it can, no snap", () => {
  const w: World = { w: 384, h: 840, top: 0, rects: [{ key: "sky", l: 150, t: 100, r: 250, b: 110 }] };
  const p = makePet(60, 840, SIZE);
  standOn(p, null, w);
  const r = plan(w, p, { key: "sky", x: 200 });
  assert.ok(r && r.partial, "partial route");
  let reached: boolean | null = null;
  const d = new Driver({ key: "sky", x: 200 }, (ok) => (reached = ok));
  sim(p, w, (q) => d.input(q, w), () => false, 120 * 10);
  assert.equal(reached, false);
  assert.equal(p.ground, FLOOR);
  assert.ok(Math.abs(p.x - 200) < 6, "went under it");
});
