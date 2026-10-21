/**
 * Where the pet stands (docs/PET.md v2, step b): on the top edge of a tile on home's page on screen, or of the search pill at its foot.
 * The edges are the tiles' rects (grid.tsx's .home-tile[data-key], the search pill), read when they're needed - at a drop, a
 * page change, a layout change - never per frame.
 *
 * A perch is { key, fx }: the tile's key ("bar" for the search pill at home's foot) and how far along its top edge (0..1). Its place on the
 * screen comes from the edge as laid out now, so a tile that moves takes the pet with it; one that's gone (or on
 * another page) sends it to the nearest edge there is.
 *
 * A drop or a fling is a short fall (gravity, a little drag): it lands on the first edge it crosses on the way down, or
 * the lowest one if it misses them all. Frames only while it's in the air.
 */

export interface Edge {
  key: string;
  left: number;
  right: number;
  top: number;
  /** The tile's bottom: its sides are walls from [top] to here (petpath.ts wall-jumps). */
  bottom?: number;
  /** A line of text's: the tile it's in (it can stand on the line inside its own tile). */
  owner?: string;
}

/** Lines of text it can stand on, at most this many (a page's widgets' text; measured only when edges are). */
const TEXT_LINES = 30;

export interface Perch {
  key: string;
  fx: number;
}

/** How far the feet sit into the edge (the shadow just under them). */
const SINK = 0.06;

/** The edges on screen now: the tiles of the page showing, and the dock. */
export function edges(): Edge[] {
  const out: Edge[] = [];
  const W = innerWidth;
  const H = innerHeight;
  // Room above an edge for the whole pet under the status bar (an edge at the screen's top: its head would be
  // under the bar - the phone showed it cut off).
  const inset = parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--inset-top")) || 24;
  const minTop = inset + (innerWidth >= 600 ? 72 : 64) + 4;
  for (const el of document.querySelectorAll<HTMLElement>(".page:not(.away) .home-tile[data-key]")) {
    if (el.classList.contains("lifted")) continue;
    const r = el.getBoundingClientRect();
    // On screen, and wide enough to stand on.
    if (r.width < 40 || r.right < 0 || r.left > W || r.top < minTop || r.top > H - 40) continue;
    out.push({ key: el.dataset.key!, left: r.left, right: r.right, top: r.top, bottom: r.bottom });
  }
  // Lines of text in the tiles (their rendered line boxes, Range.getClientRects): platforms too, inside their tile.
  let n = 0;
  const range = document.createRange();
  for (const el of document.querySelectorAll<HTMLElement>(".page:not(.away) .home-tile[data-key]")) {
    if (n >= TEXT_LINES) break;
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    for (let t = walker.nextNode(); t && n < TEXT_LINES; t = walker.nextNode()) {
      if (!t.textContent?.trim() || t.parentElement?.closest("svg, canvas, input, textarea")) continue;
      range.selectNodeContents(t);
      for (const r of range.getClientRects()) {
        if (r.width < 48 || r.height < 10 || r.top < minTop || r.top > H - 40 || r.right < 0 || r.left > W) continue;
        out.push({ key: `text:${el.dataset.key}:${n}`, left: r.left, right: r.right, top: r.top, bottom: r.bottom, owner: el.dataset.key });
        if (++n >= TEXT_LINES) break;
      }
    }
  }
  // An edge under another tile (a joined group: the lower tile's top is inside the upper one) isn't a floor: the part
  // that's open is kept, the covered rest cut off; an edge covered all along goes.
  const rects = [...document.querySelectorAll<HTMLElement>(".page:not(.away) .home-tile[data-key]")].map((el) => ({ key: el.dataset.key!, r: el.getBoundingClientRect() }));
  for (let i = out.length - 1; i >= 0; i--) {
    const e = out[i];
    for (const { key, r } of rects) {
      if (key === e.key || key === e.owner || !(e.top - 3 > r.top && e.top - 3 < r.bottom)) continue;
      // [r] covers the strip just above this edge from r.left to r.right: keep the longer open side.
      if (r.left <= e.left && r.right >= e.right) e.right = e.left; // all covered
      else if (r.left <= e.left) e.left = Math.max(e.left, r.right);
      else if (r.right >= e.right) e.right = Math.min(e.right, r.left);
    }
    if (e.right - e.left < 40) out.splice(i, 1);
  }
  // Home's foot: the search pill's top edge (the dock is under the pill - standing on it would be inside the pill).
  const pill = document.querySelector<HTMLElement>(".bar .bar-pill") ?? document.querySelector<HTMLElement>(".bar");
  if (pill) {
    const r = pill.getBoundingClientRect();
    if (r.width > 40 && r.top < H && r.bottom > 0) out.push({ key: "bar", left: r.left + 12, right: r.right - 12, top: r.top });
  }
  return out;
}

