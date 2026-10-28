/** The shell: the host's insets as CSS, its state loaded, home mounted. */
import { loadTheme } from "./ui/theme.ts";
import { render } from "preact";
import { powos } from "./bridge.ts";
import { Home } from "./ui/home.tsx";
import { Aod } from "./ui/aod.tsx";
import { Assist } from "./ui/assist.tsx";
import { Shade } from "./ui/shade.tsx";
import { Lock } from "./ui/lock.tsx";
import { Recents } from "./ui/recents.tsx";
import { chat, load } from "./state.ts";
import type { Insets } from "./types.ts";
import "./hot.ts";
import { measureIcons } from "./ui/iconperf.ts";
import "./ui/glass.ts";
import "./ui/refresh.ts";
import { handOff, keepSnapshots, restored } from "./ui/snapshot.ts";

/** The host's insets (system bars, cutout, keyboard) as --inset-* custom properties, kept current. */
function applyInsets(i: Partial<Insets> | null) {
  const root = document.documentElement.style;
  for (const side of ["top", "bottom", "left", "right", "keyboard"] as const) root.setProperty(`--inset-${side}`, `${i?.[side] ?? 0}px`);
}
powos.on("system.insets", applyInsets);
applyInsets(await powos.system.insets());

await loadTheme();

/**
 * Which screen this page is: the host says (index.html?mode=) - home (its switcher is a layer of it, ui/recents.tsx),
 * or a slot's (aod: screen-off; assist: PowOS AI over an app; shade: the notification shade; lock: the lock face;
 * recents: the switcher alone, when the desktop is home; panel: the desktop's taskbar, from powos-shell; desktop: the
 * desktop's home, from powos-shell; glasses: the
 * smart glasses' screen, off screen).
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
} else if (mode === "quicktools") {
  // Quick Tools (QuickToolsHost.kt): the control center's tiles in a card by the thumb, over any app.
  const { QuickTools } = await import("./ui/quicktools.tsx");
  render(<QuickTools />, document.body);
} else if (mode === "panel") {
  // The desktop's panel (powos-shell: a layer surface per screen, docs/DESKTOP-WEB-SHELL.md): the bar alone.
  const { Panel } = await import("./ui/panel.tsx");
  render(<Panel />, document.body);
} else if (mode === "desktop") {
  // The desktop's home (powos-shell: a layer surface under every window, docs/DESKTOP-SHELL.md): home's grid, the pill
  // and its launcher and chat, the pet - Plasma keeps its own panel, notifications and switcher.
  await load();
  const { Desktop } = await import("./ui/desktop.tsx");
  render(<Desktop />, document.body);
} else if (mode === "petover") {
  // The pet over apps (system/PetOverlay.kt's small window at a screen edge): the pet alone, its state live.
  const { PetOver } = await import("./ui/pet.tsx");
  render(<PetOver />, document.body);
} else if (mode === "glasses") {
  // The smart glasses' screen (glasses/Glasses.kt loads it off screen while they're connected): what they show,
  // pushed to them as it changes. Imported here alone: the rest of home isn't loaded.
  const { GlassesSurface } = await import("./glasses/surface.tsx");
  render(<GlassesSurface />, document.body);
} else if (mode === "gate-test") {
  // Tests only (test/gate-test.tsx; in the APK, so a rollback has it to fall back to): the page a test of the gate,
  // the watchdog and the rollback breaks instead of a live one. Imported here alone: a broken one breaks nothing else.
  const { GateTest } = await import("./test/gate-test.tsx");
  render(<GateTest />, document.body);
} else if (mode === "pull") {
  // The pull-up panel over an app (the edge gestures' overlay window): the drawer or PowOS AI's, nothing else of home.
  await load();
  const { Pull } = await import("./ui/pull.tsx");
  render(<Pull />, document.body);
} else if (mode === "assist") {
  // Over another app: PowOS AI's chat only (the rest of home isn't loaded).
  chat.value = await powos.ai.chat();
  render(<Assist />, document.body);
} else {
  await load();
  // Floating windows live on home's pages (one desktop per page).
  void import("./ui/desktops.ts").then((d) => d.startDesktops());
  // Home's last frame (index.html) gives way to home itself once it's laid out: no blank frame between.
  handOff(() => render(<Home />, document.body));
  measureIcons(restored != null);
  keepSnapshots();
  // The fps meter's source: this page's own frames, sent to the status bar's meter (only while it is on).
  void import("./ui/fpssample.ts").then((m) => m.startSampler());
}
// The page ran and drew its screen: what the native hosts ask before they let a window of theirs cover the screen
// (shell/PageWatchdog.kt) - a page that never got here (a module that didn't load) has its window taken away.
(window as unknown as { __powosAlive?: boolean }).__powosAlive = true;
