/** The shell: the host's insets as CSS, its state loaded, home mounted. */
import { render } from "preact";
import { powos } from "./bridge.ts";
import { Home } from "./ui/home.tsx";
import { Aod } from "./ui/aod.tsx";
import { Assist } from "./ui/assist.tsx";
import { Shade } from "./ui/shade.tsx";
import { Lock } from "./ui/lock.tsx";
import { Recents } from "./ui/recents.tsx";
import { chat, load } from "./state.ts";
import type { Insets, ThemeColors } from "./types.ts";
import "./hot.ts";
import { measureIcons } from "./ui/iconperf.ts";
import { handOff, keepSnapshots, restored } from "./ui/snapshot.ts";

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

/**
 * Which screen this page is: the host says (index.html?mode=) - home (its switcher is a layer of it, ui/recents.tsx),
 * or a slot's (aod: screen-off; assist: PowOS AI over an app; shade: the notification shade; lock: the lock face;
 * recents: the switcher alone, when the desktop is home).
 */
const mode = new URLSearchParams(location.search).get("mode");
document.documentElement.dataset.mode = mode ?? "home";
if (mode === "aod") {
  render(<Aod />, document.body);
} else if (mode === "recents") {
  // The switcher on its own (the recents activity's page, when the desktop is home): home's layer, alone.
  render(<Recents />, document.body);
} else if (mode === "lock") {
  // The lock screen's face (PowosLockActivity), over Android's lock screen.
  render(<Lock />, document.body);
} else if (mode === "shade") {
  // The system's shade (the native shade host's window): the notification panel alone.
  render(<Shade />, document.body);
} else if (mode === "assist") {
  // Over another app: PowOS AI's chat only (the rest of home isn't loaded).
  chat.value = await powos.ai.chat();
  render(<Assist />, document.body);
} else {
  await load();
  // Home's last frame (index.html) gives way to home itself once it's laid out: no blank frame between.
  handOff(() => render(<Home />, document.body));
  measureIcons(restored != null);
  keepSnapshots();
}
