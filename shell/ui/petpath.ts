/**
 * The pet's platformer moves (docs/PET.md v2, step e): how it gets from its perch to another edge on home - walking
 * along an edge, jumping across a gap or up a little, and wall-jumping up a tile's side when the edge above is too
 * high for one jump. A plan is a list of moves over the edges (petperch.ts: tile tops and the search pill), searched
 * cheapest first (Dijkstra by time); pet.tsx plays it as ONE compositor animation (keyframes along the path), so the
 * page does no work per frame.
 */
import type { Edge } from "./petperch.ts";

/** How far one jump reaches, CSS px: across, and up. */
export const JUMP_X = 160;
export const JUMP_UP = 118;
const WALK_PX_S = 260;
const JUMP_S = 0.48;
const WALL_S = 0.3;

export type Move =
  | { kind: "walk"; key: string; x: number }
  | { kind: "jump"; key: string; x0: number; x: number }
  | { kind: "wall"; key: string; x0: number; wx: number; wy: number; x: number };

interface Node {
  key: string;
  x: number;
}

/** The point on [a] nearest to [b] (where it'd take off toward it), inset a little from the end. */
const toward = (a: Edge, b: Edge) => {
  const inset = Math.min(18, (a.right - a.left) / 3);
  if (b.left > a.right) return a.right - inset;
  if (b.right < a.left) return a.left + inset;
  return Math.min(a.right - inset, Math.max(a.left + inset, (Math.max(a.left, b.left) + Math.min(a.right, b.right)) / 2));
};

/** The ways from [a] to [b]: one jump, a wall-jump up [b]'s side, or none. Times in seconds. */
function hop(a: Edge, b: Edge): { move: Exclude<Move, { kind: "walk" }>; t: number }[] {
  const gap = Math.max(0, b.left - a.right, a.left - b.right);
  const rise = a.top - b.top; // > 0: b is higher
  const x0 = toward(a, b);
  const x = toward(b, a);
  const out: { move: Exclude<Move, { kind: "walk" }>; t: number }[] = [];
  if (gap <= JUMP_X && rise <= JUMP_UP) out.push({ move: { kind: "jump", key: b.key, x0, x }, t: JUMP_S + Math.abs(rise) / 900 });
  else if (gap <= JUMP_X && rise <= JUMP_UP * 2.3 && b.bottom != null && b.bottom >= a.top - JUMP_UP) {
    // Up one of [b]'s sides: it jumps to the wall (as high as one jump goes), kicks off it and up onto the top. The
    // side it clings to needs room outside it on the screen (a tile at the screen's edge: only its inner side).
    const room = (wx: number, left: boolean) => (left ? wx - 40 >= 0 : wx + 40 <= innerWidth);
    const nearLeft = Math.abs(x0 - b.left) <= Math.abs(x0 - b.right);
    const sides = (nearLeft ? [true, false] : [false, true]).filter((left) => room(left ? b.left : b.right, left));
    if (!sides.length) return out;
    const fromLeft = sides[0];
    const wx = fromLeft ? b.left : b.right;
    const wy = Math.max(b.top + 8, a.top - JUMP_UP * 0.9);
    out.push({ move: { kind: "wall", key: b.key, x0, wx, wy, x: fromLeft ? b.left + 24 : b.right - 24 }, t: JUMP_S + WALL_S * 2 });
  }
  return out;
}

/**
 * The quickest way from [from] (an edge's key and an x on it) to [to] (key, x), over [edges]: the moves in order
 * (walks along an edge to the take-off point included), or null when it can't get there.
 */
export function plan(edges: Edge[], from: Node, to: Node, partial = false): Move[] | null {
  const by = new Map(edges.map((e) => [e.key, e]));
  if (!by.has(from.key) || !by.has(to.key)) return null;
  // Dijkstra over edges (few: a page's tiles and the pill); a node's x is where it landed on that edge.
  const best = new Map<string, { t: number; x: number; moves: Move[] }>([[from.key, { t: 0, x: from.x, moves: [] }]]);
  const open = [from.key];
  while (open.length) {
    open.sort((p, q) => best.get(p)!.t - best.get(q)!.t);
    const k = open.shift()!;
    const cur = best.get(k)!;
    if (k === to.key) {
      const walk = Math.abs(to.x - cur.x) / WALK_PX_S;
      return walk > 0.02 ? [...cur.moves, { kind: "walk", key: k, x: to.x }] : cur.moves;
    }
    const a = by.get(k)!;
    for (const b of edges) {
      if (b.key === k) continue;
      for (const { move, t } of hop(a, b)) {
        const x0 = move.x0;
        const walk = Math.abs(x0 - cur.x) / WALK_PX_S;
        const total = cur.t + walk + t;
        const seen = best.get(b.key);
        if (seen && seen.t <= total) continue;
        const moves: Move[] = [...cur.moves];
        if (walk > 0.02) moves.push({ kind: "walk", key: k, x: x0 });
        moves.push(move);
        best.set(b.key, { t: total, x: move.x, moves });
        if (!open.includes(b.key)) open.push(b.key);
      }
    }
  }
  if (!partial) return null;
  // Out of reach: as close as it can get - the reached edge whose nearest point is nearest the target.
  const t = by.get(to.key)!;
  let near: { k: string; d: number; x: number } | null = null;
  for (const [k, v] of best) {
    const e = by.get(k)!;
    const x = Math.min(e.right - 12, Math.max(e.left + 12, to.x));
    const d = Math.hypot(x - to.x, e.top - t.top);
    if (!near || d < near.d) near = { k, d, x };
  }
  if (!near || near.k === from.key) return null;
  const got = best.get(near.k)!;
  return Math.abs(near.x - got.x) > 6 ? [...got.moves, { kind: "walk", key: near.k, x: near.x }] : got.moves;
}

