/**
 * The pet's movement (docs/PET.md v2, step e): a fixed-timestep platformer controller, Meat Boy style - gravity,
 * acceleration and friction, a jump whose height follows how long it's held, coyote time, a jump buffer, wall slide and
 * wall jump - for a 64-72 px creature: crisp, not floaty.
 *
 * Pure: no DOM, no clock. The world is plain rects (petmove.ts measures home's: the tiles on the page showing, the
 * search pill; the screen's edges are its walls, floor and ceiling). Its only way to move is step(): velocity
 * integrated per axis (X resolved, then Y) at a fixed DT. Nothing outside sets its position - a plan (petai.ts) only
 * presses buttons - so where it is is always continuous: at most MAX_STEP px a step (the tests assert it).
 *
 * Collision:
 *   - Tiles and the pill are one-way floors: it lands on a top it crosses on the way down and jumps up through them
 *     from below (home's tiles sit 8 px apart: there's no room under or between them, so solid tiles would wall it in).
 *     Their sides are walls at its feet's height for something coming from outside - it slides down them and kicks
 *     off them.
 *   - Swept, not sampled: a floor is hit when the feet cross its top between two steps, so no speed tunnels a thin rect.
 *   - The screen's sides are walls, its foot a floor, the status bar's line a ceiling.
 *   - A rect that moves takes it along when it stands on it (at most CARRY px a step: a platform moving under it
 *     glides it, never snaps it); one that jumps further than LOST in one go, or goes, leaves it in the air: it falls.
 *   - Outside the world (a resize shrank it): it is moved back in at CLAMP px a step, never put there.
 *
 * Squash and stretch come from its real velocity and its landings (a spring on one number, clamped to +-25%), never
 * from where it should be.
 */

export const DT = 1 / 120;

export interface Rect {
  key: string;
  l: number;
  t: number;
  r: number;
  b: number;
}

export interface World {
  /** The screen: walls at 0 and w, the floor at h, the ceiling at top (under the status bar). */
  w: number;
  h: number;
  top: number;
  rects: Rect[];
}

export interface Input {
  left: boolean;
  right: boolean;
  jump: boolean;
  /** Down through the one-way floor it stands on (not the screen's foot). */
  down?: boolean;
}

export const NO_INPUT: Input = { left: false, right: false, jump: false };

/** The floor's key (the screen's foot): it stands there when nothing else caught it. */
export const FLOOR = "floor";

export interface Pet {
  /** Its feet: the middle of the bottom of its box (CSS px). */
  x: number;
  y: number;
  vx: number;
  vy: number;
  /** What it stands on (a rect's key, FLOOR), or null in the air. */
  ground: string | null;
  /** That rect's left/top as last followed (a moving platform's carry still owed is the difference). */
  gl: number;
  gt: number;
  /** The floor it dropped through (down): not landed on again until it's below it. */
  through: string | null;
  /** -1/1: a wall touching its left/right side, in the air; 0 none. */
  wall: number;
  /** Timers (s): coyote, jump buffer, wall coyote, wall-jump steering lock. */
  coyote: number;
  buffer: number;
  wallCoyote: number;
  wallSide: number;
  lock: number;
  /** The jump is still held from its take-off (released early: the jump is cut once). */
  rising: boolean;
  jumpWas: boolean;
  /** Squash/stretch: s > 0 taller, s < 0 squashed; sv its rate. */
  s: number;
  sv: number;
  /** The last landing's speed (px/s) and how many steps ago, for whoever listens. */
  landed: number;
  /** Its box (CSS px), from its size. */
  hw: number;
  hh: number;
  /** Lengths and speeds scale with its size (64 px is 1). */
  k: number;
}

/** Tuning for a 64 px creature (k = 1); px and seconds. */
export const T = {
  runMax: 300,
  runAcc: 3600,
  turnAcc: 6400,
  friction: 4400,
  airAcc: 2600,
  airDrag: 260,
  gravity: 3400,
  fallMult: 1.6,
  jumpH: 170,
  jumpCut: 0.45,
  maxFall: 1500,
  coyote: 0.09,
  buffer: 0.11,
  wallSlide: 160,
  wallCoyote: 0.07,
  wjVx: 230,
  wjVy: 900,
  wjLock: 0.07,
};

