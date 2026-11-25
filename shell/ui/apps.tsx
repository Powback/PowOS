/**
 * An app: its icon and label; a tap opens it, a long press shows its menu (AppMenu, one for the whole shell, drawn
 * over everything so no scrolling list clips it). In the drawer, holding an app and moving it drags it onto home.
 */
import { tinted } from "./icontint.ts";
import { tick } from "./haptics.ts";
import { placement, shapeOf, type Shape } from "./iconshape.ts";
import { running, runOf } from "./running.ts";
import { badgeOf } from "../apps/badge.ts";
import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";
import { apps, closeDrawer, dock, launch, menu, setDocked, shownHomePage } from "../state.ts";
import { computed, signal } from "@preact/signals";
import { Icon, type IconName } from "./icons.tsx";
import { startCarry } from "./grid.tsx";
import { closeApp, windowsOf } from "./desktops.ts";
import { inLaunchers, toggleLauncher } from "./launchers.tsx";
import { powos } from "../bridge.ts";
import { memo } from "./memo.ts";
import type { App, AppWindow } from "../types.ts";
import { usePresence } from "./reveal.tsx";
import { POW_FOLDER, powGroups } from "./launcherview.ts";
import { addToHome } from "./powtiles.ts";
import { openNewWindow, webWins } from "./webwindows.tsx";

const LONG_PRESS_MS = 420;
const SLOP = 10;

/**
 * Press-and-hold without a move opens the menu; a tap launches. Held and then moved ([onDrag]): the menu gives way to
 * dragging the app. A move before the hold is a scroll or a swipe, not the app's - unless [early] takes it (the dock: a
 * move away from it lifts the app out at once): true taken, undefined not decided yet (kept), false not its.
 */
export function usePress(onTap: () => void, onLong: (el: HTMLElement) => void, onDrag: ((e: PointerEvent) => void) | null, early?: Early) {
  const s = useRef<{ x: number; y: number; long: boolean; timer: number; el: HTMLElement } | null>(null);
  const cancel = () => {
    if (s.current) clearTimeout(s.current.timer);
    s.current = null;
  };
  return {
    onPointerDown: (e: PointerEvent) => {
      if (e.button) return;
      const el = e.currentTarget as HTMLElement;
      const state = { x: e.clientX, y: e.clientY, long: false, timer: 0, el };
      state.timer = window.setTimeout(() => {
        state.long = true;
        tick();
        // Its moves stay its own from here: the menu's scrim comes up under the finger, the app can still be dragged.
        try {
          el.setPointerCapture(e.pointerId);
        } catch {
          // the pointer is gone already
        }
        onLong(el);
      }, LONG_PRESS_MS);
      s.current = state;
    },
    onPointerMove: (e: PointerEvent) => {
      const state = s.current;
      if (!state) return;
      const way = !state.long && early ? early(e, e.clientX - state.x, e.clientY - state.y) : false;
      if (way) return cancel();
      if (way === undefined || Math.hypot(e.clientX - state.x, e.clientY - state.y) <= SLOP) return;
      if (!state.long) return cancel();
      if (onDrag) {
        cancel();
        onDrag(e);
      }
    },
    onPointerUp: (e: PointerEvent) => {
      const state = s.current;
      cancel();
      if (state && !state.long && Math.hypot(e.clientX - state.x, e.clientY - state.y) <= SLOP) onTap();
    },
    onPointerCancel: cancel,
  };
}

/** A move before the hold, [dx], [dy] from the press ([usePress]): true it took the press, undefined not yet, false not its. */
type Early = (e: PointerEvent, dx: number, dy: number) => boolean | undefined;

interface CellProps {
  app: App;
  /** A drawer cell: its name under it, and it can be dragged onto home. */
  labels?: boolean;
  draggable?: boolean;
  /** Held and moved: this instead of dragging it onto home (the dock reorders its own). */
  onDrag?: (e: PointerEvent, el: HTMLElement, app: App) => void;
  /** A move before the hold ([Early], with the app: one stable handler for all cells): the dock lifts its app out on a move away from it. */
  onMove?: (e: PointerEvent, dx: number, dy: number, app: App) => boolean | undefined;
  class?: string;
  style?: Record<string, string>;
  /** A tap: this instead of launching it (the dock's taskbar taps, ui/desktops.ts dockTap). */
  onTap?: (app: App) => void;
}

/**
 * Holding [key] and moving: the menu gives way, the launcher closes, and the app follows the finger - onto home, or over
 * an app into a window or a half, as a dock app does (state.ts Carry.toWindow, dockout.tsx). THE launcher drag: every
 * launcher tile (AppCell draggable) and search's app rows (drawer.tsx AppResultRow) start it, none has its own.
 */
