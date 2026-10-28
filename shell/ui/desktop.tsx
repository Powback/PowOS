/**
 * The desktop's home (index.html?mode=desktop, powos-shell's surface under every window: docs/DESKTOP-SHELL.md):
 * the phone's home, its parts as they are - the grid of widgets, apps and PowOS apps' islands (grid.tsx, a tile's
 * corner resizes it), PowOS AI's pill with the launcher and the chat over it (bar.tsx, drawer.tsx: one conversation),
 * the pet on the tiles, the dock under the pill. Not the phone's: the pages beside home, the switcher, the shade -
 * Plasma keeps its own panel, notifications and task switcher.
 *
 * The pill opens on a click (or "/" / Ctrl+Space while home has the keyboard); Escape or a click on home closes.
 */
import { useEffect } from "preact/hooks";
import { effect, signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import type { GlassSource } from "../types.ts";
import { AppMenu } from "./apps.tsx";
import { Dock } from "./home.tsx";
import { Bar } from "./bar.tsx";
import { Drawer } from "./drawer.tsx";
import { EditSheet } from "./editsheet.tsx";
import { drawerOpen, followOpenness } from "./gesture.ts";
import { Carried, Pages } from "./grid.tsx";
import { Pet } from "./pet.tsx";
import { AppScreen } from "./appscreen.tsx";
import { Screens } from "./screens.tsx";
import { back, chatting, closeDrawer, dockPosition, drawer, editing, pullKind } from "../state.ts";

// Its own stylesheet, here so the phone's pages never load it (hot.ts swaps it in place like the others).
const css = document.createElement("link");
css.rel = "stylesheet";
css.href = "./ui/desktop.css";
css.dataset.hot = "";
document.head.append(css);

/**
 * The home's own wallpaper while it runs: it owns the desktop (Plasma's desktop and its widgets are under it, as they
 * were, when it stops). One static layer: the host's picture (system.glass), else the theme's background.
 */
const wall = signal<string | null>(null);
const wallFrom = (g: GlassSource | null) => (wall.value = g?.wallpaper?.url ?? null);
powos.system.glass().then(wallFrom, () => {});
powos.on("system.glass", wallFrom);

// The chat open: the pill asks ("ask PowOS AI", Enter sends - not the best app match), as over PowOS AI's panel.
effect(() => {
  if (chatting.value && drawer.value > 0 && pullKind.value !== "ai") pullKind.value = "ai";
});

function useKeys() {
  useEffect(() => {
    const key = (e: KeyboardEvent) => {
      const typing = e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement;
      if (e.key === "Escape") {
        if (back()) e.preventDefault();
      } else if ((e.key === "/" && !typing) || (e.key === " " && e.ctrlKey)) {
        e.preventDefault();
        if (drawer.value === 0) pullKind.value = "apps";
        drawer.value = 1;
        document.querySelector<HTMLTextAreaElement>(".bar-pill textarea")?.focus();
      }
    };
    addEventListener("keydown", key);
    // Meta / KWin's swipe-up (powos-shell's org.powos.Shell /Launcher), sent here when no panel runs: as "/" does.
    const offToggle = powos.on("launcher.toggle", () => {
      if (drawer.value > 0) return void closeDrawer();
      pullKind.value = "apps";
      drawer.value = 1;
      document.querySelector<HTMLTextAreaElement>(".bar-pill textarea")?.focus();
    });
    return () => (removeEventListener("keydown", key), offToggle());
  }, []);
}

export function Desktop() {
  useKeys();
  return (
    <>
      <div class="desk-wall" style={wall.value ? { backgroundImage: `url("${wall.value}")` } : undefined} />
      <div class={`home dock-${dockPosition.value} ${drawerOpen.value ? "open" : ""} ${editing.value ? "editing" : ""} ${chatting.value ? "chatting" : ""}`}>
        {/* Open, only the launcher takes the pointer: a click beside it lands on the stage itself and closes it. */}
        <div class="stage" onClick={(e) => drawerOpen.value && e.target === e.currentTarget && closeDrawer()}>
          <div class="home-content" data-p ref={followOpenness}>
            <Pages />
          </div>
          <div class="launcher" data-p ref={followOpenness}>
            <div class="launcher-frame tile" />
            <div class="launcher-inner">
              <div class="drawer-clip">
                <Drawer />
              </div>
            </div>
          </div>
        </div>
        <Bar />
        <Dock />
        <AppMenu />
        <EditSheet />
      </div>
      <Pet />
      <AppScreen />
      <Screens />
      <Carried />
    </>
  );
}