/** Per-step limits: how far a moving platform carries it, how fast it's moved back into the world, the jump that's a loss. */
export const CARRY = 6;
export const CLAMP = 4;
export const LOST = 180;
/** The most it can move in one step, anything included (the tests' no-teleport bound). */
export const MAX_STEP = Math.hypot(T.maxFall * DT, (T.runMax + T.wjVx) * DT) * 1.25 + CARRY + CLAMP;
const SQ_MAX = 0.25;

export const jumpV = (k: number) => Math.sqrt(2 * T.gravity * k * T.jumpH * k);

export function makePet(x: number, y: number, size: number): Pet {
  return {
    x,
    y,
    vx: 0,
    vy: 0,
    ground: null,
    gl: 0,
    gt: 0,
    through: null,
    wall: 0,
    coyote: 0,
    buffer: 0,
    wallCoyote: 0,
    wallSide: 0,
    lock: 0,
    rising: false,
    jumpWas: false,
    s: 0,
    sv: 0,
    landed: 0,
    hw: size * 0.62,
    hh: size * 0.78,
    k: size / 64,
  };
}

/** Stood on [key] at its top (a spawn: the first place it appears, before any step). */
export function standOn(p: Pet, r: Rect | null, world: World) {
  p.vx = p.vy = 0;
  if (r) {
    p.y = r.t;
    p.ground = r.key;
    p.gl = r.l;
    p.gt = r.t;
  } else {
    p.y = world.h;
    p.ground = FLOOR;
    p.gl = 0;
    p.gt = world.h;
  }
}

const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));
const toward = (v: number, to: number, d: number) => (v < to ? Math.min(to, v + d) : Math.max(to, v - d));

/** The rect under its feet now (top within [eps] of the feet, the feet's span over it), or null. */
function under(p: Pet, world: World, eps = 1.5): Rect | null {
  const f = p.hw * 0.35;
  let best: Rect | null = null;
  for (const r of world.rects) {
    if (p.x + f > r.l && p.x - f < r.r && Math.abs(r.t - p.y) <= eps && (!best || r.t < best.t)) best = r;
  }
  return best;
}

