/**
 * The pet's movement on the page (docs/PET.md v2, step e): petphys.ts's controller on home's live rects, drawn on the
 * pet's element. ONE source of where it is (the simulation) and ONE transform: translate + its squash/stretch.
 *
 * Frames only while something moves: a requestAnimationFrame loop that steps the simulation at its fixed DT (the
 * frame's time cut into steps, the remainder carried) and draws in between two steps (interpolated). It stops once
 * the pet is at rest - on the ground, still, the spring settled, no route to play, no finger on it - so an idle page
 * runs nothing. A layout change (a page settled, tiles moved, a resize) wakes it: the rects are measured again each
 * frame while it runs, and whatever moved under it moves it (or drops it) the way petphys.ts does - never a jump.
 */
import { DT, FLOOR, NO_INPUT, atRest, makePet, scaleOf, standOn, step, type Input, type Pet, type Rect, type World } from "./petphys.ts";
import { Driver, offFloor, type Goal } from "./petai.ts";
import { edges } from "./petperch.ts";

/** How far its feet sit into an edge, as a share of its size (petperch.ts places it the same way). */
const SINK = 0.06;
/** A finger drags it at most this far a step (it lags a fast finger a little, never jumps to it). */
const HOLD_STEP = 30;
/** A throw's speed is capped (px/s). */
const THROW = 1800;

/** Home's world now: the tiles on the page showing and the search pill (petperch.ts edges(), not text lines). */
export function measure(): World {
  const inset = parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--inset-top")) || 24;
  const rects: Rect[] = [];
  for (const e of edges(false)) {
    if (e.owner || e.key.startsWith("text:")) continue;
    rects.push({ key: e.key, l: e.left, t: e.top, r: e.right, b: e.bottom ?? e.top + 44 });
  }
  return { w: innerWidth, h: innerHeight, top: inset, rects };
}

export interface MoverEvents {
  /** It came to rest: on [key] (a rect, or FLOOR) at [fx] along it (null: nowhere). */
  rest(at: { key: string; fx: number } | null): void;
  /** It touched down (speed px/s) or left the ground. */
  ground(on: boolean): void;
}

export class Mover {
  private el: HTMLElement;
  private size: number;
  private ev: MoverEvents;
  private p: Pet;
  private prev = { x: 0, y: 0, s: 0 };
  private world: World;
  private raf = 0;
  private last = 0;
  private acc = 0;
  private driver: Driver | null = null;
  private hold: { x: number; y: number; vx: number; vy: number } | null = null;
  private wasGround = false;
  private calm = 0;

  constructor(el: HTMLElement, size: number, ev: MoverEvents) {
    this.el = el;
    this.size = size;
    this.ev = ev;
    this.world = measure();
    this.p = makePet(innerWidth / 2, innerHeight, size);
    // Its squash and stretch pivot on its feet.
    el.style.transformOrigin = `50% ${(1 - SINK) * 100}%`;
  }

  /** Its size changed (the screen folded/unfolded): the same feet, a new box. */
  resize(size: number) {
    if (size === this.size) return;
    const q = makePet(this.p.x, this.p.y, size);
    this.p.hw = q.hw;
    this.p.hh = q.hh;
    this.p.k = q.k;
    this.size = size;
    this.wake();
  }

  /** Where it first appears (before any step: its first frame, not a move): on [key] at [fx], else it falls from (x, y). */
  spawn(key: string | null, fx: number, x: number, y: number) {
    this.world = measure();
    const r = key ? this.world.rects.find((q) => q.key === key) : null;
    if (r) {
      this.p.x = r.l + Math.min(1, Math.max(0, fx)) * (r.r - r.l);
      standOn(this.p, r, this.world);
    } else if (key === FLOOR) {
      this.p.x = fx * this.world.w;
      standOn(this.p, null, this.world);
    } else {
      this.p.x = x;
      this.p.y = y;
    }
    this.prev = { x: this.p.x, y: this.p.y, s: 0 };
    this.wasGround = !!this.p.ground;
    this.draw(1);
    this.wake();
  }

  /** Its element's top-left now (what the bubble is placed by). */
  pos() {
    return { left: this.p.x - this.size / 2, top: this.p.y - this.size * (1 - SINK) };
  }

  /** On a rect's top (its key), or null. */
  standing() {
    return this.p.ground && this.p.ground !== FLOOR ? this.p.ground : null;
  }

  /** Go to [goal] (a surface's key and an x on it) by its own moves; [then] when it's there (or as near as it gets). */
  goTo(goal: Goal, then?: (reached: boolean) => void) {
    // 3 ms of planning a step at most: it sets off at once, the route follows within a few frames.
    this.driver = new Driver(goal, (ok) => {
      this.driver = null;
      then?.(ok);
    }, 3);
    this.wake();
  }

  /** A finger took it: it follows the finger from here (by its feet). */
  grab() {
    this.driver = null;
    this.hold = { x: this.p.x, y: this.p.y, vx: 0, vy: 0 };
    this.wake();
    return { x: this.p.x, y: this.p.y };
  }

