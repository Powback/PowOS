import { powos } from "../bridge.ts";
import type { ThemeColors } from "../types.ts";

/**
 * The theme's colors as the tokens everything is drawn with (theme.css's --color-*), and the terminal's (--term-*,
 * from the theme's color0-15): picking a theme recolors the page at once.
 */
let themed = "";
let fadeTimer = 0;
function applyTheme(t: ThemeColors | null) {
  if (!t) return;
  const root = document.documentElement.style;
  // Another theme, live: the colors crossfade (shell.css html.theme-fade) - no reload, nothing remounted.
  const key = JSON.stringify(t.css);
  if (themed && key !== themed) {
    document.documentElement.classList.add("theme-fade");
    clearTimeout(fadeTimer);
    fadeTimer = window.setTimeout(() => document.documentElement.classList.remove("theme-fade"), 260);
  }
  themed = key;
  for (const [k, v] of Object.entries(t.css)) root.setProperty(`--color-${k}`, v);
  // Secondary text (--color-muted) is the theme's foreground a little see-through, never the theme's own muted grey:
  // that one measured 1.5-3.7:1 on the glass, and text keeps >= 4.5:1 on every theme (docs/DESIGN-LANGUAGE.md).
  root.setProperty("--color-muted", `color-mix(in srgb, ${t.css.foreground} var(--muted-text, 84%), transparent)`);
  for (let i = 0; i < 16; i++) if (t.colors[`color${i}`]) root.setProperty(`--term-color${i}`, t.colors[`color${i}`]);
  if (t.colors.cursor) root.setProperty("--term-cursor", t.colors.cursor);
  // Light or dark: what the glass's tint and frosting follow (theme.css, ui/glass.ts).
  document.documentElement.dataset.light = String(!!t.light);
  // No color-scheme: a dark one paints the WebView's canvas opaque, over the wallpaper home shows through.
}
export async function loadTheme() {
  powos.on("theme.changed", applyTheme);
  applyTheme(await powos.theme.get().catch(() => null));
}