/** One fixed step: [input] held for DT. Returns how far it moved (px). */
export function step(p: Pet, input: Input, world: World): number {
  const k = p.k;
  const x0 = p.x;
  const y0 = p.y;
  const dt = DT;
  const pressed = input.jump && !p.jumpWas;
  p.jumpWas = input.jump;
  p.coyote = Math.max(0, p.coyote - dt);
  p.buffer = pressed ? T.buffer : Math.max(0, p.buffer - dt);
  p.wallCoyote = Math.max(0, p.wallCoyote - dt);
  p.lock = Math.max(0, p.lock - dt);
  p.landed = 0;

  // 1. Its ground: followed if it moved (a capped glide), lost if it went or jumped away.
  if (p.ground && p.ground !== FLOOR) {
    const r = world.rects.find((q) => q.key === p.ground);
    if (!r || Math.abs(r.l - p.gl) > LOST || Math.abs(r.t - p.gt) > LOST) {
      p.ground = null;
      p.coyote = T.coyote;
    } else {
      const dx = clamp(r.l - p.gl, -CARRY, CARRY);
      const dy = clamp(r.t - p.gt, -CARRY, CARRY);
      p.gl += dx;
      p.gt += dy;
      p.x += dx;
      p.y = toward(p.y, p.gt, CARRY);
    }
  } else if (p.ground === FLOOR) {
    p.y = toward(p.y, world.h, CARRY);
    p.gt = p.y;
  }

  // 2. Back into the world by moving (a resize shrank it, the floor rose): CLAMP px a step at most.
  const half = p.hw / 2;
  if (p.x - half < 0) p.x = Math.min(half, p.x + CLAMP);
  else if (p.x + half > world.w) p.x = Math.max(world.w - half, p.x - CLAMP);
  if (p.y > world.h + 0.01 && p.ground !== FLOOR) {
    p.y = Math.max(world.h, p.y - CLAMP);
    p.vy = Math.min(p.vy, 0);
  }

  // 3. Running: acceleration, turning, friction; a wall jump's short lock keeps it from steering straight back.
  let dir = (input.right ? 1 : 0) - (input.left ? 1 : 0);
  if (p.lock > 0 && dir === p.wallSide) dir = 0;
  const grounded = p.ground != null;
  const max = T.runMax * k;
  if (dir !== 0) {
    const acc = (grounded ? (Math.sign(p.vx) === -dir ? T.turnAcc : T.runAcc) : T.airAcc) * k;
    p.vx = Math.abs(p.vx) > max && Math.sign(p.vx) === dir ? toward(p.vx, dir * max, T.friction * k * dt) : toward(p.vx, dir * max, acc * dt);
  } else p.vx = toward(p.vx, 0, (grounded ? T.friction : T.airDrag) * k * dt);

  // Down through the floor it stands on.
  if (input.down && p.ground && p.ground !== FLOOR && !pressed) {
    p.through = p.ground;
    p.ground = null;
    p.coyote = 0;
  }

  // 4. Jumping: from the ground or just after leaving it (coyote), buffered a little before landing; off a wall.
  if (p.buffer > 0 && (grounded || p.coyote > 0)) {
    p.vy = -jumpV(k);
    p.ground = null;
    p.coyote = 0;
    p.buffer = 0;
    p.rising = true;
    p.sv += 2.6;
  } else if (p.buffer > 0 && !grounded && (p.wall !== 0 || p.wallCoyote > 0)) {
    // Held into the wall: a climbing jump (up, barely off it); else a kick away from it.
    const side = p.wall || p.wallSide;
    const climb = dir === side;
    p.vx = -side * T.wjVx * k * (climb ? 0.3 : 1);
    p.vy = -T.wjVy * k;
    p.wallSide = side;
    p.lock = climb ? 0 : T.wjLock;
    p.buffer = 0;
    p.wallCoyote = 0;
    p.rising = true;
    p.sv += 2.2;
  }
  // Let go early: the rest of the climb is cut (variable height).
  if (p.rising && (!input.jump || p.vy >= 0)) {
    if (p.vy < 0) p.vy *= T.jumpCut;
    p.rising = false;
  }

  // 5. Gravity: lighter while a held jump rises, heavier falling; a wall pressed into slows the fall.
  if (!p.ground) {
    const g = T.gravity * k * (p.rising ? 1 : T.fallMult);
    p.vy = Math.min(T.maxFall * k, p.vy + g * dt);
    if (p.wall !== 0 && dir === p.wall && p.vy > T.wallSlide * k) p.vy = toward(p.vy, T.wallSlide * k, T.gravity * k * 3 * dt);
  }

  // 6. X, then Y.
  moveX(p, world);
  moveY(p, world);

  // 7. Walked off its ground: in the air, coyote time to still jump.
  if (p.ground && p.ground !== FLOOR) {
    const r = world.rects.find((q) => q.key === p.ground);
    const f = p.hw * 0.35;
    if (!r || p.x + f <= r.l || p.x - f >= r.r) {
      const next = under(p, world);
      if (next) {
        p.ground = next.key;
        p.gl = next.l;
        p.gt = next.t;
      } else {
        p.ground = null;
        p.coyote = T.coyote;
      }
    }
  }

  // 8. Touching a wall (in the air): for sliding and kicking off it; a moment's grace after leaving it.
  const was = p.wall;
  p.wall = p.ground ? 0 : wallAt(p, world);
  if (was !== 0 && p.wall === 0 && !p.ground) {
    p.wallCoyote = T.wallCoyote;
    p.wallSide = was;
  }
  if (p.wall !== 0) p.wallSide = p.wall;

  // 9. Squash and stretch: a spring toward its speed's stretch (in the air), kicked by landings and take-offs.
  const target = p.ground ? 0 : Math.min(0.14, (Math.abs(p.vy) / (T.maxFall * k)) * 0.16);
  p.sv += ((target - p.s) * 420 - p.sv * 18) * dt;
  p.s += p.sv * dt;
  if (Math.abs(p.s) >= SQ_MAX) {
    p.s = clamp(p.s, -SQ_MAX, SQ_MAX);
    p.sv = 0;
  }
  return Math.hypot(p.x - x0, p.y - y0);
}

/**
 * A rect's side is a wall at its feet's height: from just under its top to a little above its bottom. Only the feet:
 * it's drawn over the UI, so its head may pass in front of a tile above (home's tiles sit 8 px apart - a top with a
 * tile just over it is still a floor it can get onto), and grazing a bottom corner slides it past.
 */
