/**
 * Every app icon in one shape and at one visual size, on every surface that shows one (AppIcon: home, dock, its recent
 * apps, the drawer, folders, the library, the recent-apps widget). Each icon's picture is measured ONCE (its non-clear
 * box and what fills it) and kept by URL - the host's icon URLs name their pixels, so a measure never goes stale -
 * here and in localStorage, so a page load lays every known icon out in its first frame. AppIcon only places the img
 * in a squircle face (shell.css .app-icon-face, --icon-radius) from it: static layout, nothing per frame, and the
 * theme-recoloured copies (ui/icontint.ts) fit the same measure, being the same pixels in other colours.
 *
 * - "fill": the picture is a shape of its own (a full-bleed square, an Android adaptive icon - the app draws those in
 *   the squircle itself, AndroidApps -, a rounded square with clear padding): trimmed to its box and filling the face,
 *   the face's corners clip a square one. No plate behind it (the dock rule).
 * - "plate": a transparent or irregular picture (most Linux icons: Konsole, Foot, Dolphin; a round legacy icon): its
 *   box trimmed and fitted to GLYPH of the face, centred on the theme-tinted plate (--icon-plate) of the same
 *   squircle, so its silhouette is the others'. A small one is scaled up, never shown small.
 */
import { signal } from "@preact/signals";

/** How much of the face a plated icon's longer side takes (the spec's minimum is ~70%). */
const GLYPH = 0.76;
/** The analysis canvas's edge, px: enough to find a box to 1%. */
const N = 96;
/** Measures kept in localStorage, newest last (an icon that changed leaves its old URL behind). */
const KEEP = 600;
const STORE = "powos.icons.shape";

/** kind, then the picture's box as fractions of its square: x, y, w, h. */
export type Shape = { kind: "fill" | "plate"; x: number; y: number; w: number; h: number };

const shapes = new Map<string, Shape | null>();
try {
  const saved = JSON.parse(localStorage.getItem(STORE) ?? "[]") as [string, string][];
  for (const [src, v] of saved) shapes.set(src, decode(v));
} catch {
  // No storage (a preview, a private window): measured again this load.
}

/** Bumped as a batch of measures is in: icons laid out unmeasured look again. */
const ready = signal(0);
const queue: string[] = [];
const queued = new Set<string>();
let saveTimer = 0;

/** [src]'s measure, or undefined while it's being taken (shown as it is meanwhile); null: shown as it is. */
export function shapeOf(src: string): Shape | null | undefined {
  if (!src || src.startsWith("blob:")) return null;
  const hit = shapes.get(src);
  if (hit !== undefined) return hit;
  void ready.value; // re-rendered when a batch is in
  if (!queued.has(src)) {
    queued.add(src);
    queue.push(src);
    if (queue.length === 1) schedule();
  }
  return undefined;
}

/** The img's place in the face for [s]: its box (the picture's square) so the measured box lands where it should. */
export function placement(s: Shape | null | undefined): Record<string, string> | undefined {
  if (!s) return undefined;
  const side = Math.max(s.w, s.h);
  const k = Math.min(4, (s.kind === "fill" ? 1 : GLYPH) / side);
  const pc = (v: number) => `${(v * 100).toFixed(2)}%`;
  return {
    width: pc(k),
    height: pc(k),
    left: pc(0.5 - k * (s.x + s.w / 2)),
    top: pc(0.5 - k * (s.y + s.h / 2)),
  };
}

const schedule = () =>
  "requestIdleCallback" in window ? requestIdleCallback(() => void pump(), { timeout: 300 }) : setTimeout(() => void pump(), 30);

async function pump() {
  for (let n = 0; n < 12 && queue.length; n++) {
    const src = queue.shift()!;
    // Not readable (another origin) or not drawn yet (a 404): shown as it is, this page only (not stored); a drawn
    // icon comes with a new URL.
    shapes.set(src, await measure(src).catch(() => null));
    queued.delete(src);
  }
  ready.value++;
  clearTimeout(saveTimer);
  saveTimer = window.setTimeout(save, 2000);
  if (queue.length) schedule();
}

function save() {
  const all = [...shapes].filter(([, s]) => s).slice(-KEEP);
  try {
    localStorage.setItem(STORE, JSON.stringify(all.map(([src, s]) => [src, encode(s!)])));
  } catch {
    // Full or blocked: the measures last this page only.
  }
}

const encode = (s: Shape) => `${s.kind[0]},${[s.x, s.y, s.w, s.h].map((v) => v.toFixed(3)).join(",")}`;
function decode(v: string): Shape | null {
  const [k, ...n] = v.split(",");
  const [x, y, w, h] = n.map(Number);
  return w > 0 && h > 0 ? { kind: k === "f" ? "fill" : "plate", x, y, w, h } : null;
}

/** The picture's box (alpha > 24), and whether it is a shape of its own (fill) or a glyph for the plate. */
async function measure(src: string): Promise<Shape | null> {
  const alpha = await alphaOf(src);
  const b = alpha && box(alpha);
  if (!alpha || !b) return null;
  const [x0, y0, w, h] = b;
  let solid = 0;
  for (let y = y0; y < y0 + h; y++) for (let x = x0; x < x0 + w; x++) solid += alpha[y * N + x] > 200 ? 1 : 0;
  // A shape of its own: about square, and its box nearly all solid (a squircle is ~96%, a rounded square more; a
  // circle ~79% and a monitor, a folder, a glyph less, or not square) - those go on the plate.
  const square = Math.abs(w - h) <= 0.06 * Math.max(w, h);
  const kind = square && solid / (w * h) >= 0.88 ? "fill" : "plate";
  return { kind, x: x0 / N, y: y0 / N, w: w / N, h: h / N };
}

/** [src]'s alpha on an N x N canvas, contained and centred as the img shows it (object-fit: contain). */
async function alphaOf(src: string): Promise<Uint8Array | null> {
  const img = new Image();
  img.src = src;
  await img.decode();
  const iw = img.naturalWidth;
  const ih = img.naturalHeight;
  if (!iw || !ih) return null;
  const c = document.createElement("canvas");
  c.width = c.height = N;
  const g = c.getContext("2d", { willReadFrequently: true })!;
  const f = N / Math.max(iw, ih);
  g.drawImage(img, (N - iw * f) / 2, (N - ih * f) / 2, iw * f, ih * f);
  const px = g.getImageData(0, 0, N, N).data;
  const out = new Uint8Array(N * N);
  for (let i = 0; i < out.length; i++) out[i] = px[i * 4 + 3];
  return out;
}

/** The box of the pixels with alpha > 24: x, y, w, h in canvas px, or null when there are none. */
function box(alpha: Uint8Array): [number, number, number, number] | null {
  const rows: number[] = [];
  const cols = new Uint8Array(N);
  for (let y = 0; y < N; y++) {
    let any = 0;
    for (let x = 0; x < N; x++) if (alpha[y * N + x] > 24) any = cols[x] = 1;
    if (any) rows.push(y);
  }
  if (!rows.length) return null;
  const x0 = cols.indexOf(1);
  const x1 = cols.lastIndexOf(1);
  return [x0, rows[0], x1 - x0 + 1, rows[rows.length - 1] - rows[0] + 1];
}
