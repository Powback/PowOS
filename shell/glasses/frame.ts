/**
 * Turning the glasses page's DOM into what the glasses show (docs/GLASSES.md): its text for the glasses' own text
 * rendering (the G2's teleprompter, the G1's text screen), or its pixels - the page drawn into a canvas through an SVG
 * foreignObject (as apps/pages.ts shotOf does for switcher cards), quantized to the glasses' depth so a change the
 * glasses can't show isn't sent, and handed to the host as a PNG (it converts to 4-bit greys / 1-bit BMP).
 *
 * Pure enough to run anywhere the page does: the mock in a desktop browser, the gate's headless Chromium.
 */

/** The glasses' display. */
export interface Canvas {
  width: number;
  height: number;
  /** 4: 16 greys (G2); 1: black and white (G1). */
  bits: number;
}

/**
 * What a frame is sent as: "text" (the glasses render it: a font of their own, about [cols] x [rows] characters) or
 * "image" (pixels). The G2 gets text unless its unverified picture path is on; the G1 gets pictures.
 */
export type FrameMode = "text" | "image";

/** Characters per line and lines that fit, per model, in text mode (G2Protocol.pages: 25 a line, ~7 lines in view; the G1's 40 x 5). */
export function textGrid(c: Canvas): { cols: number; rows: number } {
  return c.bits === 1 ? { cols: 40, rows: 5 } : { cols: 25, rows: 7 };
}

/** [el]'s text as the glasses get it: its rendered lines, trailing blanks dropped, blank lines kept single. */
export function textOf(el: HTMLElement): string {
  const raw = (el.innerText ?? el.textContent ?? "").replace(/\r/g, "");
  return raw
    .split("\n")
    .map((l) => l.replace(/\s+$/, ""))
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

/** BT.601 luma of each RGBA pixel, quantized to [bits] (2^bits levels): what the glasses can tell apart. */
export function levels(rgba: Uint8ClampedArray, bits: number): Uint8Array {
  const out = new Uint8Array(rgba.length / 4);
  const max = (1 << bits) - 1;
  for (let i = 0, p = 0; i < rgba.length; i += 4, p++) {
    const y = 0.299 * rgba[i] + 0.587 * rgba[i + 1] + 0.114 * rgba[i + 2];
    out[p] = bits === 1 ? (y > 127 ? 1 : 0) : Math.floor((y * max) / 255);
  }
  return out;
}

export function sameLevels(a: Uint8Array | null, b: Uint8Array | null): boolean {
  if (!a || !b || a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

/**
 * [el] drawn at [c]'s size: its DOM in an SVG foreignObject, the page's custom properties with it, onto a canvas.
 * Returns the PNG (data: URL) and its quantized levels; null if it couldn't be drawn.
 */
export async function rasterize(el: HTMLElement, c: Canvas): Promise<{ png: string; levels: Uint8Array } | null> {
  try {
    const clone = el.cloneNode(true) as HTMLElement;
    clone.style.width = `${c.width}px`;
    clone.style.height = `${c.height}px`;
    const style = getComputedStyle(el);
    const xhtml = new XMLSerializer().serializeToString(clone);
    // The page's stylesheets don't reach into the picture: what matters is inline here (white on black, lines kept).
    const wrap = `width:${c.width}px;height:${c.height}px;overflow:hidden;background:#000;color:#fff;white-space:pre;font-family:${style.fontFamily};font-size:${style.fontSize}`.replace(/"/g, "'");
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${c.width}" height="${c.height}"><foreignObject width="100%" height="100%"><div xmlns="http://www.w3.org/1999/xhtml" style="${wrap}">${xhtml}</div></foreignObject></svg>`;
    const img = new Image();
    img.src = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
    await img.decode();
    const canvas = document.createElement("canvas");
    canvas.width = c.width;
    canvas.height = c.height;
    const ctx = canvas.getContext("2d");
    if (!ctx) return null;
    ctx.fillStyle = "#000";
    ctx.fillRect(0, 0, c.width, c.height);
    ctx.drawImage(img, 0, 0);
    const data = ctx.getImageData(0, 0, c.width, c.height).data;
    return { png: canvas.toDataURL("image/png"), levels: levels(data, c.bits) };
  } catch (e) {
    console.warn("[glasses] frame not drawn", e);
    return null;
  }
}

/**
 * Sends at most one frame per [gapMs] and never two at once: the newest waiting frame goes when the last one is done
 * and the gap is over; frames in between are skipped (a display shows the latest, not a backlog). The G2's text takes
 * ~2.5 s on the glasses (its teleprompter sequence), a G1 picture ~2.7 s (53 packets 50 ms apart).
 */
export class Pacer {
  private next: (() => Promise<unknown>) | null = null;
  private busy = false;
  private last = 0;
  private timer = 0;

  constructor(private gapMs: () => number) {}

  push(send: () => Promise<unknown>) {
    this.next = send;
    this.pump();
  }

  private pump() {
    if (this.busy || !this.next) return;
    const wait = this.last + this.gapMs() - Date.now();
    if (wait > 0) {
      clearTimeout(this.timer);
      this.timer = window.setTimeout(() => this.pump(), wait);
      return;
    }
    const send = this.next;
    this.next = null;
    this.busy = true;
    send()
      .catch((e) => console.warn("[glasses] send failed", e))
      .finally(() => {
        this.busy = false;
        this.last = Date.now();
        this.pump();
      });
  }
}

/** The gap between frames (ms) for [mode] on [c]: what the glasses take to show one. */
export function gapFor(mode: FrameMode, c: Canvas): number {
  if (mode === "text") return c.bits === 1 ? 800 : 3000;
  return 3000;
}
