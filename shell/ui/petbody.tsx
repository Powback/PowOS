/**
 * The pet's body (docs/PET.md v2, step a): a soft blob drawn from a ring of points on springs around its centre, two
 * eyes that follow the finger, a tiny pair of feet. Procedural - no sprite sheet, no smiley glyph; the theme's colours
 * (pet.css).
 *
 * Physics: each rim point is a mass on a spring to its rest place around the centre (and to its two neighbours, so the
 * rim keeps its shape), damped; a fixed 60 Hz step (verlet-ish, semi-implicit Euler). Things that move it: a drag (the
 * points lag the finger: inertia, then wobble), a squash (a landing, a tap: the rim pressed down and out, then it
 * springs back), a stretch (a jump's take-off).
 *
 * Frames only while something moves: one requestAnimationFrame loop, started by a kick, stopped once every point and
 * the eyes are still (< 0.05 px for 6 frames). At rest the page runs nothing for it - blinks and sleepy breathing are
 * finite CSS animations (pet.css). Hidden: no loop (rAF doesn't run, and a kick while hidden only marks it to settle).
 * Each frame writes two attributes (the path, the eyes' transform) straight to the DOM - no Preact render.
 */
import { useEffect, useRef } from "preact/hooks";

export const BODY = 52;
const N = 10;
const CX = 26;
const CY = 29;
/** Rest radius: a little wider than tall, a soft pear (heavier at the bottom). */
const RX = 19;
const RY = 17;
const K = 0.16; // spring to rest
const KN = 0.08; // spring to neighbours (keeps the rim smooth)
const DAMP = 0.82;
const EYE_MAX = 2.6; // how far the eyes move toward the finger (px)
const STILL = 0.05;

interface P {
  x: number;
  y: number;
  vx: number;
  vy: number;
  rx: number;
  ry: number;
}

/** What pet.tsx can do to the body. */
export interface BodyHandle {
  /** The whole body pushed (px/frame): it lags and wobbles back - a drag's motion, inverted. */
  push(vx: number, vy: number): void;
  /** Pressed down (0..1): a landing, a tap. */
  squash(amount: number): void;
  /** Pulled up (0..1): a take-off. */
  stretch(amount: number): void;
  /** Where the finger is, in page px (null: nowhere - the eyes go back to the middle). */
  look(x: number | null, y: number | null): void;
}

function ring(): P[] {
  return Array.from({ length: N }, (_, i) => {
    const a = (i / N) * Math.PI * 2 - Math.PI / 2;
    // A pear: the lower half a little wider.
    const k = Math.sin(a) > 0 ? 1.06 : 0.96;
    const rx = Math.cos(a) * RX * k;
    const ry = Math.sin(a) * RY;
    return { x: CX + rx, y: CY + ry, vx: 0, vy: 0, rx, ry };
  });
}

/** A smooth closed path through the points (Catmull-Rom as cubic Béziers). */
function pathOf(ps: P[]) {
  const n = ps.length;
  const f = (v: number) => v.toFixed(2);
  let d = `M${f(ps[0].x)} ${f(ps[0].y)}`;
  for (let i = 0; i < n; i++) {
    const p0 = ps[(i - 1 + n) % n];
    const p1 = ps[i];
    const p2 = ps[(i + 1) % n];
    const p3 = ps[(i + 2) % n];
    d += `C${f(p1.x + (p2.x - p0.x) / 6)} ${f(p1.y + (p2.y - p0.y) / 6)} ${f(p2.x - (p3.x - p1.x) / 6)} ${f(p2.y - (p3.y - p1.y) / 6)} ${f(p2.x)} ${f(p2.y)}`;
  }
  return d + "Z";
}

