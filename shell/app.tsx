/** The shell: the host's insets as CSS, its state loaded, home mounted. */
import { render } from "preact";
import { powos } from "./bridge.ts";
import { load } from "./state.ts";
import { Home } from "./ui/home.tsx";
import { Aod } from "./ui/aod.tsx";
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
  // No color-scheme: a dark one paints the WebView's canvas opaque, over the wallpaper home shows through.
}
powos.on("theme.changed", applyTheme);
applyTheme(await powos.theme.get().catch(() => null));

/** Which screen this page is: the host says (index.html?mode=) - home, or a system slot's (aod: the screen-off display). */
const mode = new URLSearchParams(location.search).get("mode");
document.documentElement.dataset.mode = mode ?? "home";
if (mode === "aod") {
  render(<Aod />, document.body);
} else {
  await load();
  render(<Home />, document.body);
}
