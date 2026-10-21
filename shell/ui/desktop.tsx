/**
 * The desktop's home (index.html?mode=desktop, powos-shell's surface under every window: docs/DESKTOP-SHELL.md):
 * the phone's home, its parts as they are - the grid of widgets, apps and PowOS apps' islands (grid.tsx, a tile's
 * corner resizes it), PowOS AI's pill with the launcher and the chat over it (bar.tsx, drawer.tsx: one conversation),
 * the pet on the tiles. Not the phone's: the dock, the pages beside home, the switcher, the shade - Plasma keeps its
 * own panel, notifications and task switcher.
 *
 * The pill opens on a click (or "/" / Ctrl+Space while home has the keyboard); Escape or a click on home closes.
 */
import { useEffect } from "preact/hooks";
import { AppMenu } from "./apps.tsx";
import { Bar } from "./bar.tsx";
import { Drawer } from "./drawer.tsx";
import { EditSheet } from "./editsheet.tsx";
import { drawerOpen, followOpenness } from "./gesture.ts";
import { Carried, Pages } from "./grid.tsx";
import { Pet } from "./pet.tsx";
import { AppScreen } from "./appscreen.tsx";
import { Screens } from "./screens.tsx";
import { back, closeDrawer, drawer, editing, pullKind } from "../state.ts";

// Its own stylesheet, here so the phone's pages never load it (hot.ts swaps it in place like the others).
const css = document.createElement("link");
css.rel = "stylesheet";
css.href = "./ui/desktop.css";
css.dataset.hot = "";
document.head.append(css);

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
    return () => removeEventListener("keydown", key);
  }, []);
}

export function Desktop() {
  useKeys();
  return (
    <>
      <div class={`home ${drawerOpen.value ? "open" : ""} ${editing.value ? "editing" : ""}`}>
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
