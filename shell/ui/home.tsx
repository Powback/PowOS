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
import { drawerDrag, drawerShown, homeGestures } from "./gesture.ts";
import { Pages } from "./grid.tsx";
import { byKey, dock, drawer, recent } from "../state.ts";

function RecentRow() {
  const shown = recent.value.map((k) => byKey.value.get(k)).filter((a) => a != null);
  return (
    <div class="strip">
      {shown.map((app) => (
        <AppCell key={app.key} app={app} labels={false} />
      ))}
    </div>
  );
}

/** The dock: pinned apps, always there under the bar. Empty, it says how to fill it - while the drawer is open. */
function Dock() {
  const pinned = dock.value.map((k) => byKey.value.get(k)).filter((a) => a != null);
  if (!pinned.length) return drawer.value > 0 ? <div class="dock-hint muted">long-press an app › pin to dock</div> : null;
  return (
    <div class="dock tile">
      {pinned.map((app) => (
        <AppCell key={app.key} app={app} labels={false} />
      ))}
    </div>
  );
}

export function Home() {
  const p = drawerShown();
  const dragging = drawerDrag.value != null;
  return (
    // --p on home itself: the panel and the dock under the bar both follow it.
    <div class={`home ${dragging ? "dragging" : ""} ${p > 0 ? "open" : ""}`} style={{ "--p": p }} {...homeGestures()}>
      <div class="stage">
        <div class="home-content">
          <Pages />
        </div>
        <div class="launcher-frame tile" />
        <div class="launcher">
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
