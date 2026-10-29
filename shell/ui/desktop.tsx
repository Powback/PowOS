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
import { back, chatting, closeDrawer, dockPosition, drawer, editing, page, pages, pullKind } from "../state.ts";

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

/**
 * Home's pages are KWin's virtual desktops (docs/DESKTOP-KWIN-NATIVE.md; the user, 2026-10-29: "it should be pinned to
 * a page properly natively"): one desktop per page, in page order. A window belongs to the desktop it opened on;
 * a page change here switches KWin's current desktop (KWin's slide effect moves the windows), and KWin switching
 * (keyboard, gestures) moves home to that page. PowOS AI's page (-1) and the app library are no desktops: KWin stays
 * where it was. Started once: KWin's current desktop is adopted first, so a reload never moves the user's windows.
 */
function followDesktops() {
  let started = false;
  /** setCurrent calls under way: KWin's switches for earlier ones (a quick double swipe) are steps, not the user's. */
  let pending = 0;
  const switchTo = (i: number) => {
    pending++;
    powos.desktops.setCurrent(i).catch(() => {}).finally(() => pending--);
  };
  powos.desktops.ensure(pages.peek().length).then(
    (list) => {
      const now = list.findIndex((d) => d.current);
      if (now >= 0 && now < pages.peek().length) page.value = now;
      started = true;
      // Home's layout came in while the list was asked: KWin's count follows it.
      if (pages.peek().length !== list.length) powos.desktops.ensure(pages.peek().length).catch(() => {});
      // A page settled while the list was asked: KWin follows it.
      if (page.peek() >= 0 && page.peek() < pages.peek().length && page.peek() !== now) switchTo(page.peek());
    },
    () => {}, // not powos-shell (a browser preview): no desktops
  );
  // A page added or removed (edit mode's empty page, a tile moved to a new page): KWin's count follows.
  effect(() => {
    const count = pages.value.length;
    if (started) powos.desktops.ensure(count).catch(() => {});
  });
  effect(() => {
    const p = page.value;
    if (started && p >= 0 && p < pages.peek().length) switchTo(p);
  });
  powos.on("desktops.current", (i: number) => {
    if (!started || (pending > 0 && i !== page.peek())) return;
    if (i >= 0 && i < pages.peek().length && page.peek() !== i) page.value = i;
  });
}
followDesktops();

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
