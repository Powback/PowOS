/**
 * App icons in the theme's colours (Settings > style > icons > "icon colours"), optional: "" keeps every icon as the
 * app draws it; "mono" redraws each one in the theme's accent - its own light and dark kept, so its shape still reads,
 * the hue the theme's. Done ONCE per icon, theme and mode, on a canvas in idle time, and kept as an object URL
 * (AppIcon shows the original until its copy is ready) - never a filter redrawn per frame.
 */
import { effect, signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import { stored } from "../state.ts";

/** "" (the apps' own icons) or "mono" (the theme's accent). */
export const iconTint = stored("icons.tint", "");
// The other pages (the pull-up over apps, the switcher): the setting as it changes on home.
addEventListener("storage", (e) => {
  if (e.key === "powos.icons.tint") iconTint.value = e.newValue ?? "";
});

const accentNow = () => getComputedStyle(document.documentElement).getPropertyValue("--color-accent").trim();
/** The theme's accent as the copies were made for it: a new theme makes new ones. */
const accent = signal("");
powos.on("theme.changed", () => setTimeout(() => (accent.value = accentNow()), 0));

/** Bumped as a batch of copies is ready: the icons showing originals look again. */
const ready = signal(0);
const cache = new Map<string, string>();
const queued = new Set<string>();
const queue: [key: string, src: string, rgb: [number, number, number], mode: string][] = [];

// A different theme or mode: the old copies go (their memory with them).
let made = "";
effect(() => {
  const now = `${iconTint.value}|${accent.value}`;
  if (made && now !== made) {
    for (const url of cache.values()) URL.revokeObjectURL(url);
    cache.clear();
    queued.clear();
    queue.length = 0;
  }
  made = now;
});

/** The icon's copy in the theme's colours, if that's on and the copy is made; undefined: show the original. */
export function tinted(src: string): string | undefined {
  const mode = iconTint.value;
  if (!mode || !src) return undefined;
  if (!accent.value) accent.value = accentNow();
  const key = `${mode}|${accent.value}|${src}`;
  const hit = cache.get(key);
  if (hit) return hit;
  void ready.value; // re-rendered when a batch is in
  if (!queued.has(key)) {
    const rgb = parseRgb(accent.value);
    if (!rgb) return undefined;
    queued.add(key);
    queue.push([key, src, rgb, mode]);
    if (queue.length === 1) schedule();
  }
  return undefined;
}

const schedule = () =>
  "requestIdleCallback" in window ? requestIdleCallback(() => void pump(), { timeout: 500 }) : setTimeout(() => void pump(), 50);

/** A few icons per idle moment, then the page told once (not a render per icon). */
async function pump() {
  for (let n = 0; n < 8 && queue.length; n++) {
    const [key, src, rgb, mode] = queue.shift()!;
    try {
      const url = await recolour(src, rgb, mode);
      if (url && queued.has(key)) cache.set(key, url);
    } catch {
      // Not readable (another origin, not drawn yet): it stays the original.
    }
  }
  ready.value++;
  if (queue.length) schedule();
}

async function recolour(src: string, rgb: [number, number, number], mode: string): Promise<string | undefined> {
  const img = new Image();
  img.src = src;
  await img.decode();
  const size = Math.min(192, Math.max(img.naturalWidth, img.naturalHeight)) || 96;
  const c = document.createElement("canvas");
  c.width = c.height = size;
  const g = c.getContext("2d", { willReadFrequently: true })!;
  g.drawImage(img, 0, 0, size, size);
  const data = g.getImageData(0, 0, size, size);
  const px = data.data;
  if (mode === "mono") {
    const [h, s] = toHueSatLight(rgb);
    const sat = Math.min(0.8, Math.max(0.35, s));
    for (let i = 0; i < px.length; i += 4) {
      if (!px[i + 3]) continue;
      const lum = (0.2126 * px[i] + 0.7152 * px[i + 1] + 0.0722 * px[i + 2]) / 255;
      // Its light and dark kept (the shape reads), squeezed off pure black and white so the hue shows in both.
      const [r, gr, b] = fromHueSatLight(h, sat, 0.12 + 0.76 * lum);
      px[i] = r;
      px[i + 1] = gr;
      px[i + 2] = b;
    }
  }
  g.putImageData(data, 0, 0);
  const blob = await new Promise<Blob | null>((ok) => c.toBlob(ok, "image/png"));
  return blob ? URL.createObjectURL(blob) : undefined;
}

function parseRgb(css: string): [number, number, number] | null {
  const m = css.match(/rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)/);
  if (m) return [+m[1], +m[2], +m[3]];
  const hex = css.match(/^#([0-9a-f]{6})$/i);
  if (hex) return [0, 2, 4].map((i) => parseInt(hex[1].slice(i, i + 2), 16)) as [number, number, number];
  return null;
}

function toHueSatLight([r, g, b]: [number, number, number]): [number, number, number] {
  r /= 255;
  g /= 255;
  b /= 255;
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  const l = (max + min) / 2;
  if (max === min) return [0, 0, l];
  const d = max - min;
  const s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
  const h = max === r ? (g - b) / d + (g < b ? 6 : 0) : max === g ? (b - r) / d + 2 : (r - g) / d + 4;
  return [h / 6, s, l];
}

function fromHueSatLight(h: number, s: number, l: number): [number, number, number] {
  const q = l < 0.5 ? l * (1 + s) : l + s - l * s;
  const p = 2 * l - q;
  const ch = (t: number) => {
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    if (t < 1 / 6) return p + (q - p) * 6 * t;
    if (t < 1 / 2) return q;
    if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
    return p;
  };
  return [Math.round(ch(h + 1 / 3) * 255), Math.round(ch(h) * 255), Math.round(ch(h - 1 / 3) * 255)];
}
