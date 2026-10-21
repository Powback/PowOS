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
  /** One blink (a 160 ms compositor animation of the eyes' layer). */
  blink(): void;
  /** The "ears" glow once (a word heard while listening). */
  pulse(): void;
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
  const clip = useRef<SVGPathElement>(null);
  const hl = useRef<SVGPathElement>(null);
  const face = useRef<SVGGElement>(null);
  const feet = useRef<SVGGElement>(null);
  const eyes = useRef<HTMLSpanElement>(null);
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
      draw(ps);
      // The face rides the body's centre of mass (a squash takes it down with it); the eyes also look.
      const shift = `translate(${(mx - CX).toFixed(2)} ${(my - CY).toFixed(2)})`;
      face.current?.setAttribute("transform", shift);
      feet.current?.setAttribute("transform", shift);
      // Eyes: their own layer (an HTML box, composited) - viewBox units to its px.
      const k = (eyes.current?.offsetWidth ?? BODY) / BODY;
      if (eyes.current) eyes.current.style.transform = `translate(${((mx - CX + eye.x) * k).toFixed(2)}px, ${((my - CY + eye.y) * k).toFixed(2)}px)`;
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
        // A fast finger mustn't tear it: at most this much per move.
        vx = Math.max(-5, Math.min(5, vx));
        vy = Math.max(-5, Math.min(5, vy));
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
      blink() {
        eyes.current?.firstElementChild?.animate(
          [{ transform: "scaleY(1)" }, { transform: "scaleY(0.1)" }, { transform: "scaleY(1)" }],
          { duration: 160, easing: "ease-in-out" },
        );
      },
      pulse() {
        for (const e of svg.current?.querySelectorAll(".pet-ear") ?? [])
          e.animate([{ opacity: 0.35 }, { opacity: 1 }, { opacity: 0.35 }], { duration: 380, easing: "ease-out" });
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
    const draw = (pts: P[]) => {
      const d = pathOf(pts);
      shape.current?.setAttribute("d", d);
      clip.current?.setAttribute("d", d);
      hl.current?.setAttribute("d", d);
    };
    draw(ps);
    return () => {
      cancelAnimationFrame(raf);
      handle.current = null;
    };
  }, []);
  return (
    <span class="pet-art">
      <svg ref={svg} class="pet-svg" viewBox="0 0 52 52" aria-hidden="true">
        <defs>
          {/* The inner top highlight (theme.css --lift's light edge, on a round thing): the rim's stroke, light at the top, gone by the middle, inside the body only. */}
          <linearGradient id="pet-hl-grad" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" class="pet-hl-a" />
            <stop offset="0.42" class="pet-hl-b" />
          </linearGradient>
          <clipPath id="pet-clip">
            <path ref={clip} />
          </clipPath>
        </defs>
        {/* Its soft shadow on whatever it stands on. */}
        <ellipse class="pet-shadow" cx="26" cy="49.2" rx="15" ry="2.4" />
        {/* Feet under the body, riding its centre of mass with the face. */}
        <g ref={feet}>
          <ellipse class="pet-foot" cx="19" cy="46.5" rx="4" ry="2.2" />
          <ellipse class="pet-foot" cx="33" cy="46.5" rx="4" ry="2.2" />
        </g>
        {/* Listening: two small "ears" that glow with the voice (pet.tsx pulses them as words come). */}
        <circle class="pet-ear" cx="15" cy="14.5" r="2.2" />
        <circle class="pet-ear" cx="37" cy="14.5" r="2.2" />
        <path ref={shape} class="pet-shape" />
        <path ref={hl} class="pet-hl" clip-path="url(#pet-clip)" />
        <g ref={face} class="pet-face">
          <path class="pet-brows" d="M16.5 22.8l5.5-1.8M35.5 22.8l-5.5-1.8" />
          <path class="pet-mouth smile" d="M23.2 34q2.8 2.2 5.6 0" />
          <path class="pet-mouth flat" d="M23.5 35h5" />
          <path class="pet-mouth wavy" d="M22 35q1.7-1.6 3.4 0t3.4 0" />
          <ellipse class="pet-mouth open" cx="26" cy="35" rx="2.2" ry="1.9" />
          {/* Working: a tiny parcel it carries, softly lit. */}
          <g class="pet-parcel">
            <circle class="pet-parcel-glow" cx="38" cy="38" r="6" />
            <rect class="pet-parcel-box" x="34.5" y="34.8" width="7" height="6.2" rx="1.6" />
            <path class="pet-parcel-tie" d="M38 34.8v6.2M34.5 37.6h7" />
          </g>
        </g>
        <text class="pet-z" x="41" y="12">z</text>
      </svg>
      {/* The eyes on a layer of their own: they look (a transform) and blink (pet.tsx: one short animation) on the compositor. */}
      <span ref={eyes} class="pet-eyes-move">
        <span class="pet-eyes-blink">
          <svg class="pet-svg" viewBox="0 0 52 52" aria-hidden="true">
            <ellipse class="pet-eye open" cx="20" cy="27" rx="2.8" ry="3.4" />
            <ellipse class="pet-eye open" cx="32" cy="27" rx="2.8" ry="3.4" />
            <circle class="pet-glint" cx="21" cy="25.6" r="0.9" />
            <circle class="pet-glint" cx="33" cy="25.6" r="0.9" />
            <path class="pet-eye closed" d="M16.8 28q3.2 2.3 6.4 0M28.8 28q3.2 2.3 6.4 0" />
            <path class="pet-eye glad" d="M16.8 28.4q3.2-3.6 6.4 0M28.8 28.4q3.2-3.6 6.4 0" />
          </svg>
        </span>
      </span>
    </span>
  );
}
