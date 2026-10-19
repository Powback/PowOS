/**
 * Home: the pages; the launcher panel - the recent apps bar, which a swipe up grows into the drawer: the recent row
 * rides the top edge as it follows the finger, and all the apps unfold under it - one component, the bar is the
 * launcher's head; the search bar; and under it the dock, the apps pinned to stay at hand (as on iOS).
 *
 * The panel's openness (gesture.ts) is one number, --p, on the stage: the frame's top edge and the clip that reveals
 * the drawer move with it in CSS, so a frame of the swipe moves an edge, not a re-laid-out list of apps.
 */
import { useEffect, useRef } from "preact/hooks";
import { AppCell, AppMenu, dragHome } from "./apps.tsx";
import { Bar } from "./bar.tsx";
import { Drawer } from "./drawer.tsx";
import { drawerDragging, drawerOpen, followOpenness, homeGestures } from "./gesture.ts";
import { Pages } from "./grid.tsx";
import { ScreenPanel } from "./screen.tsx";
import { SessionScreen } from "./session.tsx";
import { RemoteScreen } from "./remote.tsx";
import { AgentsScreen } from "./agents.tsx";
import { Screens } from "./screens.tsx";
import { EditSheet } from "./editsheet.tsx";
import { NotificationPanel } from "./notifications.tsx";
import { PowAiPage } from "./powai.tsx";
import { byKey, dock, dockDrag, editing, menu, recent, setDock } from "../state.ts";

/**
 * The apps opened lately, last first - not those pinned to the dock, which are at hand already. Six to a width, the
 * rest a sideways scroll away; back at the newest whenever the list changes.
 */
function RecentRow() {
  const row = useRef<HTMLDivElement>(null);
  const pinned = new Set(dock.value);
  const shown = recent.value
    .filter((k) => !pinned.has(k))
    .map((k) => byKey.value.get(k))
    .filter((a) => a != null);
  const first = shown[0]?.key;
  useEffect(() => {
    row.current?.scrollTo({ left: 0 });
  }, [first]);
  return (
    <div class="strip" ref={row}>
      {shown.map((app) => (
        <AppCell key={app.key} app={app} labels={false} draggable />
      ))}
    </div>
  );
}

/** How far above the dock a held app has to go to leave it for the home screen. */
const DOCK_EXIT = 48;

/**
 * Held and moved along the dock, a pinned app reorders it (the others make room as it passes); taken up out of it,
 * it's dragged onto home like a drawer app (and stays pinned).
 */
function moveInDock(key: string, e: PointerEvent, dockEl: HTMLElement) {
  const slotOf = (x: number) => {
    const r = dockEl.getBoundingClientRect();
    return Math.max(0, Math.min(dock.value.length - 1, Math.floor(((x - r.left) / r.width) * dock.value.length)));
  };
  menu.value = null;
  dockDrag.value = { key, x: e.clientX, slot: slotOf(e.clientX) };
  const done = () => {
    window.removeEventListener("pointermove", move);
    window.removeEventListener("pointerup", up);
    window.removeEventListener("pointercancel", cancel);
  };
  const move = (ev: PointerEvent) => {
    if (ev.pointerId !== e.pointerId) return;
    if (ev.clientY < dockEl.getBoundingClientRect().top - DOCK_EXIT) {
      done();
      dockDrag.value = null;
      return dragHome(key, ev);
    }
    const slot = slotOf(ev.clientX);
    if (slot !== dockDrag.value?.slot) navigator.vibrate?.(5);
    dockDrag.value = { key, x: ev.clientX, slot };
  };
  const up = (ev: PointerEvent) => {
    if (ev.pointerId !== e.pointerId) return;
    done();
    const d = dockDrag.value;
    dockDrag.value = null;
    if (d) setDock(order(d.key, d.slot));
  };
  const cancel = (ev: PointerEvent) => {
    if (ev.pointerId !== e.pointerId) return;
    done();
    dockDrag.value = null;
  };
  window.addEventListener("pointermove", move);
  window.addEventListener("pointerup", up);
  window.addEventListener("pointercancel", cancel);
}

/** The dock's keys with [key] moved to [slot]. */
function order(key: string, slot: number) {
  const rest = dock.value.filter((k) => k !== key);
  return [...rest.slice(0, slot), key, ...rest.slice(slot)];
}

/** The dock: pinned apps under the bar, folding away while the launcher is open (shell.css). */
function Dock() {
  const el = useRef<HTMLDivElement>(null);
  const d = dockDrag.value;
  const keys = d ? order(d.key, d.slot) : dock.value;
  const pinned = keys.map((k) => byKey.value.get(k)).filter((a) => a != null);
  if (!pinned.length) return null;
  return (
    <div
      class="dock tile"
      data-p
      ref={(node) => {
        el.current = node;
        followOpenness(node);
      }}
    >
      {pinned.map((app, i) => {
        // The held one follows the finger from its new slot; the others have moved aside (a slot each, equal widths).
        let style: Record<string, string> | undefined;
        if (d?.key === app.key && el.current) {
          const r = el.current.getBoundingClientRect();
          const slotCenter = r.left + ((i + 0.5) * r.width) / pinned.length;
          style = { transform: `translateX(${d.x - slotCenter}px)` };
        }
        return (
          <AppCell
            key={app.key}
            app={app}
            labels={false}
            class={d?.key === app.key ? "lifted" : ""}
            style={style}
            onDrag={(e) => el.current && moveInDock(app.key, e, el.current)}
          />
        );
      })}
    </div>
  );
}

export function Home() {
  // data-p: these follow the panel's openness (--p, written by gesture.ts, not through a render).
  return (
    <>
      {/* PowOS AI's page beside home: the two slide as one, so home's bar and dock go with it (gesture.ts applyScreens). */}
      <div class="screens" {...homeGestures()}>
        <PowAiPage />
        <div
          class={`home ${drawerDragging.value ? "dragging" : ""} ${drawerOpen.value ? "open" : ""} ${editing.value ? "editing" : ""}`}
        >
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
          <EditSheet />
          <NotificationPanel />
        </div>
      </div>
      {/* Outside home: its touches never reach home's swipes. */}
      <ScreenPanel />
      <SessionScreen />
      <RemoteScreen />
      <AgentsScreen />
      <Screens />
    </>
  );
}
