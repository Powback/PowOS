/**
 * The pet's planner (docs/PET.md v2, step e): it gets somewhere by pressing buttons - left, right, jump - never by
 * being put there. petphys.ts is the only thing that moves it.
 *
 * A goal is a surface (a rect's key, or the screen's foot) and an x on it. The route there is a chain of hops between
 * surfaces, found cheapest first (Dijkstra by time), and every hop it considers is first PLAYED in a copy of the world
 * with the same physics and the same hop driver that will drive it live - so a route only holds hops that really land.
 * A hop: run to a take-off point (or off the end), then jump (held as long as the next surface needs) or drop, steering
 * in the air toward where it should come down; a wall in the way below the target's top is climbed (wall jumps).
 *
 * Live, the driver plays the route closed-loop on the live world: rects that moved a little are steered around. When a
 * hop ends anywhere but where it should (a rect moved or went, it missed), it replans from where it is - never a reset.
 * A goal it can't reach: as close as it can get (the surface nearest the goal it can reach).
 */
import { DT, FLOOR, NO_INPUT, T, step, type Input, type Pet, type Rect, type World } from "./petphys.ts";

export interface Goal {
  key: string;
  x: number;
}

interface Hop {
  to: string;
  /** Take-off: run to x0, then jump ("full": held to the top; "auto": as high as [to] needs) or run off ("drop"). */
  x0: number;
  mode: "full" | "auto" | "drop" | "down";
  /** Where to come down on [to]. */
  tx: number;
  /** Stop at x0 before jumping (a standing jump: up a wall beside it), else run through it. */
  stand?: boolean;
  /** Up the screen's side (-1 left, 1 right): wall jumps up it until [to]'s top is in reach. */
  side?: number;
}

export interface Route {
  hops: Hop[];
  goal: Goal;
  /** The goal was out of reach: this ends as near it as it can. */
  partial: boolean;
}

/** A surface: a rect, or the screen's foot. */
function surface(world: World, key: string): Rect | null {
  if (key === FLOOR) return { key: FLOOR, l: 0, t: world.h, r: world.w, b: world.h + 1 };
  return world.rects.find((r) => r.key === key) ?? null;
}

const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));
const now = () => (typeof performance !== "undefined" ? performance.now() : Date.now());
const inset = (p: Pet, r: Rect, x: number) => {
  const m = Math.min(p.hw * 0.5, (r.r - r.l) / 2);
  return clamp(x, r.l + m, r.r - m);
};

/** One hop, closed loop: what to press this step. */
export class HopDriver {
  phase: "run" | "air" = "run";
  t = 0;
  dir0 = 0;
  kicked = false;
  hop: Hop;
  from: string;
  constructor(hop: Hop, from: string) {
    this.hop = hop;
    this.from = from;
  }