  /** Where the finger wants its feet. */
  drag(x: number, y: number) {
    if (this.hold) {
      this.hold.x = x;
      this.hold.y = y;
    }
  }

  /** Let go: thrown with the finger's speed (capped), it falls and lands where physics takes it. */
  release() {
    const h = this.hold;
    this.hold = null;
    if (!h) return;
    const sp = Math.hypot(h.vx, h.vy);
    const k = sp > THROW ? THROW / sp : 1;
    this.p.vx = h.vx * k;
    this.p.vy = h.vy * k;
    this.wake();
  }

  /** Something may have moved under it (a layout change): measured again, stepped until it's at rest. */
  wake() {
    this.calm = 0;
    this.floorTried = false;
    if (this.raf || document.hidden || this.paused) return;
    this.last = 0;
    this.raf = requestAnimationFrame(this.frame);
  }

  stop(keepRoute = false) {
    cancelAnimationFrame(this.raf);
    this.raf = 0;
    if (!keepRoute) this.driver = null;
  }

  /**
   * Hidden (the drawer, a panel, the shade over home): it holds still where it is - nothing measured or stepped, so
   * home's tiles going away under a panel don't drop it while nobody sees it; shown again, it carries on from there.
   */
  pause(on: boolean) {
    if (on === this.paused) return;
    this.paused = on;
    if (on) this.stop(true);
    else this.wake();
  }
  private paused = false;
  private floorTried = false;

  /** On its way somewhere (a route playing). */
  busy() {
    return !!this.driver || !!this.hold;
  }

  private frame = (now: number) => {
    this.raf = 0;
    if (document.hidden || this.paused) return;
    // The frame's time in fixed steps. A long frame (the page busy elsewhere) is slowed down, never caught up: at
    // most 2 steps a frame, the rest of the time dropped - so it moves at most two steps' worth between two frames.
    const dt = this.last ? Math.min(2 * DT, (now - this.last) / 1000) : DT;
    this.last = now;
    this.acc += dt;
    this.world = measure();
    while (this.acc >= DT) {
      this.acc -= DT;
      this.prev = { x: this.p.x, y: this.p.y, s: this.p.s };
      this.tick();
    }
    this.draw(this.acc / DT);
    // On the screen's foot (a fall, a throw, a page whose tiles went): it doesn't stay - straight off it to the
    // nearest surface, by its own moves. Once per landing there (an unreachable surface isn't retried until the
    // layout changes).
    if (this.p.ground === FLOOR && !this.driver && !this.hold && !this.floorTried) {
      this.floorTried = true;
      const g = offFloor(this.world, this.p);
      if (g) this.goTo(g);
    } else if (this.p.ground && this.p.ground !== FLOOR) this.floorTried = false;
    const g = !!this.p.ground;
    if (g !== this.wasGround) {
      this.wasGround = g;
      this.ev.ground(g);
    }
    // At rest a few frames in a row: the loop stops (an idle page draws nothing).
    const resting = !this.hold && !this.driver && atRest(this.p, this.world);
    this.calm = resting ? this.calm + 1 : 0;
    if (this.calm >= 3) {
      this.acc = 0;
      this.prev = { x: this.p.x, y: this.p.y, s: this.p.s };
      this.draw(1);
      this.ev.rest(this.perch());
      return;
    }
    this.raf = requestAnimationFrame(this.frame);
  };

  private tick() {
    const p = this.p;
    const h = this.hold;
    if (h) {
      // Held: its feet go toward the finger, a capped step at a time (velocity kept, for the throw).
      const dx = h.x - p.x;
      const dy = h.y - p.y;
      const d = Math.hypot(dx, dy);
      const k = d > HOLD_STEP ? HOLD_STEP / d : 1;
      const mx = dx * k;
      const my = dy * k;
      p.x += mx;
      p.y += my;
      h.vx = h.vx * 0.6 + (mx / DT) * 0.4;
      h.vy = h.vy * 0.6 + (my / DT) * 0.4;
      p.vx = p.vy = 0;
      p.ground = null;
      p.s += (0 - p.s) * 0.2;
      p.sv = 0;
      return;
    }
    const input: Input = this.driver?.input(p, this.world) ?? NO_INPUT;
    step(p, input, this.world);
  }

  private draw(a: number) {
    const s = this.size;
    const x = this.prev.x + (this.p.x - this.prev.x) * a;
    const y = this.prev.y + (this.p.y - this.prev.y) * a;
    const { sx, sy } = scaleOf({ ...this.p, s: this.prev.s + (this.p.s - this.prev.s) * a });
    this.el.style.transform = `translate3d(${(x - s / 2).toFixed(2)}px, ${(y - s * (1 - SINK)).toFixed(2)}px, 0) scale(${sx.toFixed(3)}, ${sy.toFixed(3)})`;
  }

  private perch() {
    const p = this.p;
    if (!p.ground) return null;
    if (p.ground === FLOOR) return { key: FLOOR, fx: p.x / Math.max(1, this.world.w) };
    const r = this.world.rects.find((q) => q.key === p.ground);
    return r ? { key: r.key, fx: (p.x - r.l) / Math.max(1, r.r - r.l) } : null;
  }
}
