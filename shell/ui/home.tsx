/**
 * Home: the pages; the launcher panel - the recent apps bar, which a swipe up grows into the drawer: the recent row
 * rides the top edge as it follows the finger, and all the apps unfold under it - one component, the bar is the
 * launcher's head; the search bar; and under it the dock, the apps pinned to stay at hand (as on iOS).
 *
 * The panel's openness (gesture.ts) is one number, --p, on the stage: the frame's top edge and the clip that reveals
 * the drawer move with it in CSS, so a frame of the swipe moves an edge, not a re-laid-out list of apps.
 */
import { WidgetSheet } from "./widgetsheet.tsx";
import { useEffect, useLayoutEffect, useRef } from "preact/hooks";
import { computed, effect, signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import { AppCell, AppMenu } from "./apps.tsx";
import { Bar } from "./bar.tsx";
import { Drawer } from "./drawer.tsx";
import { drawerDragging, drawerOpen, followOpenness, homeGestures, shadeTakesHome } from "./gesture.ts";
import { Carried, Pages, startCarry } from "./grid.tsx";
import { carriedApp, shownLess } from "./dockdrop.ts";
import { ScreenPanel } from "./screen.tsx";
import { SessionScreen } from "./session.tsx";
import { AppScreen } from "./appscreen.tsx";
import { RemoteScreen } from "./remote.tsx";
import { GlassesScreen } from "./glasses.tsx";
import { AgentsScreen } from "./agents.tsx";
import { Screens } from "./screens.tsx";
import { EditSheet } from "./editsheet.tsx";
import { AiContent, AiHeader, PowAiPage } from "./powai.tsx";
import { Pet } from "./pet.tsx";
import { Recents } from "./recents.tsx";
import { footBelow, hasSearchWidget } from "./searchwidget.tsx";
import { byKey, carry, dock, dockAim, dockDrag, drawer, editing, folder, menu, page, pullKind, recent, screen, selected, sessionView, setDock, windows } from "../state.ts";
import { screens } from "../screens.ts";
import { appView } from "../apps/pages.ts";
import { remoteOpen } from "../remote.ts";
import { glassesOpen } from "../glasses/open.ts";
import { agentsView } from "../agents.ts";

/**
 * A pull down on home is the system shade's (ShadeHost, the same window, pull and blur as over an app): home has no
 * notification panel of its own. While nothing is open over home's pages - and it isn't PowOS AI's page, whose up and
 * down are its own - the host takes a finger dragged down anywhere on home ("shade.homePull"); otherwise home keeps it.
 */
const homePullOk = computed(
  () =>
    page.value >= 0 &&
    drawer.value === 0 &&
    !drawerOpen.value &&
    !editing.value &&
    !menu.value &&
    !folder.value &&
    !selected.value &&
    !carry.value &&
    !screen.value.key &&
    !sessionView.value &&
    !appView.value &&
    !remoteOpen.value &&
    !glassesOpen.value &&
    !agentsView.value &&
    screens.value.length === 0,
);
// Home's page only (app.tsx imports this module in every mode).
if (!new URLSearchParams(location.search).get("mode")) effect(() => {
  const on = homePullOk.value;
  powos.shade.homePull(on).then(
    (taken) => (shadeTakesHome.value = !!taken),
    () => (shadeTakesHome.value = false),
  );
});

/** How far above the dock a held app has to go to leave it for the home screen. */
const DOCK_EXIT = 48;

/**
 * Held and moved along the dock, a pinned app reorders it (the others make room as it passes); taken up out of it,
 * it's carried like a drawer app (grid.tsx startCarry): let go off the dock it's unpinned (and on home, where there's
 * room), brought back over the dock it goes where it's let go (dockdrop.ts).
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
      return startCarry({ app: key, fromDock: true }, ev, { x: 30, y: 30 });
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
    if (d) {
      navigator.vibrate?.(10);
      setDock(order(d.key, d.slot));
    }
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

/**
 * The dock's icons glide to their new places when the row changes under a finger (one making room, one leaving):
 * each is drawn where it was and eased to where it is now.
 */
function useGlide(el: { current: HTMLDivElement | null }, keys: string) {
  const was = useRef(new Map<string, number>());
  useLayoutEffect(() => {
    const now = new Map<string, number>();
    for (const node of el.current?.querySelectorAll<HTMLElement>(".app[data-key]") ?? []) {
      const k = node.dataset.key!;
      const left = node.getBoundingClientRect().left;
      now.set(k, left);
      const from = was.current.get(k);
      // The held one rides the finger (its own transform); a new one just appears.
      if (from == null || from === left || node.classList.contains("lifted")) continue;
      node.animate([{ transform: `translateX(${from - left}px)` }, { transform: "none" }], { duration: 160, easing: "ease-out" });
    }
    was.current = now;
  }, [keys]);
}

/**
 * The dock: pinned apps under the bar, folding away while the launcher is open (shell.css). An app carried over it
 * (dockdrop.ts) opens a gap where it would go - or, the dock full, marks the app it would swap out; one carried out of
 * it leaves no gap. With nothing pinned it's only there while an app is carried: a drop zone over the bar's foot.
 */
/**
 * After the dock's pinned page: the apps opened lately, last first, not those pinned (they're on the first) - all of
 * them in a row that scrolls on with the finger (momentum, the browser's own), past what a page holds.
 */
function DockRecents({ count }: { count: number }) {
  const pinned = new Set(dock.value);
  const shown = recent.value
    .filter((k) => !pinned.has(k))
    .map((k) => byKey.value.get(k))
    .filter((a) => a != null)
    .slice(0, count);
  return (
    <>
      {shown.map((app) => (
        <AppCell key={app.key} app={app} labels={false} draggable />
      ))}
    </>
  );
}

/**
 * The floating app windows (unfolded home) by the app they're of: app key -> "running" | "minimised" (a dot under its
 * icon; a tap on it brings the window back - the host restores rather than launches, ShellBridge.launch).
 */
const windowed = computed(() => {
  const out = new Map<string, string>();
  for (const w of windows.value) {
    const key = [...byKey.value.keys()].find((k) => k.startsWith(`a:${w.pkg}/`));
    if (key && !out.has(key)) out.set(key, w.minimised ? "minimised" : "running");
  }
  return out;
});

/** After the pinned apps: the apps with a floating window that aren't pinned, so every window can be reached. */
function DockWindows({ pinned }: { pinned: string[] }) {
  const shown = [...windowed.value.entries()].filter(([k]) => !pinned.includes(k));
  return (
    <>
      {shown.map(([k, state]) => {
        const app = byKey.value.get(k);
        return app && <AppCell key={`w ${k}`} app={app} labels={false} class={`windowed ${state}`} />;
      })}
    </>
  );
}

/** Which of the dock's pages shows (0 pinned, 1 recent): its dots follow it, told when a scroll ends - never per frame. */
const dockPage = signal(0);

/** Exported for the desktop's home (ui/desktop.tsx): the same dock under its pill. */
export function Dock() {
  const el = useRef<HTMLDivElement>(null);
  const d = dockDrag.value;
  const aim = dockAim.value;
  const c = carry.value;
  const carried = carriedApp(c);
  // The order shown: moved along the dock; with a carried app's gap (or its swap); or less the one carried out of it.
  let keys = d ? order(d.key, d.slot) : dock.value;
  let gap = -1;
  if (aim && !aim.swap) {
    keys = shownLess(aim.key);
    gap = aim.slot;
  } else if (c?.fromDock && c.app) keys = shownLess(c.app);
  const pinned = keys.map((k) => byKey.value.get(k)).filter((a) => a != null);
  const swapOut = aim?.swap ? pinned[aim.slot]?.key : undefined;
  useGlide(el, `${pinned.map((a) => a.key).join()}|${gap}`);
  // The page the dock settled on, once a swipe's scroll has ended (scrollend: no work while it moves).
  const pagesEl = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const node = pagesEl.current;
    if (!node) return;
    // Anywhere in the recent apps (they scroll on past a page) is the second dot.
    const settle = () => (dockPage.value = Math.min(1, Math.round(node.scrollLeft / Math.max(1, node.clientWidth))));
    node.addEventListener("scrollend", settle);
    return () => node.removeEventListener("scrollend", settle);
  });
  // Nothing pinned at all (not just the one carried out of it): no pinned page, only the drop zone while carrying.
  const ghost = !dock.value.some((k) => byKey.value.has(k));
  const recents = recent.value.some((k) => !dock.value.includes(k) && byKey.value.has(k));
  if (ghost && !carried && !recents) return null;
  // While an app is carried or moved along it, the dock is its pinned page only.
  const paged = recents && !carried && !d && !ghost;
  const slots = pinned.length + (gap >= 0 ? 1 : 0);
  const cells = pinned.map((app, i) => {
    // The held one follows the finger from its new slot; the others have moved aside (a slot each, equal widths).
    let style: Record<string, string> | undefined;
    if (d?.key === app.key && el.current) {
      const r = el.current.getBoundingClientRect();
      const slotCenter = r.left + ((i + 0.5) * r.width) / slots;
      style = { transform: `translateX(${d.x - slotCenter}px)` };
    }
    return (
      <AppCell
        key={app.key}
        app={app}
        labels={false}
        class={`${d?.key === app.key ? "lifted" : swapOut === app.key ? "swap-out" : ""} ${windowed.value.has(app.key) ? `windowed ${windowed.value.get(app.key)}` : ""}`}
        style={style}
        onDrag={(e) => el.current && moveInDock(app.key, e, el.current)}
      />
    );
  });
  if (gap >= 0) cells.splice(gap, 0, <div key=" gap" class="app dock-gap" />);
  const r = aim?.swap && el.current?.getBoundingClientRect();
  return (
    <>
      {/*
       * The pinned apps' page, then the recent apps in a row that scrolls on (the browser's own scroll, on the
       * compositor: momentum, snapping only near the two starts). The dots below follow when a scroll settles.
       */}
      <div class={`dock ${ghost && carried ? "dock-ghost" : ""} ${aim ? "aimed" : ""} ${paged ? "paged" : ""}`} data-p ref={followOpenness}>
        <div class="dock-pages" ref={pagesEl}>
          {(!ghost || carried) && (
            <div
              class="dock-page"
              ref={(node) => {
                el.current = node;
              }}
            >
              {ghost && gap < 0 ? <div class="dock-empty">drop here to pin</div> : cells}
              {!d && !carried && <DockWindows pinned={dock.value} />}
            </div>
          )}
          {(paged || (ghost && !carried)) && (
            <div class="dock-page dock-recent">
              <DockRecents count={30} />
            </div>
          )}
        </div>
        {paged && (
          <div class="dock-dots">
            <i class={dockPage.value === 0 ? "on" : ""} />
            <i class={dockPage.value === 1 ? "on" : ""} />
          </div>
        )}
      </div>
      {r && (
        <div class="dock-hint tile" style={{ bottom: `${innerHeight - r.top + 6}px` }}>
          dock full - drop to swap
        </div>
      )}
    </>
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
          class={`home ${footBelow.value ? "pill-below" : ""} ${drawerDragging.value ? "dragging" : ""} ${drawerOpen.value ? "open" : ""} ${editing.value ? "editing" : ""} ${carriedApp(carry.value) ? "carry-app" : ""}`}
        >
          <div class="stage">
            <div class="home-content" data-p ref={followOpenness}>
              <Pages />
            </div>
            <div class="launcher-frame tile" data-p ref={followOpenness} />
            <div class="launcher-clip" data-p ref={followOpenness}>
              <div class="launcher" data-p ref={followOpenness}>
                <div class="launcher-inner">
                  <div class="drawer-clip">
                    {pullKind.value === "ai" ? (
                      <div class="ai-panel">
                        <AiHeader />
                        <AiContent shown={drawerOpen.value} />
                      </div>
                    ) : (
                      <Drawer />
                    )}
                  </div>
                </div>
              </div>
            </div>
          </div>
          {!hasSearchWidget() && <Bar />}
          <Dock />
          <AppMenu />
          <EditSheet />
        </div>
      </div>
      {/* The pet (the agents' face): over home and PowOS AI's page, outside their swipes; the screens below cover it. */}
      <Pet />
      {/* Outside home: its touches never reach home's swipes. */}
      <ScreenPanel />
      <SessionScreen />
      <AppScreen />
      <RemoteScreen />
      <GlassesScreen />
      <AgentsScreen />
      <Screens />
      {/* A widget's detail sheet (an island's long-pressed control): over home, its scrim taking the touches outside it. */}
      <WidgetSheet />
      {/* The switcher: a layer over all of home (a swipe up over an app builds it; the overview button shows it). */}
      <Recents />
      {/* A tile or app carried by a finger, over everything it can be dropped on (the pages, the dock). */}
      <Carried />
    </>
  );
}