  /** null: the hop is over (look at p.ground: on [hop.to] it worked). */
  input(p: Pet, world: World): Input | null {
    const h = this.hop;
    this.t += DT;
    if (p.ground === h.to) return null;
    if (this.t > 4) return null;
    const to = surface(world, h.to);
    if (!to) return null;
    const k = p.k;
    const half = p.hw / 2;
    if (this.phase === "run") {
      if (p.ground && p.ground !== this.from) return null;
      if (!p.ground) this.phase = "air";
      else {
        if (!this.dir0) this.dir0 = Math.sign(h.x0 - p.x) || Math.sign(h.tx - p.x) || 1;
        if (h.stand) {
          const w = walkInput(p, h.x0);
          if (w && Math.abs(h.x0 - p.x) > 2.5) return w;
          if (Math.abs(p.vx) > 20) return { ...NO_INPUT };
        }
        const there = h.stand || (this.dir0 > 0 ? p.x >= h.x0 - 1 : p.x <= h.x0 + 1);
        if (h.mode === "down" && there) {
          this.phase = "air";
          return { ...NO_INPUT, down: true };
        }
        if (h.mode !== "drop" && there) {
          this.phase = "air";
          const d = h.stand ? 0 : Math.sign(h.tx - p.x);
          return { left: d < 0, right: d > 0, jump: true };
        }
        const d = h.mode === "drop" && there ? Math.sign(h.tx - p.x) || this.dir0 : this.dir0;
        return { left: d < 0, right: d > 0, jump: false };
      }
    }
    // In the air.
    if (p.ground) return null;
    const fallG = T.gravity * k * T.fallMult;
    // How high over [to]'s top to aim: a little, less where a tile sits just above it (it has to get in under that).
    let room = Infinity;
    for (const r of world.rects) if (r.key !== to.key && r.l < to.r && r.r > to.l && r.b <= to.t + 1) room = Math.min(room, to.t - r.b);
    const clear = Math.min(26 * k, Math.max(3, room / 2));
    // Hold the jump while it isn't high enough yet: [to]'s top (and a little), or for a "full" jump, all the way.
    // (After a wall kick only as high as [to] needs: higher, it would come down on whatever is beside the wall.)
    const v = p.vy * T.jumpCut;
    const short = p.y - (v * v) / (2 * fallG) > to.t - clear;
    let jump = p.rising && ((h.mode === "full" && !this.kicked) || short);
    // Steering: below [to]'s top and beside it, toward its wall (to climb it); else to the landing point.
    const below = p.y > to.t - 1;
    const outsideL = p.x + half <= to.l + 0.5;
    const outsideR = p.x - half >= to.r - 0.5;
    // (Rising high enough to clear its top: over it already - a wall it touches on the way up only slides it up.)
    const g0 = p.rising ? T.gravity * k : fallG;
    const apex = p.vy < 0 ? p.y - (p.vy * p.vy) / (2 * g0) : p.y;
    let aim = h.tx;
    const toWall = below && apex > to.t - 6 && h.to !== FLOOR && (outsideL || outsideR);
    if (toWall) aim = outsideL ? to.l - half - 0.3 : to.r + half + 0.3;
    // Up the screen's side: to it, and up it, until a jump clears [to]'s top.
    const edge = !toWall && !!h.side && below && apex > to.t - 6;
    if (edge) aim = h.side! < 0 ? half - 0.3 : world.w - half + 0.3;
    // When it comes down to [to]'s top (the falling branch), or soon if it can't get that high.
    const g = p.rising ? T.gravity * k : fallG;
    const dy = to.t - p.y;
    const disc = p.vy * p.vy + 2 * g * dy;
    const tl = disc >= 0 ? Math.max(0.06, (-p.vy + Math.sqrt(disc)) / g) : Math.max(0.06, -p.vy / g);
    const want = clamp((aim - p.x) / tl, -T.runMax * k, T.runMax * k);
    const dead = 18 * k;
    let d = p.vx < want - dead ? 1 : p.vx > want + dead ? -1 : 0;
    // Close to the wall it's going for: pressed into it (the wall stops it; pressing is what makes it slide).
    // (Only with its feet at the wall's height: lower, there's no wall yet and pressing would take it in under.)
    if (toWall && Math.abs(aim - p.x) < 8 * k) d = p.y < to.b - 10 * k ? (outsideL ? 1 : -1) : Math.sign(Math.round((aim - p.x - p.vx * 0.08) / 2));
    if (edge && Math.abs(aim - p.x) < 8 * k) d = h.side!;
    // Against a wall below the top: keep pressing into it (slide) and kick off it when the climb has slowed.
    if (p.wall !== 0 && below && ((toWall && p.wall === (outsideL ? 1 : -1)) || (edge && p.wall === h.side))) {
      d = p.wall;
      if (p.vy > -140 * k && !p.jumpWas) {
        jump = true;
        this.kicked = true;
      } else if (p.vy > -140 * k) jump = false;
    } else if (p.lock > 0 && p.wallSide !== 0) {
      // Just kicked off: steer back to the wall once the lock lets it.
      d = p.wallSide;
    }
    return { left: d < 0, right: d > 0, jump };
  }
}

/** Walking to x on the surface it stands on, braking to stop there. */
function walkInput(p: Pet, x: number): Input | null {
  const dx = x - p.x;
  if (Math.abs(dx) < 3 && Math.abs(p.vx) < 1) return null;
  const stop = (p.vx * p.vx) / (2 * T.friction * p.k);
  const d = Math.abs(dx) > stop + 1.5 ? Math.sign(dx) : 0;
  return { left: d < 0, right: d > 0, jump: false };
}

/** A copy of a pet standing still at [x] on [key] (a planning start). */
function standing(p: Pet, world: World, key: string, x: number): Pet {
  const r = surface(world, key)!;
  return { ...p, x, y: r.t, vx: 0, vy: 0, ground: key, gl: r.l, gt: r.t, through: null, wall: 0, coyote: 0, buffer: 0, wallCoyote: 0, wallSide: 0, lock: 0, rising: false, jumpWas: false, s: 0, sv: 0 };
}

