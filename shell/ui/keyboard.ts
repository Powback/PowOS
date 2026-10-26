import { powos } from "../bridge.ts";

/**
 * Takes the keyboard down: blurs the focused field and hides the IME. A page, an overlay or the switcher that changes
 * leaves no keyboard behind. Its own module (no state): recents.tsx importing gesture.ts ran gesture.ts's effects before
 * the signals they read were set up (a cycle through the home page).
 */
export function dropKeyboard() {
  const el = document.activeElement as HTMLElement | null;
  if (!el || !el.matches?.("input, textarea, [contenteditable]")) return;
  el.blur();
  powos.keyboard.hide();
}
