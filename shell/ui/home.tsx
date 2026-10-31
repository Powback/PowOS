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
import type { PageRect } from "../types.ts";
import { AppCell, AppMenu } from "./apps.tsx";
import { Bar } from "./bar.tsx";
import { DockSearchBar, DockSearchButton, dockButton, dockSearch } from "./docksearch.tsx";
import { drawerDragging, drawerOpen, followOpenness, homeGestures, launcherTakesHome, pageDrag, shadeTakesHome } from "./gesture.ts";
import { PageDots } from "./pagedots.tsx";
import { Carried, Folders, Pages, startCarry } from "./grid.tsx";
import { buttonSlot, carriedApp, shownLess, slotPast } from "./dockdrop.ts";
import { ScreenPanel } from "./screen.tsx";
import { SessionScreen } from "./session.tsx";
import { AppScreen } from "./appscreen.tsx";
import { RemoteScreen } from "./remote.tsx";
import { GlassesScreen } from "./glasses.tsx";
import { AgentsScreen } from "./agents.tsx";
import { Screens } from "./screens.tsx";
import { EditSheet } from "./editsheet.tsx";
import { PowAiPage } from "./powai.tsx";
import { Pet } from "./pet.tsx";
import { markClass, pageFocus } from "./pagemarks.ts";
import { Recents } from "./recents.tsx";
import { appOf, dockTap } from "./desktops.ts";
import { overWindows } from "./panellift.ts";
import { footBelow, searchClasses } from "./searchwidget.tsx";
import { wideHome } from "../hosts/wide.ts";
import { webWins } from "./webwindows.tsx";
import { byKey, carry, dock, dockPosition, dockAim, dockDrag, drawer, editing, folder, menu, page, pageCount, pullPanels, recent, screen, selected, sessionView, setDock, windows } from "../state.ts";
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
const dockElement = signal<HTMLElement | null>(null);

/** The screen less its top and bottom edge strips (24 px at least, the status bar / gesture insets where taller). */
export function fullScreenAppRegion(): PageRect {
  const css = getComputedStyle(document.documentElement);
  const inset = (name: string) => parseFloat(css.getPropertyValue(name)) || 0;
  const top = Math.max(24, inset("--inset-top"));
  const bottom = Math.max(24, inset("--inset-bottom"));
  return { left: 0, top, width: innerWidth, height: Math.max(0, innerHeight - top - bottom) };
}

function pageRect(r: DOMRect): PageRect {
  return { left: r.left, top: r.top, width: r.width, height: r.height };
}

/** Whether [el] scrolls along y (or x) and has more to show that way. */
function scrolls(el: Element): boolean {
  const up = el.scrollHeight > el.clientHeight + 1;
  const side = el.scrollWidth > el.clientWidth + 1;
  if (!up && !side) return false;
  const s = getComputedStyle(el);
  return (up && /auto|scroll/.test(s.overflowY)) || (side && /auto|scroll/.test(s.overflowX));
}

/**
 * Spec G-R: a drag that starts on a strip that scrolls is the strip's - never the shade's pull down nor the launcher's
 * swipe up. Every such region of home: the dock wherever it sits (bottom row, or the side column of `.home.dock-right`
 * / `.dock-left` with its recents, which scrolls up and down), its own scrollers, and each widget list that scrolls.
 * Home's pager and anything near screen-sized are left out: they're the empty home the pulls start from. The user,
 * 2026-10-29: "Trying to scroll the recent bar triggers the notification center or the launcher."
 */
/** A web window's resize zones reach this far outside its frame (screen px: the corners', shell.css .ww-edge). */
const WINDOW_ZONE = 48;