export function PetBody({ handle }: { handle: { current: BodyHandle | null } }) {
  const svg = useRef<SVGSVGElement>(null);
  const shape = useRef<SVGPathElement>(null);
  const eyes = useRef<SVGGElement>(null);
  useEffect(() => {
    const ps = ring();
    const eye = { x: 0, y: 0, tx: 0, ty: 0 };
    let raf = 0;
    let still = 0;
    const step = () => {
      let moved = 0;
      // Centre of mass: the eyes and feet ride on it.
      let mx = 0;
      let my = 0;
      for (const p of ps) {
        mx += p.x;
        my += p.y;
      }
      mx /= N;
      my /= N;
      for (let i = 0; i < N; i++) {
        const p = ps[i];
        const a = ps[(i - 1 + N) % N];
        const b = ps[(i + 1) % N];
        // To its rest place around the (fixed) centre, and toward the middle of its neighbours.
        let fx = (CX + p.rx - p.x) * K + ((a.x + b.x) / 2 - p.x) * KN;
        let fy = (CY + p.ry - p.y) * K + ((a.y + b.y) / 2 - p.y) * KN;
        p.vx = (p.vx + fx) * DAMP;
        p.vy = (p.vy + fy) * DAMP;
        p.x += p.vx;
        p.y += p.vy;
        moved = Math.max(moved, Math.abs(p.vx), Math.abs(p.vy));
      }
      const ex = eye.x + (eye.tx - eye.x) * 0.25;
      const ey = eye.y + (eye.ty - eye.y) * 0.25;
      moved = Math.max(moved, Math.abs(ex - eye.x), Math.abs(ey - eye.y));
      eye.x = ex;
      eye.y = ey;
      shape.current?.setAttribute("d", pathOf(ps));
      // The face rides the body's centre of mass (a squash takes the eyes down with it).
      eyes.current?.setAttribute("transform", `translate(${(mx - CX + eye.x).toFixed(2)} ${(my - CY + eye.y).toFixed(2)})`);
      still = moved < STILL ? still + 1 : 0;
      if (still >= 6 || document.hidden) {
        raf = 0;
        return;
      }
      raf = requestAnimationFrame(step);
    };
    const wake = () => {
      still = 0;
      if (!raf && !document.hidden) raf = requestAnimationFrame(step);
    };
    handle.current = {
      push(vx, vy) {
        // The rim lags the motion: points on the leading side pressed in, trailing side pulled out.
        for (const p of ps) {
          const along = (p.rx * vx + p.ry * vy) / (RX * Math.hypot(vx, vy) || 1);
          p.vx -= vx * (0.5 + 0.3 * along);
          p.vy -= vy * (0.5 + 0.3 * along);
        }
        wake();
      },
      squash(amount) {
        for (const p of ps) {
          p.vy += (p.ry < 0 ? 1 : -0.15) * 5 * amount * Math.abs(p.ry / RY);
          p.vx += (p.rx / RX) * 3.5 * amount;
        }
        wake();
      },
      stretch(amount) {
        for (const p of ps) {
          p.vy -= (p.ry < 0 ? 1 : 0) * 5 * amount * Math.abs(p.ry / RY);
          p.vx -= (p.rx / RX) * 2 * amount;
        }
        wake();
      },
      look(x, y) {
        const r = svg.current?.getBoundingClientRect();
        if (x == null || y == null || !r) {
          eye.tx = 0;
          eye.ty = 0;
        } else {
          const dx = x - (r.left + r.width / 2);
          const dy = y - (r.top + r.height * 0.45);
          const d = Math.hypot(dx, dy) || 1;
          // Close by: a little; far: the full reach - toward the finger, never out of the face.
          const reach = EYE_MAX * Math.min(1, d / 120);
          eye.tx = (dx / d) * reach;
          eye.ty = (dy / d) * reach * 0.8;
        }
        wake();
      },
    };
    shape.current?.setAttribute("d", pathOf(ps));
    return () => {
      cancelAnimationFrame(raf);
      handle.current = null;
    };
  }, []);
  return (
    <svg ref={svg} class="pet-svg" viewBox="0 0 52 52" width={BODY} height={BODY} aria-hidden="true">
      {/* Feet: two small rounded nubs under it (still: the body squashes over them). */}
      <ellipse class="pet-foot" cx="19" cy="46.5" rx="4" ry="2.2" />
      <ellipse class="pet-foot" cx="33" cy="46.5" rx="4" ry="2.2" />
      <path ref={shape} class="pet-shape" />
      <g ref={eyes} class="pet-face">
        <g class="pet-eyes">
          <ellipse class="pet-eye open" cx="20" cy="27" rx="2.8" ry="3.4" />
          <ellipse class="pet-eye open" cx="32" cy="27" rx="2.8" ry="3.4" />
          <circle class="pet-glint" cx="21" cy="25.6" r="0.9" />
          <circle class="pet-glint" cx="33" cy="25.6" r="0.9" />
          <path class="pet-eye closed" d="M16.8 28q3.2 2.3 6.4 0M28.8 28q3.2 2.3 6.4 0" />
          <path class="pet-eye glad" d="M16.8 28.4q3.2-3.6 6.4 0M28.8 28.4q3.2-3.6 6.4 0" />
        </g>
        <path class="pet-brows" d="M16.5 22.8l5.5-1.8M35.5 22.8l-5.5-1.8" />
        <path class="pet-mouth smile" d="M23.2 34q2.8 2.2 5.6 0" />
        <path class="pet-mouth flat" d="M23.5 35h5" />
        <path class="pet-mouth wavy" d="M22 35q1.7-1.6 3.4 0t3.4 0" />
        <ellipse class="pet-mouth open" cx="26" cy="35" rx="2.2" ry="1.9" />
      </g>
      <text class="pet-z" x="41" y="12">z</text>
    </svg>
  );
}