export function dragHome(key: string, e: PointerEvent) {
  menu.value = null;
  closeDrawer();
  // The Pow folder is no app to open in a window: home or the dock only.
  startCarry({ app: key, toWindow: key !== POW_FOLDER }, e, { x: 30, y: 30 });
}

/**
 * Memoised: [onTap] / [onDrag] take the app, so a parent passes one stable handler for all its cells (never a closure per
 * render - a new one each dock render re-rendered every cell, 152x in perf-1793456386286).
 */
export const AppCell = memo(function AppCell({ app, labels = true, draggable = false, onDrag, onMove, class: cls = "", style, onTap }: CellProps) {
  const press = usePress(
    onTap ? () => onTap(app) : () => launch(app.key),
    (el) => (menu.value = { app, at: el.getBoundingClientRect() }),
    onDrag ? (e) => onDrag(e, e.currentTarget as HTMLElement, app) : draggable ? (e) => dragHome(app.key, e) : null,
    onMove && ((e, dx, dy) => onMove(e, dx, dy, app)),
  );
  return (
    <div class={`app ${cls}`} style={style} data-key={app.key} data-run={runOf(app.key).value} {...press}>
      <AppIcon src={app.icon} label={app.label} app={app.key} />
      {labels && <div class="app-label">{app.label}</div>}
    </div>
  );
});

/**
 * How long an icon URL that failed may stay unanswered before the app gets its initial instead. The host draws icons
 * in the background and sends the list again (a new URL) when one is in - well within this on the phone.
 */
const ICON_GIVE_UP_MS = 4000;

/**
 * An app's icon. One the page has already (the WebView keeps each icon's file - its URL names its pixels, ShellIcons)
 * shows in the first frame, as it is; only one still on its way is a softly pulsing tile until the picture is in.
 * The host draws icons in the background, so an icon asked for early may not be there yet (a 404); the list comes
 * again when it is (its URL changes), and loads it then. One that fails and stays failed (no new URL within
 * ICON_GIVE_UP_MS) ends as the app's initial, never as a tile loading forever; a new URL tries the picture again.
 * [app] (its launcher key): the app's unread dot over the corner while its count is above 0 (host.badge, apps/badge.ts).
 */
export function AppIcon(props: { src: string; label?: string; app?: string }) {
  return props.app === POW_FOLDER ? <PowFolderIcon /> : <AppImage {...props} />;
}

const collator = new Intl.Collator(undefined, { sensitivity: "base", numeric: true });
/** The Pow folder's first four apps, in the folder's order (launcherview.ts powGroups): its icon's minis. */
const powMinis = computed(() => powGroups(apps.value, collator.compare).flatMap((g) => g.apps).slice(0, 4));

/**
 * The Pow folder's icon (launcherview.ts POW_FOLDER), wherever an app icon goes - the launcher, the dock, a home tile,
 * a carried ghost: its first four apps small on the icon plate, as a folder shows them, and PowOS's mark on the corner
 * where a web app's kind mark sits. Static.
 */
function PowFolderIcon() {
  return (
    <span class="app-icon pow-folder">
      <span class="app-icon-face pow-face">
        {powMinis.value.map((a) => (
          <img key={a.key} src={a.icon} alt="" draggable={false} onError={(e) => ((e.currentTarget as HTMLImageElement).style.visibility = "hidden")} />
        ))}
      </span>
      <img class="pow-mark" src="./icons/powos.svg" alt="" draggable={false} />
    </span>
  );
}

function AppImage({ src, label, app }: { src: string; label?: string; app?: string }) {
  const [missing, setMissing] = useState(false);
  // In the theme's colours when that's on and its copy is made (ui/icontint.ts), else as the app draws it.
  const shown = tinted(src) ?? src;
  // In the one shape at the one visual size (ui/iconshape.ts): placed in the squircle face, on the plate if it needs one.
  const shape = shapeOf(src);
  const timer = useRef(0);
  const img = useRef<HTMLImageElement>(null);
  useEffect(() => {
    setMissing(false);
    return () => clearTimeout(timer.current);
  }, [src]);
  // Before the frame is drawn: an image not decoded yet gets the pulsing tile - one that is shows as it is, with no
  // fade-in (a page reload, home recreated, a fold: every icon is in the WebView's cache by then).
  useLayoutEffect(() => {
    const i = img.current;
    if (i && !(i.complete && i.naturalWidth)) i.closest(".app-icon")!.classList.add("loading");
  }, [src]);
  return (
    <span class={`${missing ? "app-icon initials" : "app-icon"}${offlineWeb(app) ? " offline" : ""}`}>
      {missing && (label ?? "?")[0]}
      <span class={faceClass(shape, missing)}>
      <img
        ref={img}
        src={shown}
        alt=""
        draggable={false}
        decoding="sync"
        style={missing ? { display: "none" } : placement(shape)}
        onLoad={(e) => {
          clearTimeout(timer.current);
          setMissing(false);
          e.currentTarget.closest(".app-icon")!.classList.remove("loading");
        }}
        onError={(e) => {
          e.currentTarget.closest(".app-icon")!.classList.add("loading");
          // HACK: a 404 can't tell "not drawn yet" from "this app has no icon", so a failure that lasts is taken as
          // the latter. Real fix: the host sends icon: null for an app whose lookup failed (ShellBridge.apps(), with
          // Runtime.refreshApps recording the failures) - not done here while ShellBridge has another change in flight.
          // On PowOS (rooted) powos-apps-export now draws every app a picture, so this is only the backstop.
          clearTimeout(timer.current);
          timer.current = window.setTimeout(() => setMissing(true), ICON_GIVE_UP_MS);
        }}
      />
      </span>
      {badgeOf(app) > 0 && <span class="app-badge" />}
      <WebMarkChip app={app} />
    </span>
  );
}