function claimFree(dockNode: HTMLElement | null): PageRect[] {
  const out: PageRect[] = [];
  const big = innerWidth * innerHeight * 0.5;
  const add = (el: Element) => {
    const r = el.getBoundingClientRect();
    if (r.width > 0 && r.height > 0 && r.width * r.height < big) out.push(pageRect(r));
  };
  if (dockNode) {
    add(dockNode);
    dockNode.querySelectorAll(".dock-pages, .dock-recent").forEach(add);
  }
  const home = document.querySelector(".home");
  home?.querySelectorAll("*").forEach((el) => {
    if (!dockNode?.contains(el) && scrolls(el)) add(el);
  });
  // A web window (ui/webwindows.tsx) whole - title bar, body, edges - whatever its size: dragging it moves the window,
  // and its body is the app's, never a pull (the user, 2026-10-30: "when i try to move the window it moves the whole page").
  // RZ5: with its resize zones outside the frame (32 dp edges, 48 dp corners: the rect grown by the corners'), kept out
  // of the status strip and the bottom gesture area - those stay the system's.
  const app = fullScreenAppRegion();
  document.querySelectorAll(".page:not(.away) .webwindow").forEach((el) => {
    const r = el.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) return;
    const top = Math.max(app.top, r.top - WINDOW_ZONE);
    const bottom = Math.min(app.top + app.height, r.bottom + WINDOW_ZONE);
    const left = Math.max(0, r.left - WINDOW_ZONE);
    const right = Math.min(innerWidth, r.right + WINDOW_ZONE);
    if (bottom > top && right > left) out.push({ left, top, width: right - left, height: bottom - top });
  });
  // FL4: a full-screen Linux window (over all of home, no element on the page) is the app's everywhere but the edge
  // strips: the shade's pull only from the top strip, home / the launcher only from the bottom one.
  if (webWins.value.some((w) => w.full && w.key.startsWith("l:"))) out.push(fullScreenAppRegion());
  return out;
}
function followDock(el: HTMLElement | null) {
  followOpenness(el);
  dockElement.value = el;
}

/** How long a web window holds still before home re-reports its pull regions (see the effect below). */
const REPORT_SETTLE_MS = 120;
let lastWins: unknown;

// Home's page only (app.tsx imports this module in every mode).
if (!new URLSearchParams(location.search).get("mode")) effect(() => {
  const on = homePullOk.value;
  const mainPage = on && page.value === 0;
  pullPanels.value; // Re-report when the pull-up corners change.
  dockPosition.value; // Re-report when placement changes, even if its size stays the same.
  webWins.value; // A web window opened, moved, resized, raised or closed: its region with it (after the render).
  const dockNode = dockElement.value;
  const report = () => {
    const r = dockNode?.getBoundingClientRect();
    const exclude = r ? pageRect(r) : undefined;
    const regions = claimFree(dockNode);
    powos.shade.homePull(on, exclude, mainPage, regions).then(
      (taken) => (shadeTakesHome.value = !!taken),
      () => (shadeTakesHome.value = false),
    );
    // Up is the launcher overlay's, the same way (PullHost.kt): it follows the finger over home.
    const split = pullPanels.value === "on";
    (powos.pull.homePull?.(on, exclude, split, regions) ?? Promise.resolve(false)).then(
      (taken) => (launcherTakesHome.value = !!taken),
      () => (launcherTakesHome.value = false),
    );
  };
  // One report per frame at most, however many observers fire in it (claimFree walks home and reads computed styles:
  // a forced layout, 44 ms in perf-1793396392624). A web window moving or resizing re-runs this effect every pointer
  // step: that report waits until the window holds still (REPORT_SETTLE_MS) - the finger is the window's meanwhile.
  const settling = lastWins !== undefined && lastWins !== webWins.peek();
  lastWins = webWins.peek();
  let frame = 0;
  const soon = () => {
    if (!frame) frame = requestAnimationFrame(() => ((frame = 0), report()));
  };
  const timer = settling ? setTimeout(soon, REPORT_SETTLE_MS) : (soon(), 0);
  const observer = new ResizeObserver(soon);
  if (dockNode) observer.observe(dockNode);
  addEventListener("resize", soon);
  return () => { clearTimeout(timer); cancelAnimationFrame(frame); observer.disconnect(); removeEventListener("resize", soon); };
});

/** How far above the dock a held app has to go to leave it for the home screen. */
const DOCK_EXIT = 48;

/**
 * Held and moved along the dock, a pinned app reorders it (the others make room as it passes); taken up out of it,
 * it's carried like a drawer app (grid.tsx startCarry): let go off the dock it's unpinned (and on home, where there's
 * room), brought back over the dock it goes where it's let go (dockdrop.ts).
 */
