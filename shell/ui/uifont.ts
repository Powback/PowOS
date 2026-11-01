/**
 * The theme's UI font (Settings > style > font; docs/DESIGN-LANGUAGE.md §4): "ui" (the default, the proportional
 * --font-ui) or "mono" (--font). Shown as html[data-font] - theme.css turns --font-body to the pick, so every UI text
 * follows at once; code, terminals and logs name --font and stay monospace either way. The other pages (the shade, the
 * pull-up over apps, the status bar) follow a pick on home through the storage event, no reload.
 */
import { effect, signal } from "@preact/signals";

export type UiFont = "ui" | "mono";
export const UI_FONTS: UiFont[] = ["ui", "mono"];
// Kept as state.ts stored() keeps its signals (powos.<key>), without importing the page's state: the status bar's
// window (chrome.tsx) loads this too.
const KEY = "powos.style.font";
const read = (): UiFont => {
  try {
    return localStorage.getItem(KEY) === "mono" ? "mono" : "ui";
  } catch {
    return "ui";
  }
};
export const uiFont = signal<UiFont>(read());
addEventListener("storage", (e) => {
  if (e.key === KEY) uiFont.value = read();
});
effect(() => {
  const v = uiFont.value;
  document.documentElement.dataset.font = v;
  try {
    if (v === "mono") localStorage.setItem(KEY, v);
    else localStorage.removeItem(KEY);
  } catch {}
});