/** The pet's top-left for a perch on [e] (its size [s]): centred on the point along the edge, feet on it. */
export function placeOn(e: Edge, fx: number, s: number) {
  const x = e.left + Math.min(1, Math.max(0, fx)) * (e.right - e.left);
  return {
    left: Math.min(innerWidth - s - 4, Math.max(4, x - s / 2)),
    top: e.top - s * (1 - SINK),
  };
}

/** The perch for a pet whose feet are at (x, y): the nearest edge under it, else the nearest at all. */
export function perchAt(x: number, y: number, list = edges()): Perch | null {
  if (!list.length) return null;
  const under = list.filter((e) => x >= e.left - 8 && x <= e.right + 8 && e.top >= y - 24).sort((a, b) => a.top - b.top);
  const e =
    under[0] ??
    [...list].sort((a, b) => dist(a, x, y) - dist(b, x, y))[0];
  return { key: e.key, fx: (Math.min(e.right, Math.max(e.left, x)) - e.left) / Math.max(1, e.right - e.left) };
}

const dist = (e: Edge, x: number, y: number) => {
  const cx = Math.min(e.right, Math.max(e.left, x));
  return Math.hypot(cx - x, e.top - y);
};

/** Where a perch is now (null: its edge isn't on screen - the caller finds another). */
export function where(p: Perch | null, s: number, list = edges()) {
  if (!p) return null;
  const e = list.find((x) => x.key === p.key);
  return e ? placeOn(e, p.fx, s) : null;
}

/**
 * A fall from the pet's top-left (x, y) with a velocity (px/frame): calls [frame] with each position, and [land] with
 * the perch it lands on (and the impact speed, for the squash). Returns a cancel.
 */
export function fall(
  x: number,
  y: number,
  vx: number,
  vy: number,
  s: number,
  frame: (x: number, y: number) => void,
  land: (p: Perch, speed: number) => void,
) {
  const list = edges();
  const lowest = list.reduce<Edge | null>((m, e) => (!m || e.top > m.top ? e : m), null);
  let raf = 0;
  let n = 0;
  const step = () => {
    const feet0 = y + s * (1 - SINK);
    vy = Math.min(vy + 0.9, 28);
    vx *= 0.97;
    x = Math.min(innerWidth - s - 4, Math.max(4, x + vx));
    y += vy;
    const feet = y + s * (1 - SINK);
    const cx = x + s / 2;
    // Crossed an edge's top on the way down, over it: landed.
    const hit = vy > 0 ? list.filter((e) => cx >= e.left && cx <= e.right && feet0 <= e.top && feet >= e.top).sort((a, b) => a.top - b.top)[0] : undefined;
    const missed = !hit && lowest && feet > lowest.top + 4 && feet > innerHeight * 0.95;
    if (hit || missed || ++n > 180) {
      const e = hit ?? lowest;
      if (!e) return;
      const fx = (Math.min(e.right, Math.max(e.left, cx)) - e.left) / Math.max(1, e.right - e.left);
      const at = placeOn(e, fx, s);
      frame(at.left, at.top);
      land({ key: e.key, fx }, Math.abs(vy));
      raf = 0;
      return;
    }
    frame(x, y);
    raf = requestAnimationFrame(step);
  };
  raf = requestAnimationFrame(step);
  return () => cancelAnimationFrame(raf);
}