/** A plan as keyframes for the pet's element: its top-left offsets from where it starts, and each frame's offset. */
export function keyframes(edges: Edge[], start: { left: number; top: number }, fromKey: string, fromX: number, moves: Move[], size: number) {
  const by = new Map(edges.map((e) => [e.key, e]));
  const sink = size * 0.94;
  // Where its feet go -> where its top-left is.
  const at = (x: number, top: number) => ({ dx: x - size / 2 - start.left, dy: top - sink - start.top });
  type F = { dx: number; dy: number; t: number; sx?: number; sy?: number };
  const frames: F[] = [{ ...at(fromX, by.get(fromKey)!.top), t: 0 }];
  let t = 0;
  let x = fromX;
  let top = by.get(fromKey)!.top;
  for (const m of moves) {
    const e = by.get(m.key)!;
    if (m.kind === "walk") {
      const d = Math.abs(m.x - x) / WALK_PX_S;
      // A little bob as it goes (one up-down per ~60 px).
      const steps = Math.max(1, Math.round(Math.abs(m.x - x) / 60));
      for (let i = 1; i <= steps; i++) {
        const xi = x + ((m.x - x) * i) / steps;
        frames.push({ ...at(xi - (m.x - x) / steps / 2, top), dy: at(0, top).dy - 3, t: t + (d * (i - 0.5)) / steps });
        frames.push({ ...at(xi, top), t: t + (d * i) / steps });
      }
      t += d;
      x = m.x;
    } else if (m.kind === "jump") {
      const peak = Math.min(top, e.top) - 34;
      frames.push({ ...at(x, top), t: t + 0.06, sx: 1.08, sy: 0.9 });
      frames.push({ ...at((x + m.x) / 2, peak), t: t + JUMP_S / 2, sx: 0.95, sy: 1.06 });
      frames.push({ ...at(m.x, e.top), t: t + JUMP_S, sx: 1.08, sy: 0.9 });
      frames.push({ ...at(m.x, e.top), t: t + JUMP_S + 0.12 });
      t += JUMP_S + 0.12;
      x = m.x;
      top = e.top;
    } else {
      // To the wall (feet at wy, its side against it), a beat there, off it and up onto the top.
      // The tile's left side: it clings on the outside, left of it (its feet that far from the wall); the right: right.
      const wallX = m.wx <= (e.left + e.right) / 2 ? m.wx - size / 2 + 6 : m.wx + size / 2 - 6;
      frames.push({ ...at(x, top), t: t + 0.06, sx: 1.08, sy: 0.9 });
      frames.push({ ...at(wallX, m.wy), t: t + JUMP_S * 0.6, sx: 0.88, sy: 1.08 });
      frames.push({ ...at(wallX, m.wy - 4), t: t + JUMP_S * 0.6 + WALL_S * 0.5, sx: 0.9, sy: 1.06 });
      frames.push({ ...at((wallX + m.x) / 2, e.top - 30), t: t + JUMP_S * 0.6 + WALL_S * 1.2, sx: 0.95, sy: 1.06 });
      frames.push({ ...at(m.x, e.top), t: t + JUMP_S + WALL_S * 2, sx: 1.08, sy: 0.9 });
      frames.push({ ...at(m.x, e.top), t: t + JUMP_S + WALL_S * 2 + 0.12 });
      t += JUMP_S + WALL_S * 2 + 0.12;
      x = m.x;
      top = e.top;
    }
  }
  const total = Math.max(t, 0.01);
  return {
    duration: total * 1000,
    frames: frames.map((f) => ({
      transform: `translate(${f.dx.toFixed(1)}px, ${f.dy.toFixed(1)}px) scale(${f.sx ?? 1}, ${f.sy ?? 1})`,
      offset: Math.min(1, f.t / total),
    })),
    end: { x, top },
  };
}
