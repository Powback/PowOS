/** The shell: the host's insets as CSS, its state loaded, home mounted. */
import { render } from "preact";
import { powos } from "./bridge.ts";
import { load } from "./state.ts";
import { Home } from "./ui/home.tsx";
import type { Insets, ThemeColors } from "./types.ts";
import "./hot.ts";

/** The host's insets (system bars, cutout, keyboard) as --inset-* custom properties, kept current. */
function applyInsets(i: Partial<Insets> | null) {
  const root = document.documentElement.style;
  for (const side of ["top", "bottom", "left", "right", "keyboard"] as const) root.setProperty(`--inset-${side}`, `${i?.[side] ?? 0}px`);
}
powos.on("system.insets", applyInsets);
applyInsets(await powos.system.insets());

/**
 * The theme's colors as the tokens everything is drawn with (theme.css's --color-*), and the terminal's (--term-*,
 * from the theme's color0-15): picking a theme recolors the page at once.
 */
function applyTheme(t: ThemeColors | null) {
  if (!t) return;
  const root = document.documentElement.style;
  for (const [k, v] of Object.entries(t.css)) root.setProperty(`--color-${k}`, v);
  for (let i = 0; i < 16; i++) if (t.colors[`color${i}`]) root.setProperty(`--term-color${i}`, t.colors[`color${i}`]);
  if (t.colors.cursor) root.setProperty("--term-cursor", t.colors.cursor);
  root.setProperty("color-scheme", t.light ? "light" : "dark");
}
powos.on("theme.changed", applyTheme);
applyTheme(await powos.theme.get().catch(() => null));

await load();
render(<Home />, document.body);