function moveInDock(key: string, e: PointerEvent, dockEl: HTMLElement) {
  const vertical = dockPosition.value !== "bottom";
  const axis = (ev: PointerEvent) => vertical ? ev.clientY : ev.clientX;
  // The search button (docksearch.tsx) holds a slot of its own in the dock's middle: the apps' slots skip it.
  const n = dock.value.length;
  const cells = n + (dockButton.value ? 1 : 0);
  const slotOf = (x: number) => {
    const r = dockEl.getBoundingClientRect();
    const slot = vertical ? (x - r.top) / 56 : ((x - r.left) / r.width) * cells;
    return Math.max(0, Math.min(n - 1, slotPast(Math.floor(slot), n)));
  };
  menu.value = null;
  dockDrag.value = { key, x: axis(e), slot: slotOf(axis(e)) };
  const done = () => {
    window.removeEventListener("pointermove", move);
    window.removeEventListener("pointerup", up);
    window.removeEventListener("pointercancel", cancel);
  };
  const move = (ev: PointerEvent) => {
    if (ev.pointerId !== e.pointerId) return;
    if (outsideDock(dockEl.getBoundingClientRect(), ev)) {
      done();
      dockDrag.value = null;
      return startCarry({ app: key, fromDock: true }, ev, { x: 30, y: 30 });
    }
    const slot = slotOf(axis(ev));
    if (slot !== dockDrag.value?.slot) navigator.vibrate?.(5);
    dockDrag.value = { key, x: axis(ev), slot };
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

function outsideDock(r: DOMRect, e: PointerEvent) {
  if (dockPosition.value === "left") return e.clientX > r.right + DOCK_EXIT;
  if (dockPosition.value === "right") return e.clientX < r.left - DOCK_EXIT;
  return e.clientY < r.top - DOCK_EXIT;
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
      const rect = node.getBoundingClientRect();
      const left = dockPosition.value === "bottom" ? rect.left : rect.top;
      now.set(k, left);
      const from = was.current.get(k);
      // The held one rides the finger (its own transform); a new one just appears.
      if (from == null || from === left || node.classList.contains("lifted")) continue;
      node.animate([{ transform: `translate${dockPosition.value === "bottom" ? "X" : "Y"}(${from - left}px)` }, { transform: "none" }], { duration: 160, easing: "ease-out" });
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
  // An app with a floating window is in the pinned dock already (DockWindows): never twice in the dock.
  const pinned = new Set([...dock.value, ...windowed.value.keys()]);
  const shown = recent.value
    .filter((k) => !pinned.has(k))
    .map((k) => byKey.value.get(k))
    .filter((a) => a != null)
    .slice(0, count);
  return (
    <>
      {shown.map((app) => (
        <AppCell key={app.key} app={app} labels={false} class={markClass(app.key)} draggable onTap={() => dockTap(app.key)} />
      ))}
    </>
  );
}

/**
 * The floating app windows (unfolded home) by the app they're of: app key -> "running" | "minimised" (a dot under its
 * icon; a tap on it brings the window back - the host restores rather than launches, ShellBridge.launch).
 */
// The last value, kept while equal: a new Map on every webWins change re-rendered the dock (and each of its cells)
// on every frame of a web window's move or resize (render scan 10-30), where only a window's place changed.
let lastWindowed = new Map<string, string>();
const windowed = computed(() => {
  const out = new Map<string, string>();
  for (const w of windows.value) {
    const key = appOf(w);
    if (key && byKey.value.has(key) && !out.has(key)) out.set(key, w.minimised ? "minimised" : "running");
  }
  webWindowed(out);
  if (out.size === lastWindowed.size && [...out].every(([k, v]) => lastWindowed.get(k) === v)) return lastWindowed;
  return (lastWindowed = out);
});

/** Web windows (ui/webwindows.tsx) into [out]: a minimised one stays in the dock; its tap brings it back (launch -> openWebWindow). */
function webWindowed(out: Map<string, string>) {
  for (const w of webWins.value) if (byKey.value.has(w.key) && !out.has(w.key)) out.set(w.key, w.minimised ? "minimised" : "running");
}

/** The apps with a floating window that aren't in [pinned]: (key, "running" | "minimised"). */
function windowedOnly(pinned: string[]): [string, string][] {
  return [...windowed.value.entries()].filter(([k]) => !pinned.includes(k) && byKey.value.has(k));
}

/** After the pinned apps: the apps with a floating window that aren't pinned, so every window can be reached. */
function DockWindows({ pinned }: { pinned: string[] }) {
  const shown = windowedOnly(pinned);
  return (
    <>
      {shown.map(([k, state]) => {
        const app = byKey.value.get(k);
        return app && <AppCell key={`w ${k}`} app={app} labels={false} class={`windowed ${state} ${markClass(k)}`} onTap={() => dockTap(k)} />;
      })}
    </>
  );
}

/** The held dock app at app slot [i] of [slots], its finger at [x]: drawn there (the search button's slot skipped). */
function heldStyle(row: HTMLElement, i: number, slots: number, x: number) {
  const vertical = dockPosition.value !== "bottom";
  const r = row.getBoundingClientRect();
  const button = dockButton.value ? 1 : 0;
  const at = button && i >= buttonSlot(slots) ? i + 1 : i;
  const slotCenter = vertical ? r.top + at * 56 + 28 : r.left + ((at + 0.5) * r.width) / (slots + button);
  return { transform: `translate${vertical ? "Y" : "X"}(${x - slotCenter}px)` };
}

/** Which of the dock's pages shows (0 pinned, 1 recent): its dots follow it, told when a scroll ends - never per frame. */
const dockPage = signal(0);

/** Exported for the desktop's home (ui/desktop.tsx): the same dock under its pill. */
export function Dock() {
  const el = useRef<HTMLDivElement>(null);
  const vertical = dockPosition.value !== "bottom";
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
  // Nothing pinned AND no floating window either (not just the one carried out of it): no pinned page, only the drop
  // zone while carrying. A window with nothing pinned (possible with an empty dock, e.g. a fresh install - 2026-10-24
  // emulator FAIL "no dock cell for Calculator") still needs the pinned page: it's the only place DockWindows renders.
  const ghost = !dock.value.some((k) => byKey.value.has(k)) && windowed.value.size === 0;
  // Wide (unfolded), the recent apps are the bar's right end (DockTray): the dock is its pinned apps only.
  const wide = wideHome.value;
  const recents = (!wide || vertical) && recent.value.some((k) => !dock.value.includes(k) && byKey.value.has(k));
  // Home's search as a dock button (docksearch.tsx): the dock is there for it even with nothing pinned.
  const button = dockButton.value;
  if (ghost && !carried && !recents && !button) return null;
  // While an app is carried or moved along it, the dock is its pinned page only.
  const paged = !vertical && recents && !carried && !d && (!ghost || button);
  const slots = pinned.length + (gap >= 0 ? 1 : 0);
  const cells = pinned.map((app, i) => {
    // The held one follows the finger from its new slot; the others have moved aside (a slot each, equal widths).
    const style = d?.key === app.key && el.current ? heldStyle(el.current, i, slots, d.x) : undefined;
    return (
      <AppCell
        key={app.key}
        app={app}
        labels={false}
        class={`${d?.key === app.key ? "lifted" : swapOut === app.key ? "swap-out" : ""} ${windowed.value.has(app.key) ? `windowed ${windowed.value.get(app.key)}` : ""} ${markClass(app.key)}`}
        style={style}
        onDrag={(e) => el.current && moveInDock(app.key, e, el.current)}
        onTap={() => dockTap(app.key)}
      />
    );
  });
  if (gap >= 0) cells.splice(gap, 0, <div key=" gap" class="app dock-gap" />);
  // The centre slot: as many apps left of it as right, an odd one more on the right (the user, 01:26: "3 | 3").
  if (button) cells.splice(buttonSlot(cells.length), 0, <DockSearchButton key=" search" />);
  const r = aim?.swap && el.current?.getBoundingClientRect();
  return (
    <>
      {/*
       * The pinned apps' page, then the recent apps in a row that scrolls on (the browser's own scroll, on the
       * compositor: momentum, snapping only near the two starts). The dots below follow when a scroll settles.
       */}
      <div class={`dock ${ghost && carried ? "dock-ghost" : ""} ${aim ? "aimed" : ""} ${paged ? "paged" : ""} ${pageFocus.value ? "page-focus" : ""}`} data-p ref={followDock}>
        <div class="dock-pages" ref={pagesEl}>
          {(!ghost || carried || button) && (
            <div
              class="dock-page"
              // Wide, the cells share the bar's left end: more than six (the windows' apps after the pinned ones) get
              // narrower slots instead of running on under the pill (shell.css --cells; a Calculator window's icon
              // sat under the pill, its tap opened the drawer: dock-taskbar FAIL 2026-10-23).
              style={{ "--cells": String(slots + (!d && !carried ? windowedOnly(dock.value).length : 0)) }}
              ref={(node) => {
                el.current = node;
              }}
            >
              {ghost && gap < 0 && !button ? <div class="dock-empty">drop here to pin</div> : cells}
              {!d && !carried && <DockWindows pinned={dock.value} />}
            </div>
          )}
          {recents && (paged || (vertical && !carried && !d) || (ghost && !carried)) && (
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

/**
 * The wide screen's bar (unfolded): one row at the foot - the dock's pinned apps on the left, the search pill in the
 * middle, and here on the right the apps opened lately (last first, not the pinned ones), a row that scrolls on with
 * the finger past what fits. It gives way with the dock as the launcher opens (a .dock: the same fade and slide).
 */
export function DockTray() {
  if (dockPosition.value !== "bottom") return null;
  if (!recent.value.some((k) => !dock.value.includes(k) && !windowed.value.has(k) && byKey.value.has(k))) return null;
  return (
    <div class={`dock dock-tray paged ${pageFocus.value ? "page-focus" : ""}`} data-p ref={followOpenness}>
      <div class="dock-pages">
        <div class="dock-page dock-recent">
          <DockRecents count={30} />
        </div>
      </div>
    </div>
  );
}

/**
 * Home's position for its dots (pagedots.tsx): PowOS AI's page first (-1), then home's pages and the app library - as
 * the track and the screens slide (gesture.ts applyTrack), so the dot moves with the finger, not after the settle.
 */
function homeDotsAt(): [number, boolean] {
  const dx = pageDrag.value;
  const at = page.value;
  if (dx == null) return [at + 1, false];
  // Toward PowOS AI's page the whole screen slides; between home's pages, the pages' own width.
  const toAi = at === -1 || (at === 0 && dx > 0);
  const w = (toAi ? null : document.querySelector<HTMLElement>(".pages")?.clientWidth) || innerWidth;
  return [Math.max(0, Math.min(pageCount.value, at + 1 - dx / w)), true];
}

/** Home's page dots: above the foot (the search pill and dock), centred on the pages - never under a side dock. */
function HomeDots() {
  return (
    <div class="home-dots" data-p ref={followOpenness}>
      <PageDots count={pageCount.value + 1} follow={homeDotsAt} />
    </div>
  );
}

/** The foot's pill, or the bar the dock's search button expands into. */
const HomeSearch = () => (dockButton.value ? <DockSearchBar /> : <Bar />);

/** Home's search as the dock's button (docksearch.tsx), and that button expanded. */
const searchDockClasses = () => `${dockButton.value ? "search-dock" : ""} ${dockSearch.value !== "closed" ? "search-open" : ""}`;

export function Home() {
  // data-p: these follow the panel's openness (--p, written by gesture.ts, not through a render).
  return (
    <>
      {/* PowOS AI's page beside home: the two slide as one, so home's bar and dock go with it (gesture.ts applyScreens). */}
      <div class="screens" {...homeGestures()}>
        <PowAiPage />
        <div
          class={`home dock-${dockPosition.value} ${wideHome.value ? "wide" : ""} ${footBelow.value ? "pill-below" : ""} ${searchClasses()} ${drawerDragging.value ? "dragging" : ""} ${drawerOpen.value ? "open" : ""} ${editing.value ? "editing" : ""} ${overWindows.value ? "over-windows" : ""} ${carriedApp(carry.value) ? "carry-app" : ""} ${searchDockClasses()}`}
        >
          <div class="stage">
            <div class="home-content" data-p ref={followOpenness}>
              <Pages />
            </div>
            <HomeDots />
            {/* No launcher here: it's the overlay over home (pull.tsx), as the shade is - one for every way in. */}
          </div>
          {/* Always the foot's pill: the launcher's face - a tap opens the overlay with its search (bar.tsx). With the
              search widget on the grid it's parked (shell.css .search-parked). */}
          {/* Or, as the user picked (Settings > style > home: "search: dock button"), no pill here: the dock's centre
              button, which expands into this bar in place (docksearch.tsx). */}
          <HomeSearch />
          <Dock />
          {wideHome.value && <DockTray />}
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
      {/* An open folder: the tile grows into it, over everything (ui/folderview.tsx). */}
      <Folders />
      <Carried />
    </>
  );
}
