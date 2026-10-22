/**
 * The widget detail sheet: a widget's other controls in a frosted popup anchored to it (ui/widgetsheet.tsx draws it),
 * for any PowOS app's island - Lights' long-pressed room: colour, scenes, each light.
 *
 *   {open && host.DetailSheet && (
 *     <host.DetailSheet anchor={pillEl} title="Living room" onClose={() => setOpen(false)}>
 *       ...the controls, the island's own components and state...
 *     </host.DetailSheet>
 *   )}
 *
 * Rendered in place it draws nothing: its children go to the shell's one sheet (a signal), again on every render, so
 * they stay live with the island's state. Unmounted, the sheet goes. A tap outside, a swipe down on it or Back calls
 * onClose - the island decides (it unmounts it). Inside, sliders own their drags (input[type=range], role=slider).
 */
import { signal } from "@preact/signals";
import type { ComponentChildren } from "preact";
import { useLayoutEffect, useRef } from "preact/hooks";

export interface OpenSheet {
  id: number;
  /** The widget's box on the screen when it opened (the sheet stays put while it's open). */
  anchor: DOMRect;
  title?: string;
  children: ComponentChildren;
  onClose: () => void;
}

/** The open sheet: one at a time (a second one replaces it). */
export const detailSheet = signal<OpenSheet | null>(null);
let next = 1;

export interface DetailSheetProps {
  /** What it's anchored to: the long-pressed element (or its box). */
  anchor: Element | DOMRect | null;
  title?: string;
  onClose: () => void;
  children?: ComponentChildren;
}

export function DetailSheet({ anchor, title, onClose, children }: DetailSheetProps) {
  const id = useRef(0);
  const at = useRef<DOMRect | null>(null);
  if (!id.current) id.current = next++;
  if (!at.current && anchor) at.current = anchor instanceof Element ? anchor.getBoundingClientRect() : anchor;
  useLayoutEffect(() => {
    detailSheet.value = { id: id.current, anchor: at.current ?? new DOMRect(innerWidth / 2, innerHeight / 2, 0, 0), title, children, onClose };
  });
  useLayoutEffect(
    () => () => {
      if (detailSheet.peek()?.id === id.current) detailSheet.value = null;
    },
    [],
  );
  return null;
}
