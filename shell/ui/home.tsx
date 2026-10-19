/**
 * Home: the pages and the recent apps strip, the drawer that slides up over them, the bar, and under it the dock -
 * the apps pinned to stay at hand, as on iOS. Swipes follow the finger (gesture.ts).
 */
import { AppCell, AppMenu } from "./apps.tsx";
import { Bar } from "./bar.tsx";
import { Drawer } from "./drawer.tsx";
import { drawerDrag, drawerShown, homeGestures } from "./gesture.ts";
import { Pages } from "./grid.tsx";
import { byKey, dock, drawer, recent } from "../state.ts";

function RecentStrip() {
  const shown = recent.value.map((k) => byKey.value.get(k)).filter((a) => a != null);
  return (
    <div class="strip tile">
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

/** The pages and the strip: they recede as the drawer comes up over them. */
function HomeContent() {
  const p = drawerShown();
  return (
    <div
      class={`home-content ${drawerDrag.value != null ? "dragging" : ""}`}
      style={{ opacity: 1 - p, transform: `scale(${1 - p * 0.04})`, pointerEvents: p > 0 ? "none" : undefined }}
    >
      <Pages />
      <RecentStrip />
    </div>
  );
}

export function Home() {
  return (
    <div class="home" {...homeGestures()}>
      <div class="stage">
        <HomeContent />
        <Drawer />
      </div>
      <Bar />
      <Dock />
      <AppMenu />
    </div>
  );
}
