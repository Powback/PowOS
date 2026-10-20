/**
 * What a glasses app (the module the glasses' screen shows: the built-in HUD, glasses/hud.tsx, or a PowOS app's
 * manifest "glasses": { entry }) gets: the display it draws for, and the glasses' input. Its default export is a
 * Preact component, rendered by glasses/surface.tsx at the canvas's size and props { glasses: GlassesApi, host }.
 *
 * Draw for [GlassesApi.view]: in "text" mode only the text reaches the glasses (laid out by them, about cols x rows
 * characters - lay lines out to that); in "image" mode the pixels do (black is off, white is brightest; the G2 has 16
 * greys, the G1 two). Changes are pushed by the surface when what would be shown changed - nothing to call.
 */
import { signal } from "@preact/signals";
import { useEffect, useRef } from "preact/hooks";
import type { FrameMode } from "./frame.ts";

export interface GlassesView {
  /** "G2" | "G1"; null before the host said. */
  model: string | null;
  width: number;
  height: number;
  bits: number;
  mode: FrameMode;
  /** Text mode's grid: characters a line, lines in view. */
  cols: number;
  rows: number;
}

/**
 * Input from the glasses: "click", "double", "up", "down" (the G2's touch bars / ring; the G1's taps), "headUp",
 * "headDown" (G1), "enter" / "exit" (the glasses' foreground). On a desktop browser, keys stand in: Enter, Space,
 * the arrows.
 */
export type GlassesInputName = "click" | "double" | "up" | "down" | "headUp" | "headDown" | "enter" | "exit" | string;

export interface GlassesApi {
  view: GlassesView;
  /**
   * The glasses' own screen (true), or the phone's preview of it (false): only the live one acts for the wearer -
   * the microphone, messages to PowOS AI.
   */
  live: boolean;
  /** Calls [handler] with each input while the component is mounted. */
  useInput(handler: (input: GlassesInputName) => void): void;
}

export const view = signal<GlassesView>({ model: null, width: 576, height: 288, bits: 4, mode: "text", cols: 25, rows: 7 });

const handlers = new Set<(input: GlassesInputName) => void>();

export function dispatchInput(input: GlassesInputName) {
  handlers.forEach((h) => {
    try {
      h(input);
    } catch (e) {
      console.error("[glasses] input handler", e);
    }
  });
}

export function useGlassesInput(handler: (input: GlassesInputName) => void) {
  const latest = useRef(handler);
  latest.current = handler;
  useEffect(() => {
    const h = (i: GlassesInputName) => latest.current(i);
    handlers.add(h);
    return () => void handlers.delete(h);
  }, []);
}

/** [text] word-wrapped to [cols] characters a line (long words cut), blank lines kept. */
export function wrap(text: string, cols: number): string[] {
  const out: string[] = [];
  for (const para of text.replace(/\r/g, "").split("\n")) {
    if (!para.trim()) {
      out.push("");
      continue;
    }
    let line = "";
    for (let word of para.split(/\s+/).filter(Boolean)) {
      while (word.length > cols) {
        if (line) out.push(line);
        out.push(word.slice(0, cols));
        word = word.slice(cols);
        line = "";
      }
      if (!line) line = word;
      else if (line.length + 1 + word.length <= cols) line += " " + word;
      else {
        out.push(line);
        line = word;
      }
    }
    if (line) out.push(line);
  }
  return out;
}
