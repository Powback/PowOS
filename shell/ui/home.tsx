/**
 * Home: the pages; the launcher panel - the recent apps bar, which a swipe up grows into the drawer: the recent row
 * rides the top edge as it follows the finger, and all the apps unfold under it - one component, the bar is the
 * launcher's head; the search bar; and under it the dock, the apps pinned to stay at hand (as on iOS).
 *
 * The panel's openness (gesture.ts) is one number, --p, on the stage: the frame's top edge and the clip that reveals
 * the drawer move with it in CSS, so a frame of the swipe moves an edge, not a re-laid-out list of apps.
 */
import { AppCell, AppMenu } from "./apps.tsx";
import { Bar } from "./bar.tsx";
import { Drawer } from "./drawer.tsx";
import { drawerDragging, drawerOpen, followOpenness, homeGestures } from "./gesture.ts";
import { Pages } from "./grid.tsx";
import { RECENT, byKey, dock, recent } from "../state.ts";

/** The apps opened lately, last first - not those pinned to the dock, which are at hand already. */
function RecentRow() {
  const pinned = new Set(dock.value);
  const shown = recent.value
    .filter((k) => !pinned.has(k))
    .map((k) => byKey.value.get(k))
    .filter((a) => a != null)
    .slice(0, RECENT);
  return (
    <div class="strip">
      {shown.map((app) => (
        <AppCell key={app.key} app={app} labels={false} />
      ))}
    </div>
  );
}

/** The dock: pinned apps under the bar, folding away while the launcher is open (shell.css). */
function Dock() {
  const pinned = dock.value.map((k) => byKey.value.get(k)).filter((a) => a != null);
  if (!pinned.length) return null;
  return (
    <div class="dock tile" data-p ref={followOpenness}>
      {pinned.map((app) => (
        <AppCell key={app.key} app={app} labels={false} />
      ))}
    </div>
  );
}

export function Home() {
  // data-p: these follow the panel's openness (--p, written by gesture.ts, not through a render).
  return (
    <div class={`home ${drawerDragging.value ? "dragging" : ""} ${drawerOpen.value ? "open" : ""}`} {...homeGestures()}>
      <div class="stage">
        <div class="home-content" data-p ref={followOpenness}>
          <Pages />
        </div>
        <div class="launcher-frame tile" data-p ref={followOpenness} />
        <div class="launcher" data-p ref={followOpenness}>
          <div class="launcher-inner">
            <RecentRow />
            <div class="drawer-clip">
              <Drawer />
            </div>
          </div>
        </div>
      </div>
      <Bar />
      <Dock />
      <AppMenu />
    </div>
  );
}