const sideAt = (p: Pet, r: Rect) => p.y > r.t + 2 && p.y < r.b - 10 * p.k;

function moveX(p: Pet, world: World) {
  const half = p.hw / 2;
  const nx = p.x + p.vx * DT;
  let x = nx;
  // Rect sides: a wall for a box that was beside it and runs into it, with its body at the wall's height.
  for (const r of world.rects) {
    if (!sideAt(p, r)) continue;
    if (p.x + half <= r.l + 0.01 && x + half > r.l) {
      x = r.l - half;
      p.vx = Math.min(0, p.vx);
    } else if (p.x - half >= r.r - 0.01 && x - half < r.r) {
      x = r.r + half;
      p.vx = Math.max(0, p.vx);
    }
  }
  // The screen's sides (only crossing them from inside: outside, step 2 moves it back).
  if (p.x - half >= 0 && x - half < 0) {
    x = half;
    p.vx = Math.max(0, p.vx);
  } else if (p.x + half <= world.w && x + half > world.w) {
    x = world.w - half;
    p.vx = Math.min(0, p.vx);
  }
  p.x = x;
}

function moveY(p: Pet, world: World) {
  if (p.ground) return;
  const y0 = p.y;
  let y = p.y + p.vy * DT;
  if (p.vy > 0) {
    // Down: the first top its feet crossed this step, under the feet's span; else the screen's foot.
    const f = p.hw * 0.35;
    let hit: Rect | null = null;
    for (const r of world.rects) {
      if (r.key !== p.through && p.x + f > r.l && p.x - f < r.r && y0 <= r.t + 0.01 && y >= r.t && (!hit || r.t < hit.t)) hit = r;
    }
    if (hit) return land(p, hit.key, hit.t, hit.l);
    if (y0 <= world.h && y >= world.h) return land(p, FLOOR, world.h, 0);
  } else if (y - p.hh < world.top && y0 - p.hh >= world.top - 0.01) {
    // Up: the status bar's line is a ceiling (one-way tiles never are).
    y = world.top + p.hh;
    p.vy = 0;
    p.rising = false;
  }
  p.y = y;
  if (p.through) {
    const r = world.rects.find((q) => q.key === p.through);
    if (!r || p.y > r.t + 4) p.through = null;
  }
}

function land(p: Pet, key: string, top: number, left: number) {
  p.landed = p.vy;
  // The squash: how hard it came down (a hop's landing about half the clamp, a long fall the whole of it).
  p.sv -= Math.min(1, p.vy / (T.maxFall * p.k)) * 7 + 1;
  p.y = top;
  p.vy = 0;
  p.ground = key;
  p.gl = left;
  p.gt = top;
  p.rising = false;
  p.wall = 0;
  p.through = null;
}

function wallAt(p: Pet, world: World) {
  const half = p.hw / 2;
  if (Math.abs(p.x - half) < 0.75) return -1;
  if (Math.abs(p.x + half - world.w) < 0.75) return 1;
  for (const r of world.rects) {
    if (!sideAt(p, r)) continue;
    if (Math.abs(p.x + half - r.l) < 0.75) return 1;
    if (Math.abs(p.x - half - r.r) < 0.75) return -1;
  }
  return 0;
}

/** Its scale for drawing: (sx, sy), from the squash spring, each within +-25%. */
export function scaleOf(p: Pet) {
  const s = clamp(p.s, -SQ_MAX, SQ_MAX);
  return { sx: clamp(1 - s * 0.9, 1 - SQ_MAX, 1 + SQ_MAX), sy: 1 + s };
}

/** Nothing left to move: on the ground, still, the spring settled, no carry owed. */
export function atRest(p: Pet, world: World) {
  if (!p.ground || Math.abs(p.vx) > 0.5 || Math.abs(p.s) > 0.004 || Math.abs(p.sv) > 0.03) return false;
  if (p.ground === FLOOR) return Math.abs(p.y - world.h) < 0.01;
  const r = world.rects.find((q) => q.key === p.ground);
  return !!r && r.l === p.gl && r.t === p.gt && Math.abs(p.y - r.t) < 0.01;
}