/** The .pow web apps by launcher key: what their icon's mark says ([WebMark]), looked up per icon without a scan. */
const webApps = computed(() => {
  const m = new Map<string, App>();
  for (const a of apps.value) if (a.kind === "web") m.set(a.key, a);
  return m;
});

/**
 * What a .pow web app is (the user 11-23: "some indicator of whether its pwa or whatever"), as a small mark on its
 * icon's lower corner and a line in its menu: an installable PWA, a plain web page, a sleeping service (wakes on open,
 * the first open takes longer), or - over all three - not reachable right now (off the home network/VPN).
 */
const WEB_MARKS: Record<WebMark, { icon: IconName; says: string }> = {
  pwa: { icon: "apps", says: "Web app" },
  page: { icon: "web", says: "Web page" },
  sleeps: { icon: "moonWaningCrescent", says: "Sleeping service: wakes when opened, the first open takes longer" },
  offline: { icon: "wifiOff", says: "Not reachable right now: off your home network or VPN" },
};
type WebMark = "pwa" | "page" | "sleeps" | "offline";

const webMark = (a: App): WebMark => (a.offline ? "offline" : a.web ?? "page");

/** [app] (a launcher key) is a web app whose catalog didn't answer on the last try. */
const offlineWeb = (app?: string) => !!app && !!webApps.value.get(app)?.offline;

/** The mark on a web app's icon (nothing for any other app). */
function WebMarkChip({ app }: { app?: string }) {
  const web = app ? webApps.value.get(app) : undefined;
  if (!web) return null;
  const mark = webMark(web);
  return (
    <span class={`app-web-mark web-${mark}`}>
      <Icon name={WEB_MARKS[mark].icon} />
    </span>
  );
}

/** A web app's menu line: what kind it is, where it lives (its host), its category when it has one. */
export function webInfo(a: App): string {
  const host = a.key.slice(2);
  return [WEB_MARKS[webMark(a)].says, host, a.webCategory].filter(Boolean).join(" · ");
}

/** The face's classes: placed by its measure, on the plate when it needs one (ui/iconshape.ts). */
const faceClass = (shape: Shape | null | undefined, missing: boolean) =>
  `app-icon-face${shape ? " placed" : ""}${shape?.kind === "plate" && !missing ? " plate" : ""}`;

type Item = [string, () => void];

/**
 * A running app's window actions, first in its menu: close (the app ended: closeApp), minimise or restore its top-most
 * window, and with two or more windows each of them, a tap bringing it to the front (the host's restore).
 */
function windowItems(key: string): Item[] {
  const wins = windowsOf(key);
  if (!running.value[key] && !wins.length) return [];
  return [["close", () => void closeApp(key)], ...stateItem(wins[0]), ...(wins.length > 1 ? listItems(wins) : [])];
}

/** Restore for a window out of sight (minimised, on another page), else minimise; none without a window. */
function stateItem(w: AppWindow | undefined): Item[] {
  const f = powos.floating;
  if (!f || !w) return [];
  if (w.minimised || w.away) return [["restore", () => void f.restore(w.id)]];
  return f.minimise ? [["minimise", () => void f.minimise!(w.id)]] : [];
}

/** Each window by its name (numbered when two share one); a tap brings it to the front. */
function listItems(wins: AppWindow[]): Item[] {
  const seen: Record<string, number> = {};
  return wins.map((w) => {
    const n = (seen[w.label] = (seen[w.label] ?? 0) + 1);
    return [n > 1 ? `${w.label} ${n}` : w.label, () => void powos.floating?.restore(w.id)];
  });
}