/** Plays [hop] from [start] in [world]: where it ended, and how long it took. */
export function playHop(world: World, start: Pet, hop: Hop): { ok: boolean; t: number; end: Pet } {
  const p = { ...start };
  const d = new HopDriver(hop, start.ground ?? "");
  let t = 0;
  for (;;) {
    const i = d.input(p, world);
    if (!i) break;
    step(p, i, world);
    t += DT;
  }
  // Landed: let it come to a stop (its landing x is where the next hop starts).
  for (let n = 0; n < 60 && p.ground && Math.abs(p.vx) > 0.5; n++) {
    step(p, NO_INPUT, world);
    t += DT;
  }
  return { ok: p.ground === hop.to, t, end: p };
}

/** The hops worth trying from [a] (standing at x) to [b], cheapest-looking first. */
function candidates(p: Pet, world: World, a: Rect, x: number, b: Rect, goalX: number | null): Hop[] {
  const half = p.hw / 2;
  const right = (b.l + b.r) / 2 > (a.l + a.r) / 2;
  const near = inset(p, b, goalX ?? clamp(x, b.l, b.r));
  const mid = inset(p, b, (b.l + b.r) / 2);
  const edge = right ? a.r - 2 : a.l + 2;
  const off = right ? a.r + half : a.l - half;
  const under = inset(p, a, near);
  const out: Hop[] = [];
  const higher = b.t < a.t - 2;
  // Over or under it: straight up through it, or off the end down to it.
  if (b.l < a.r && b.r > a.l && higher) out.push({ to: b.key, x0: under, mode: "auto", tx: near }, { to: b.key, x0: under, mode: "full", tx: near });
  if (!higher) out.push({ to: b.key, x0: off, mode: "drop", tx: near });
  // Straight down through it onto [b] under it.
  if (!higher && a.key !== FLOOR && b.l < a.r && b.r > a.l) out.unshift({ to: b.key, x0: inset(p, a, inset(p, b, near)), mode: "down", tx: near, stand: true });
  out.push({ to: b.key, x0: edge, mode: "auto", tx: near }, { to: b.key, x0: edge, mode: "full", tx: near }, { to: b.key, x0: edge, mode: "full", tx: mid });
  // Up its side: from just beside it, a full jump to its wall, then wall jumps.
  if (higher)
    for (const wx of [b.l - half - 2, b.r + half + 2]) if (wx > a.l && wx < a.r) out.push({ to: b.key, x0: wx, mode: "full", tx: near, stand: true });
  // Up the screen's side nearest [b] (home's tiles stand far above the pill, with no wall between): from the end of
  // [a] toward that side, a jump to the screen's edge and wall jumps up it.
  if (higher) {
    const sides = (b.l + b.r) / 2 < world.w / 2 ? [-1, 1] : [1, -1];
    for (const side of sides) {
      const x0 = side < 0 ? Math.max(a.l + 2, half + 1) : Math.min(a.r - 2, world.w - half - 1);
      if (Math.abs((side < 0 ? 0 : world.w) - x0) < world.w * 0.3) out.push({ to: b.key, x0, mode: "full", tx: near, side });
    }
  }
  return out;
}

/** The surfaces there are: the rects and the screen's foot. */
const surfaces = (world: World) => [...world.rects, surface(world, FLOOR)!];

/**
 * The route from where [p] stands to [goal] (null: it isn't standing on anything yet, or there's nowhere to go).
 * Out of reach: the route to the reachable surface nearest the goal, partial.
 */
export function plan(world: World, p: Pet, goal: Goal): Route | null {
  const g = planner(world, p, goal);
  for (;;) {
    const r = g.next();
    if (r.done) return r.value;
  }
}

