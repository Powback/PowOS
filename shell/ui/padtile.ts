/**
 * The Controller tile (control.tsx): the touch controller overlay (GamepadOverlay on the phone, bridge pad.*) on or off,
 * and its layout editor on a long press. The tile shows the real state (asked while the shade shows) but flips at once
 * on a tap; a failed call puts it back and says why for a moment. A host without the overlay (the desktop, an older
 * launcher) rejects pad.state: no tile.
 */
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import type { QuickTile } from "../types.ts";

export const PAD_ID = "powos.pad";

/** The overlay is on; null: not asked yet, or this host has none. */
const on = signal<boolean | null>(null);
/** A failed tap's word, shown a moment under the tile in place of its own. */
const note = signal<string | null>(null);
let noteTimer = 0;
const say = (w: string) => {
  note.value = w;
  clearTimeout(noteTimer);
  noteTimer = window.setTimeout(() => (note.value = null), 2500);
};

/** Asks for the real state (while the shade shows). */
export function askPad() {
  powos.pad?.state().then(
    (v) => (on.value = v),
    () => {},
  );
}

export function padTile(): QuickTile | null {
  if (on.value == null) return null;
  return { id: PAD_ID, label: note.value ?? "controller", on: on.value, detail: on.value ? "on" : "off" };
}

/** Flips at once; the host's answer settles it, a failure puts it back. */
export function togglePad() {
  const was = on.value;
  if (was == null) return;
  on.value = !was;
  powos.pad.overlay(!was).then(
    (v) => (on.value = v),
    (e) => {
      console.warn("pad:", e);
      on.value = was;
      say("failed");
    },
  );
}

/** The long press: the overlay's layout editor (it needs a game session up to edit on). */
export function editPad() {
  powos.pad.edit().then(
    (ok) => ok || say("no game"),
    () => say("failed"),
  );
}