/**
 * "new window" for an app with a web window here (the user 11-03: "if I want to open up another chrome instance on this
 * page I could"): a second instance on the page on screen, as the dock's drag-out (a tap fronts the one it has).
 */
function newWindowItem(app: App): Item[] {
  if (!webWins.value.some((w) => w.key === app.key && !w.failed)) return [];
  return [["new window", () => void shownHomePage().then((p) => openNewWindow(app.key, app.label, p))]];
}

/**
 * What each web app was allowed (the host's WebAppPermissions: microphone, camera, location, midi), read when its menu
 * opens. An older APK has no call: no lines.
 */
const webGrants = signal<Record<string, string[]>>({});

async function loadGrants(key: string) {
  const read = powos.apps.permissions;
  if (!read) return;
  const kinds = await read(key).catch(() => [] as string[]);
  webGrants.value = { ...webGrants.value, [key]: kinds };
}

/** A web app's site permissions, one line each: tapping it takes that one back (the site asks again next time). */
function grantItems(app: App): Item[] {
  if (app.kind !== "web" || !powos.apps.revoke) return [];
  return (webGrants.value[app.key] ?? []).map((kind) => [
    `revoke ${kind}`,
    () => void powos.apps.revoke!(app.key, kind).then(() => loadGrants(app.key)),
  ]);
}

/** What the app menu offers for [app]. */
function menuItems(app: App): Item[] {
  const docked = dock.value.includes(app.key);
  const home: Item = ["add to home", () => shownHomePage().then((p) => addToHome(app.key, p))];
  // The Pow folder: where it sits, nothing else (it isn't an app to close, window or remove).
  if (app.key === POW_FOLDER) return [[docked ? "unpin from dock" : "pin to dock", () => setDocked(app.key, !docked)], home];
  const quick = inLaunchers(app.key);
  const android = app.kind === "android";
  return [
    ...windowItems(app.key),
    ...newWindowItem(app),
    [docked ? "unpin from dock" : "pin to dock", () => setDocked(app.key, !docked)],
    // The control center's quick-launch row, at its end (launchers.tsx: the row's own add/remove).
    [quick ? "remove from quick launch" : "add to quick launch", () => void toggleLauncher(app.key)],
    // On the page home shows (also from the launcher overlay's own page: state.ts shownHomePage), in its first free cell.
    // A web app as its shell tile (powtiles.ts: ShellHome pins Android/Linux shortcuts only).
    home,
    ...(android ? ([["app info", () => powos.apps.info(app.key)]] as Item[]) : []),
    ...(android && !app.system ? ([["uninstall", () => powos.apps.uninstall(app.key)]] as Item[]) : []),
    // A .pow web app (issue #8): only its launcher entry goes, and the catalog sync leaves it out from then on (PowApps
    // installs it again); the service itself is untouched.
    ...grantItems(app),
    ...(app.kind === "web" ? ([["remove from launcher", () => powos.apps.uninstall(app.key)]] as Item[]) : []),
  ];
}

/** The menu open now, or the one leaving (kept with what it was opened on while it leaves), and whether it's leaving. */
function useMenuPresence() {
  const open = menu.value;
  const pop = usePresence(open != null);
  const last = useRef(open);
  if (open) last.current = open;
  return { m: open ?? (pop.on ? last.current : null), leaving: pop.leaving };
}

/**
 * The open app menu, under (or, near the bottom, over) the app it belongs to - kept while it leaves on the spring (§6:
 * it vanished in one frame), as the switcher's card menu does (recents.tsx Menu).
 */
export function AppMenu() {
  const { m, leaving } = useMenuPresence();
  const webKey = m?.app.kind === "web" ? m.app.key : null;
  useEffect(() => {
    if (webKey && !leaving) void loadGrants(webKey);
  }, [webKey, leaving]);
  if (!m) return null;
  const { app, at } = m;
  const items = menuItems(app);
  const below = at.bottom + 48 * items.length + 16 < innerHeight;
  const left = Math.max(8, Math.min(innerWidth - 188, at.left + at.width / 2 - 90));
  const close = () => (menu.value = null);
  return (
    <>
      {!leaving && <div class="menu-scrim" onPointerDown={close} />}
      <div class={`menu tile sheet pop${leaving ? " leaving" : ""}`} inert={leaving || undefined} style={{ left: `${left}px`, ...(below ? { top: `${at.bottom + 4}px` } : { bottom: `${innerHeight - at.top + 4}px` }) }}>
        <div class="menu-title">{app.label}</div>
        {app.kind === "web" && <div class="menu-sub">{webInfo(app)}</div>}
        {items.map(([label, run]) => (
          <button
            class="menu-item"
            onClick={() => {
              close();
              run();
            }}
          >
            {label}
          </button>
        ))}
      </div>
    </>
  );
}