/** plan(), one played hop at a time (a yield after each): the live driver spreads it over frames. */
export function* planner(world: World, p: Pet, goal: Goal): Generator<void, Route | null> {
  if (!p.ground) return null;
  p = { ...p };
  const all = surfaces(world);
  const goalR = surface(world, goal.key);
  if (!goalR) return null;
  const gx = inset(p, goalR, goal.x);
  type Node = { t: number; x: number; hops: Hop[] };
  const start: string = p.ground!;
  const best = new Map<string, Node>([[start, { t: 0, x: p.x, hops: [] }]]);
  const done = new Set<string>();
  for (;;) {
    let k: string | null = null;
    for (const [key, n] of best) if (!done.has(key) && (k == null || n.t < best.get(k)!.t)) k = key;
    if (k == null) break;
    done.add(k);
    if (k === goal.key) break;
    const cur = best.get(k)!;
    const a = surface(world, k)!;
    const from = k === start && cur.hops.length === 0 ? { ...p } : standing(p, world, k, cur.x);
    for (const b of all) {
      if (b.key === k || done.has(b.key)) continue;
      // A long way across: not worth playing (any height is: the screen's sides climb).
      if (Math.max(b.l - a.r, a.l - b.r) > world.w * 0.6) continue;
      for (const hop of candidates(p, world, a, cur.x, b, b.key === goal.key ? gx : null)) {
        const r = playHop(world, from, hop);
        yield;
        if (!r.ok) continue;
        const t = cur.t + r.t;
        const seen = best.get(b.key);
        if (!seen || t < seen.t) best.set(b.key, { t, x: r.end.x, hops: [...cur.hops, hop] });
        break;
      }
    }
  }
  const got = best.get(goal.key);
  if (got) return { hops: got.hops, goal: { key: goal.key, x: gx }, partial: false };
  // Out of reach: the reached surface whose nearest point is nearest the goal.
  let near: { key: string; d: number; x: number } | null = null;
  for (const [key] of best) {
    const r = surface(world, key)!;
    const x = inset(p, r, gx);
    const d = Math.hypot(x - gx, r.t - goalR.t);
    if (!near || d < near.d) near = { key, d, x };
  }
  if (!near) return null;
  return { hops: best.get(near.key)!.hops, goal: { key: near.key, x: near.x }, partial: true };
}

/**
 * Plays a route live, closed loop: input() each fixed step. A hop that ends anywhere else, a surface gone, a goal
 * moved: it replans from where it stands (a few times; then it stops where it is).
 */
export class Driver {
  route: Route | null = null;
  private hop: HopDriver | null = null;
  private i = 0;
  private replans = 0;
  goal: Goal;
  private done: (reached: boolean) => void;
  /** Planning time per step (ms): the route is worked out a slice at a time while it already sets off. */
  private budget: number;
  private gen: Generator<void, Route | null> | null = null;
  constructor(goal: Goal, done: (reached: boolean) => void, budgetMs = Infinity) {
    this.goal = goal;
    this.done = done;
    this.budget = budgetMs;
  }

  /** What to press this step; null when it has arrived (or given up) - done() was called. */
  input(p: Pet, world: World): Input | null {
    if (!surface(world, this.goal.key)) return this.finish(false);
    if (!this.route) {
      if (!this.gen) {
        if (!p.ground) return { ...NO_INPUT };
        this.gen = planner(world, p, this.goal);
      }
      // A slice of the planning this step; meanwhile it already heads the goal's way along what it stands on.
      const until = this.budget === Infinity ? Infinity : now() + this.budget;
      let r = this.gen.next();
      while (!r.done && now() < until) r = this.gen.next();
      if (!r.done) {
        const g = p.ground && surface(world, p.ground);
        const w = g && p.ground !== FLOOR ? walkInput(p, inset(p, g, this.goal.x)) : g ? walkInput(p, clamp(this.goal.x, p.hw, world.w - p.hw)) : null;
        return w ?? { ...NO_INPUT };
      }
      this.gen = null;
      this.route = r.value;
      this.i = 0;
      this.hop = null;
      if (!this.route) return this.finish(false);
    }
    const r = this.route;
    if (this.i < r.hops.length) {
      if (!this.hop) {
        if (!p.ground) return { ...NO_INPUT };
        this.hop = new HopDriver(r.hops[this.i], p.ground);
      }
      const i = this.hop.input(p, world);
      if (i) return i;
      const ok = p.ground === r.hops[this.i].to;
      this.hop = null;
      if (ok) this.i++;
      else return this.replan(p);
      return { ...NO_INPUT };
    }
    // On the last surface: walk to the spot.
    if (p.ground !== r.goal.key) return p.ground ? this.replan(p) : { ...NO_INPUT };
    const g = surface(world, r.goal.key)!;
    const w = walkInput(p, inset(p, g, r.goal.key === this.goal.key ? this.goal.x : r.goal.x));
    if (w) return w;
    return this.finish(!r.partial);
  }

  private replan(p: Pet): Input | null {
    if (++this.replans > 5) return this.finish(false);
    this.route = null;
    this.hop = null;
    this.gen = null;
    return { ...NO_INPUT };
  }

  private finished = false;
  private finish(reached: boolean): null {
    if (!this.finished) {
      this.finished = true;
      this.done(reached);
    }
    return null;
  }
}
