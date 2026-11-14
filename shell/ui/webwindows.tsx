// Web windows: an app's window as an ELEMENT of home's page (unfolded; on unless Settings.Global powos_web_windows =
// 0). docs/WEB_WINDOWS.md "Element model". The user, 2026-10-30: "the whole way we integrate windows is still hacky, it
// needs to be handled properly fully inside the powos web ui", "The apps were supposed to be working directly in the
// webview". This file is the window: its model (page, position, size, scale, z-order = list order = DOM order,
// minimised/maximised, tiles) AND its element - the title bar, buttons, edges, tile menu and dividers are DOM, plain
// web input. Only the app's pixels are native: the host (WebWindows.kt) puts the app's own buffers in a layer UNDER
// home's surface, exactly where this file measures the body every frame (position, clip, visibility, z), on the same
// draw. Over the body the page is transparent; anything above it in the DOM paints over the app and takes its taps.
import { effect, signal } from "@preact/signals";
import { useLayoutEffect, useRef, useState } from "preact/hooks";
import { geometryChannel, native, nextFrameId, sendGeometry } from "../apps/port.ts";
import { powos } from "../bridge.ts";
import { wideHome } from "../hosts/wide.ts";
// The shared spring's CSS vars (--spring / --spring-ms): a folded quick page's sheet rises on it.
import "./spring.ts";
import type { HostWebWindow, HostWebWindowsSnapshot, WebWindowRect } from "../types.ts";
import { Mark } from "./chrome.tsx";
import { forgetQuickReturn, QuickBar, quickGone, quickIconKeys, quickPlace, quickShown, QUICK, type QuickInfo, type QuickRect } from "./quickpage.tsx";
import { memo } from "./memo.ts";
import { barReveal, edgeDown, edgeEnd, edgeMove, holdReveal, releaseReveal, revealGone, revealKept } from "./barreveal.ts";
import { usePresence } from "./reveal.tsx";
import { confirm as hapticConfirm, tick as hapticTick } from "./haptics.ts";
import { dropAt, dropInto, freeRegion, insertAt, leaves, splitBox, tabAt, treeRects, zoneKey as dropKey, type Bar, type Tree, type Zone } from "./tiledrop.ts";

const TITLE = 36;
const RADIUS = 12;

export interface WebWin {
  id: number;
  key: string;
  label: string;
  /** The home page (its number, as pages lists them) it's pinned to. */
  page: number;
  /** Its frame in the page, CSS px. */
  x: number;
  y: number;
  w: number;
  h: number;
  /** Two fingers on its bar or edge zoom the whole window (the host's layer matrix; the app keeps its resolution). */
  scale?: number;
  /**
   * TS1: its app's CONTENT zoom (1 = the window's own density): a pinch on a tiled window's bar - the app shows less
   * (> 1) or more, the frame stays. The host's display dpi ("webwindows.zoom"). Its own property: no layout pass, tile,
   * float or swap touches it; a reload gets it back from "webwindows.list".
   */
  zoom?: number;
  /** Off its page, in the dock (a tap on the dock icon brings it back: openWebWindow). */
  minimised?: boolean;
  /**
   * PP1: its app left the window by itself (its own PiP / floating button: Android's PiP or a floating window,
   * "webwindows.pip"): no frame, no bar - the app is Android's window now; its switcher card says PiP. Expanded back,
   * the host says so and the window returns where it was.
   */
  pip?: boolean;
  /** Filling the work area (above the dock); the frame to go back to. */
  restore?: { x: number; y: number; w: number; h: number };
  /**
   * Its app is a real full-screen app on the main display now (its bar's full screen button, WebWindows.fullScreen):
   * the window is hidden, its place kept; "Back to window" on its switcher card brings it back here.
   */
  full?: boolean;
  /** Its app's task, once the host told it ("webwindows.full"). */
  task?: number;
  /**
   * TB1: its app asks its status bar hidden (immersive: a video full screen, a game) while the window is maximised
   * ("webwindows.immersive", WebWindows.immersiveScan): its bar auto-hides, the body takes its room, a pull from the
   * top slides it back in over the app ([barAutoHidden], ui/barreveal.ts).
   */
  immersive?: boolean;
  /** In a tile (see "Tiles" below): the floating frame it had before, where "float" puts it back. */
  untiled?: { x: number; y: number; w: number; h: number };
  /** Its app's content shows ("webwindows.live"): the body paints nothing; until then, the placeholder. */
  live?: boolean;
  /**
   * LW3: a Linux launch's window before KWin offers its toplevel - the placeholder at once, at its place (id < 0: the
   * host knows nothing of it, no geometry goes out). The first offer with its key takes it ([takePlaceholder]).
   */
  pending?: boolean;
  /** Its element's key: a placeholder's id, kept when KWin's window takes it (the same element: no jump). */
  el?: number;
  /** Not live in [LINUX_START] (or its app gone): "couldn't start", with the reason - its body shows it and a close. */
  failed?: string;
  /**
   * SL1: a game Steam is launching (PowOS's tap or Steam's own UI, "apps.launching" - [steamLaunches]): Steam reports
   * its steps and its end, so it waits [STEAM_START] (a cold Proton start under FEX takes a minute), not [LINUX_START].
   */
  steam?: boolean;
  /** SL1: what the launch is doing now, in plain words ("Syncing saves", "Starting Proton", "Loading"): under its progress line. */
  phase?: string;
  /** SL1: minimised because Steam is asking something in its own window; back when the launch goes on. */
  asking?: boolean;
  /**
   * Its app draws its own complete frame (a Linux window with client-side decorations: Brave, Chrome, Steam, a GTK
   * header bar; kwin 0046 "decor ... own"): no PowOS bar over it (one bar, never two) - its own drag moves this frame
   * ("webwindows.moveresize"), a hold on that drag opens the tile menu.
   */
  ownFrame?: boolean;
  /** A quick page (ui/quickpage.tsx): one settings page as a compact card - no tiles, dock or recents; [QuickEl]. */
  quick?: QuickInfo;
}

/** An app's icon URL by its key (state.ts sets it: this file can't import that one), or undefined. */
let iconOf: (key: string) => string | undefined = () => undefined;
export function setIconOf(f: (key: string) => string | undefined) {
  iconOf = f;
}

/** The home page on screen (its number), as state.ts knows it: where the switcher's split screen tiles. */
let shownPage = () => 1;
export function setShownPage(f: () => number) {
  shownPage = f;
}
/** The page number beside the one on screen ([side] -1 left, 1 right), or null: none that way (state.ts sets it). */
let pageBeside: (side: -1 | 1) => number | null = () => null;
export function setPageBeside(f: (side: -1 | 1) => number | null) {
  pageBeside = f;
}

/** Bottom first: the last one is on top. */
export const webWins = signal<WebWin[]>([]);

let checkedAt = 0;
let on = false;

async function enabled(): Promise<boolean> {
  const ww = powos.webwindows;
  if (!ww) return false;
  if (Date.now() - checkedAt > 5000) {
    on = await ww.enabled().catch(() => false);
    checkedAt = Date.now();
  }
  return on;
}

/** Web windows can open here (unfolded, the setting on): the switcher's split screen tiles instead of Android's split. */
export async function webWindowsOn(): Promise<boolean> {
  return wideHome.value && (await enabled());
}

/** Opens an Android app as a home element on [page] (unfolded, the setting on): false leaves the launch to the caller. */
export async function openWebWindow(key: string, label: string, page: number): Promise<boolean> {
  if (key.startsWith("l:")) return (await linuxWindow(key, label, page)) != null;
  return (await openWindow(key, label, page)) != null;
}

/** [openWebWindow], with the window's id (null: not a window). A page tiling with an empty tile puts it there. */
/**
 * A Linux app ("l:"): its windows come from KWin ("webwindows.adopt" with a KWin id). One that has a web window already
 * comes to [page], on top, as an Android app's does; else (or that window couldn't start) the tap launches it with a
 * placeholder window on [page] at once (LW3: the user, 2026-10-30, "they shoulf have a splash screen"), which its first
 * toplevel takes. null: not one (the caller launches it as before).
 */
async function linuxWindow(key: string, label: string, page: number): Promise<number | null> {
  if (!wideHome.value || !(await enabled())) return null;
  // One that couldn't start goes: a tap is a new try (a stuck one never blocks the app: Dolphin, 2026-10-30 21:01).
  for (const w of webWins.value.filter((v) => v.key === key && v.failed)) close(w.id);
  return existingWindow(key, page) ?? linuxPlaceholder(key, label, page);
}

/** How long a Linux launch's window may take to show (LW3): then "couldn't start". The gate shortens it. */
export const LINUX_START = { ms: 20_000 };
let placeholders = 0;

/** A Linux launch's placeholder window (LW3) on [page], on top, and the launch itself (the host: powos-run). */
function linuxPlaceholder(key: string, label: string, page: number): number {
  const id = --placeholders;
  webWins.value = [...webWins.value, { id, el: id, key, label, page, ...cascade(), pending: true }];
  fillEmptyTile(page, id);
  reach(id);
  watchStart(id);
  void powos.apps.launch(key).catch(() => update(id, { failed: "The launch failed." }));
  return id;
}

// The host: a Linux launch of [key] couldn't start (its command ended with no window, or never ran; Runtime.openRooted):
// its waiting window says so with the reason at once, not "loading" until [LINUX_START] (Dolphin, 2026-10-30 21:00).
powos.on("apps.launchfailed", ({ key, reason }: { key: string; reason?: string }) => {
  for (const w of webWins.value.filter((v) => v.key === key && !v.live && !v.failed)) update(w.id, { failed: `${(reason || "The launch failed").replace(/\.$/, "")}.` });
});
// A Linux window whose content stopped and didn't come back after two rebinds (host ConsumerLane, 7d3bc624): its body
// says so instead of an endless placeholder (10-31 16:01 "Dolphin is loading forever").
powos.on("webwindows.failed", ({ id, reason }: { id: number; reason: string }) => update(id, { live: false, failed: reason }));

/**
 * Window [id] not live in [LINUX_START] (no toplevel, or one that never drew): "couldn't start" - never forever. A
 * Steam game's ([WebWin.steam]) gets [STEAM_START] in all: Steam says itself when its launch ends ([steamLaunches]).
 */
function watchStart(id: number, ms = LINUX_START.ms) {
  setTimeout(() => {
    const w = webWins.value.find((v) => v.id === id);
    if (!w || w.live || w.failed) return;
    if (w.steam && ms < STEAM_START.ms) return watchStart(id, STEAM_START.ms - ms);
    update(id, { failed: w.pending ? "It opened no window." : "Its window never drew." });
  }, ms);
}

/** SL1: how long a Steam game's launch may take to show its window ([watchStart]); also how old a launch may be to get a placeholder. */
export const STEAM_START = { ms: 180_000 };

/** One game launch Steam runs, as the host reports it ("apps.launching": RunningApps.launchesFor, powos-sleep-gui SteamLaunches). */
interface SteamLaunch {
  /** The key its window will be offered as (the drawer entry that starts it, else "l:steam_app_<appid>"). */
  key: string;
  label: string;
  appid: string;
  /** launching (Steam's steps), asking (a question in Steam's window), running (the game's process), ended. */
  state: "launching" | "asking" | "running" | "ended";
  phase?: string;
  /** Why it ended (ended only). */
  reason?: string;
  /** When it started (epoch s). */
  since: number;
  /**
   * Its game's own Android task holds it (SteamLaunchTasks: folded - a fold mid-launch too - or its window opened as a
   * full-screen task): no placeholder here, and one waiting goes - the task shows the launch.
   */
  task?: boolean;
}

/**
 * SL1 (the user, 11-07: "if steam is launching a game why arent we seeing the splashscreen app placeholder window thing
 * we made? like everything should feel completely native and snappy"): a game Steam launches - from Steam's own UI
 * (Big Picture, its library) as well as PowOS's tap - shows the launch's placeholder window from its first step, as a
 * tap on a PowOS icon does (LW3), filling the work area like the game will, with Steam's phase under its progress line.
 * The game's window takes it when KWin offers it (adoptWebWindow -> takePlaceholder: the same element, no jump), and
 * its first frame ("webwindows.live") shows the game in it. Ended before its window: "couldn't start" with why and a
 * close. Steam asking something (a cloud conflict, the shader skip): the placeholder steps aside (minimised) so Steam's
 * window shows, and comes back when the launch goes on. A game with its window already: nothing to do.
 */
async function steamLaunches(list: SteamLaunch[]) {
  for (const l of list) await steamLaunch(l);
}

/** [steamLaunches] for one launch. */
async function steamLaunch(l: SteamLaunch) {
  const launch = `${l.appid}@${l.since}`;
  // Its game's window shows already: this launch is that window's (never a second placeholder for it, also once the
  // window closed and Steam's "ended" is still on its way).
  if (webWins.value.some((v) => v.key === l.key && v.live)) return void steamSeen.add(launch);
  const w = webWins.value.find((v) => v.key === l.key && (v.pending || v.failed || v.steam));
  if (l.task) return steamToTask(w, launch);
  if (w) return steamUpdate(w, l, launch);
  if (!newSteamLaunch(l, launch) || !(await webWindowsOn())) return;
  // Placed meanwhile (another event while the host answered).
  if (webWins.value.some((v) => v.key === l.key) || steamSeen.has(launch)) return;
  steamSeen.add(launch);
  steamPlaceholder(l);
}

/** A launch that gets a placeholder: going on, not seen yet, recent (not from before this page: a reload mid-game). */
const newSteamLaunch = (l: SteamLaunch, launch: string) =>
  (l.state === "launching" || l.state === "running") && !steamSeen.has(launch) && Date.now() - l.since * 1000 <= STEAM_START.ms;

/** Launch [l]'s step on its waiting window [w] (a placeholder, or the game's window before its first frame). */
function steamUpdate(w: WebWin, l: SteamLaunch, launch: string) {
  if (l.state === "ended") return steamEnded(w, l);
  // One that couldn't start before Steam said anything (LW3's own): a tap is its new try.
  if (w.failed && !w.steam) return;
  steamSeen.add(launch);
  // A PowOS tap's placeholder (LW3, cascaded) fills the work area as a game does.
  if (!w.steam && w.pending && !w.restore) toggleMaximise(w.id);
  const asking = l.state === "asking";
  update(w.id, { steam: true, phase: l.phase, failed: undefined, ...askingChange(w, asking) });
  if (!asking && w.asking) raise(w.id);
}

/** The launch is its game's task's now ([SteamLaunch.task]): a placeholder still waiting here goes (a fold mid-launch), never a second one. */
function steamToTask(w: WebWin | undefined, launch: string) {
  steamSeen.add(launch);
  if (w?.pending && w.id < 0) close(w.id);
}

/** Steam asking something ([asking]): the waiting window minimised so Steam's window shows; back once it goes on. */
const askingChange = (w: WebWin, asking: boolean): Partial<WebWin> => (asking !== !!w.asking ? { minimised: asking, asking: asking || undefined } : {});

/** Launch [l] ended before its window's first frame: [w] says why, with a close. */
function steamEnded(w: WebWin, l: SteamLaunch) {
  if (!w.failed) update(w.id, { failed: `${(l.reason || "It ended").replace(/\.$/, "")}.`, phase: undefined, minimised: false, asking: undefined });
}

/** SL1: the launches ("<appid>@<since>") that have their placeholder or window already. */
const steamSeen = new Set<string>();
powos.on("apps.launching", (list: SteamLaunch[]) => void steamLaunches(Array.isArray(list) ? list : []));

/** SL1: the placeholder window of a Steam launch on the page on screen, on top, filling the work area - no launch of its own (Steam runs it). */
function steamPlaceholder(l: SteamLaunch): number {
  const id = --placeholders;
  const page = shownPage();
  webWins.value = [...webWins.value, { id, el: id, key: l.key, label: l.label, page, ...cascade(), pending: true, steam: true, phase: l.phase }];
  toggleMaximise(id);
  watchStart(id);
  console.info(`[steam-launch] ${l.label} (${l.appid}): placeholder ${id} at ${l.phase ?? l.state}`);
  return id;
}

/** A new window's default frame (page px): half the screen wide, cascaded by the windows there are. */
function cascade(): { x: number; y: number; w: number; h: number } {
  const n = webWins.value.length;
  return { x: 48 + 32 * (n % 6), y: 72 + 32 * (n % 6), w: Math.round(innerWidth * 0.5), h: Math.round(innerHeight * 0.6) };
}

/**
 * KWin's toplevel [kwin] for placeholder [ph] (LW3): the host's window at the placeholder's body, then the same model
 * entry and element under the host's id (its frame, page, tile and z kept). Closed meanwhile: the window goes too.
 */
async function takePlaceholder(ph: WebWin, kwin: number, ownFrame?: boolean): Promise<boolean> {
  const b = document.querySelector(`.webwindow[data-wwid="${ph.id}"] .webwindow-body`)?.getBoundingClientRect();
  const o = pageOrigin();
  const rect = b?.width ? { left: b.left, top: b.top, width: b.width, height: b.height } : { left: ph.x + o.x, top: ph.y + o.y + TITLE, width: ph.w, height: ph.h - TITLE };
  const id = await powos.webwindows!.open(ph.key, rect, undefined, kwin).catch(() => -1);
  if (id < 0) return false;
  if (!webWins.value.some((w) => w.id === ph.id)) {
    void powos.webwindows!.close(id);
    return true;
  }
  hostGave(id);
  webWins.value = webWins.value.map((w) => (w.id === ph.id ? { ...w, id, el: w.el ?? ph.id, pending: undefined, failed: undefined, ownFrame: ownFrame || undefined } : w));
  const t = tiledOn(ph.id);
  if (t != null) setTiling(t, { ...tilings.value[t], ids: tilings.value[t].ids.map((v) => (v === ph.id ? id : v)) });
  if (tileMenu.value === ph.id) tileMenu.value = id;
  watchStart(id);
  return true;
}

/**
 * App [key]'s window already (its id, brought to [page] - or to the front as its full-screen app), or null: none. The
 * ONE running-window lookup of every launch (dock, drawer, home icon, search, assist, overlays -> state.ts launch ->
 * openWebWindow), Android and Linux alike (the user 11-03: tapping Steam "launches a SECOND Steam instead of focusing the
 * running one"): a full-screen Linux window was skipped here, so a tap made a placeholder and a second launch.
 */
function existingWindow(key: string, page: number): number | null {
  // Already a window: it comes to this page, on top - never a second display for the same app (its task would move).
  // One that couldn't start is no running window (linuxWindow closes it and tries again).
  const open = webWins.value.find((w) => w.key === key && !w.failed);
  if (!open) return null;
  // A full-screen app now: it comes to the front as one (never a second window).
  if (open.full && powos.webwindows?.fullScreen) {
    void powos.webwindows.fullScreen(open.id);
    return open.id;
  }
  return cameHere(open.id, page);
}

/** Window [id] to [page], not minimised, on top: its id. */
function cameHere(id: number, page: number): number {
  showTab(id);
  toPageOf(id, page);
  // On its page and reachable: a window left outside every page (an x off by a page width) comes onto this one.
  const w = webWins.value.find((v) => v.id === id);
  const at = w && !w.full ? clampPlace(w.x, w.y, w.w) : null;
  update(id, { minimised: false, ...(at && (at.x !== w!.x || at.y !== w!.y) ? at : {}) });
  raise(id);
  return id;
}

/**
 * Window [id] onto [page]: tiled on ANOTHER page, it leaves that tiling first (the others close up) - never a tile kept
 * for a window that is gone (the user 11-03, Chrome dragged out onto another page: "It moved the old one and it broke the
 * grid" - its half stayed empty). On [page] it floats at its own frame, or takes an empty tile there.
 */
function toPageOf(id: number, page: number) {
  const was = webWins.value.find((w) => w.id === id)?.page;
  const tiled = tiledOn(id);
  if (tiled != null && tiled !== page) untile(id, "float");
  update(id, { page });
  if (was !== page) fillEmptyTile(page, id);
}

/**
 * Opens in flight by app key (the user, 10-31: "Sometimes it shows it as empty if it's opening two instances of the
 * app"): a second tap while the first open waits for the host gets THAT open's window, never a second bridge call.
 */
const opening = new Map<string, Promise<number | null>>();

/** How long an Android window may stand with no task bound (never "live") before it goes: never left empty. */
export const BOUND = { ms: 3000 };

export async function openWindow(key: string, label: string, page: number): Promise<number | null> {
  const inFlight = opening.get(key);
  if (inFlight) {
    const id = await inFlight;
    return id == null || !webWins.value.some((v) => v.id === id) ? id : cameHere(id, page);
  }
  const p = openFresh(key, label, page);
  opening.set(key, p);
  try {
    return await p;
  } finally {
    opening.delete(key);
  }
}

async function openFresh(key: string, label: string, page: number): Promise<number | null> {
  // An Android app ("a:") or an installed .pow web app ("w:", the host's WebAppActivity on its site; issue #8).
  if (!wideHome.value || !(key.startsWith("a:") || key.startsWith("w:")) || !(await enabled())) return null;
  const had = existingWindow(key, page);
  if (had != null) return had;
  return openHost(key, label, page, false);
}

/**
 * The host's window for Android app [key] on [page]: a new one, or (one display per app task) the app's existing one,
 * which comes here. [another]: a second instance of an app that has a window (the host forces it for every app Android
 * lets run twice; a singleTask / singleInstance one answers with its existing window).
 */
async function openHost(key: string, label: string, page: number, another: boolean): Promise<number | null> {
  const { x, y, w, h } = cascade();
  // Its first rect is a guess; the element reports its real one on its first frame.
  const ww = powos.webwindows!;
  const rect = { left: x, top: y + TITLE, width: w, height: h - TITLE };
  const id = await (another && ww.openAnother ? ww.openAnother(key, rect) : ww.open(key, rect)).catch(() => -1);
  if (id < 0) return null;
  // The host's window for this app already (its task on another display or page, minimised, split): that one comes
  // here, never a second entry or display.
  if (webWins.value.some((v) => v.id === id)) return cameHere(id, page);
  hostGave(id);
  webWins.value = [...webWins.value, { id, key, label, page, x, y, w, h }];
  fillEmptyTile(page, id);
  reach(id);
  watchBound(id, key);
  return id;
}

// ---- the window the user is in: Back / Forward go to it (the host's WindowKeys.kt) ---------------------------------
// The user, 11-01 (Chrome floating over home): "when I use the back or forward button/gesture it doesn't do anything for
// the given window". A press on a window (its bar or body) makes it the user's at once; home is theirs again only after a
// whole press outside every window (its UP: the edge back gesture's own DOWN on home is cancelled, so it never takes
// the focus off the window it is meant for).
let focusedWin = -1;
function focusWin(id: number) {
  if (id === focusedWin) return;
  focusedWin = id;
  void powos.webwindows?.focus?.(id);
}
if (typeof addEventListener === "function") {
  let outside = false;
  addEventListener(
    "pointerdown",
    (e) => {
      const el = (e.target as Element | null)?.closest?.(".webwindow[data-wwid]");
      const id = el ? Number(el.getAttribute("data-wwid")) : NaN;
      outside = !Number.isFinite(id);
      if (!outside) focusWin(id);
    },
    { capture: true, passive: true },
  );
  addEventListener("pointerup", () => outside && focusWin(-1), { capture: true, passive: true });
  addEventListener("pointercancel", () => (outside = false), { capture: true, passive: true });
}

// ---- quick pages (ui/quickpage.tsx; the host: QuickPages.kt) --------------------------------------------------------

// The host started a quick page's launch: its card here, springing out of [anchor]; its page starts on the card's display.
powos.on("quickpage.show", (m: { token: string; pkg: string; label: string; anchor?: QuickRect | null }) => {
  void openQuick(m).then((id) => {
    if (id == null) {
      forgetQuickReturn();
      void powos.quickpage?.refused(m.token);
    } else quickShown(m.token);
  });
});

/**
 * Quick page [m]'s card on the page on screen (one at a time: an open one goes): its id, or null (the host's net runs).
 * Folded too - the web-window layer's first folded user (the manager, 11-01: "web windows being unfolded-only is no
 * excuse"): one card display, a sheet full width minus 16 rising above the bar. Every other window stays unfolded-only.
 */
export async function openQuick(m: { token: string; pkg: string; label: string; anchor?: QuickRect | null }): Promise<number | null> {
  if (!(await enabled())) return null;
  for (const w of webWins.value.filter((v) => v.quick)) close(w.id);
  const sheet = !wideHome.value || innerWidth < QUICK.folded;
  const p = quickPlace(m.anchor ?? undefined, workArea(), sheet, innerHeight);
  const key = `q:${m.token}`;
  const id = await powos.webwindows!.open(key, { left: p.x, top: p.y + TITLE, width: p.w, height: p.h - TITLE }).catch(() => -1);
  if (id < 0) return null;
  const o = pageOrigin();
  hostGave(id);
  const quick: QuickInfo = { token: m.token, pkg: m.pkg, anchor: m.anchor ?? undefined, sheet: sheet || undefined, origin: p.origin };
  webWins.value = [...webWins.value, { id, key, label: m.label, page: shownPage(), x: p.x - o.x, y: p.y - o.y, w: p.w, h: p.h, quick }];
  return id;
}

// A fold / unfold: an open quick page's card was placed for the other screen (a folded sheet, an unfolded card) - it goes.
let quickWide = wideHome.peek();
wideHome.subscribe((wide) => {
  if (wide === quickWide) return;
  quickWide = wide;
  for (const w of webWins.value.filter((v) => v.quick)) close(w.id);
});

/** Quick page [id] reopened in its app's normal window (the host closes the card and its task, then launches it). */
function popOut(win: WebWin) {
  const q = powos.quickpage;
  if (!q || !win.quick) return close(win.id);
  quickGone(win.quick.token, "popout");
  void q.popout(win.quick.token, win.id);
  webWins.value = webWins.value.filter((w) => w.id !== win.id);
}

/** A quick page's card: a scrim (a tap outside closes), the card on the backdrop glass with its small bar and the page. */
function QuickEl({ win, z }: { win: WebWin; z: number }) {
  const body = useRef<HTMLDivElement>(null);
  const frame = { position: "absolute", left: `${win.x}px`, top: `${win.y}px`, width: `${win.w}px`, height: `${win.h}px`, zIndex: 20 + z, display: "flex", flexDirection: "column", transformOrigin: win.quick?.origin } as const;
  return (
    <>
      <div class="quickpage-scrim" style={{ zIndex: 19 + z }} onPointerDown={(e) => (e.stopPropagation(), close(win.id))} />
      <div class={`webwindow quickpage${win.quick?.sheet ? " quick-sheet" : ""}${win.live ? " live" : ""}`} data-wwid={win.id} data-z={z} data-quick={win.quick?.token} style={frame}>
        <QuickBar label={win.label} icon={quickIconKeys(win.quick?.pkg).map(iconOf).find(Boolean) ?? iconOf(win.key)} height={TITLE} onPopOut={() => popOut(win)} onClose={() => close(win.id)} />
        <Body win={win} body={body} />
      </div>
    </>
  );
}

/** Window [id] with no task bound (never live) [BOUND] after its launch: removed, logged - never an empty frame. */
function watchBound(id: number, key: string) {
  setTimeout(() => {
    const w = webWins.value.find((v) => v.id === id);
    if (!w || w.live || w.task != null || w.full) return;
    console.warn(`webwindows: window ${id} (${key}) has no task ${BOUND.ms} ms after its launch: removed, not left empty`);
    close(id);
  }, BOUND.ms);
}

/** Where an adopted window goes: its [body] (viewport CSS px) plus its [bar], else a default size centred in the work
 * area; clamped into the work area (viewport px). */
function adoptPlace(body: WebWindowRect | undefined, bar: number): { vx: number; vy: number; w: number; h: number } {
  const a = workArea();
  const aw = a.right - a.left;
  const ah = a.bottom - a.top;
  const w = Math.max(Math.min(aw, Math.round(body ? body.width : innerWidth * 0.5)), 200);
  const h = Math.max(Math.min(ah, Math.round(body ? body.height + bar : innerHeight * 0.6)), 160);
  const sx = body ? body.left : a.left + (aw - w) / 2;
  const sy = body ? body.top - bar : a.top + (ah - h) / 2;
  const vx = Math.round(Math.min(Math.max(sx, a.left), a.right - w));
  const vy = Math.round(Math.min(Math.max(sy, a.top), a.bottom - h));
  return { vx, vy, w, h };
}

/**
 * An app's running task made a window here (the host's "webwindows.adopt": the switcher's "PowOS desktop window", the
 * system window menu's "Desktop window" - ShellBridge.toWebWindow is the one path): a new window on [page] holding THAT
 * task (moved onto the window's display, not launched again), at [body] (viewport CSS px: where the app floated, or its
 * last place by hand) inside the work area, else a default size centred in it. Home goes to [page], the window on top.
 * A tiling on [page] with an empty tile puts it there (fillEmptyTile), as [openWindow] does.
 */
/** The drawer key of KWin's stand-in window for an Android app ([adoptWebWindow]). */
const ANDROID_STAND_IN = "l:android-";

export async function adoptWebWindow(
  m: { task?: number; kwin?: number; key: string; label: string; body?: WebWindowRect; ownFrame?: boolean; alts?: string[] },
  page: number,
): Promise<boolean> {
  // Plan 2.4: one adoption per offer at a time - the event's and a snapshot's (its pendingLinux) are the same one. Once
  // it's done the host has taken the offer (a late snapshot's copy only gets "not offered" back: -1, nothing made).
  const kwin = m.kwin;
  if (kwin == null) return adoptNow(m, page);
  if (offersSeen.has(kwin)) return false;
  offersSeen.add(kwin);
  try {
    return await adoptNow(m, page);
  } finally {
    offersSeen.delete(kwin);
  }
}

async function adoptNow(
  m: { task?: number; kwin?: number; key: string; label: string; body?: WebWindowRect; ownFrame?: boolean; alts?: string[] },
  page: number,
): Promise<boolean> {
  // KWin's stand-in for an Android app ("l:android-<package>", the Linux session's powos-android-tasks / scrcpy
  // window): the app's own window is it - never a second element (10-31 15:33, Termux's translucent ghost window).
  if (m.key.startsWith(ANDROID_STAND_IN)) return false;
  // A window that draws its own frame has no PowOS bar: its body is the whole frame.
  const bar = m.ownFrame ? 0 : TITLE;
  const ww = powos.webwindows;
  if (!ww) return false;
  // A Linux launch's placeholder waiting for this app (LW3; by its key - the host matched app_id to the .desktop - or
  // the key of an entry starting the same command, [alts]: System Settings' two .desktop files): taken.
  const ph = m.kwin != null ? webWins.value.find((w) => w.pending && (w.key === m.key || !!m.alts?.includes(w.key))) : undefined;
  if (ph) return takePlaceholder(ph, m.kwin!, m.ownFrame);
  const o = pageOrigin();
  const { vx, vy, w, h } = adoptPlace(m.body, bar);
  const id = await ww.open(m.key, { left: vx, top: vy + bar, width: w, height: h - bar }, m.task, m.kwin).catch(() => -1);
  if (id < 0) return false;
  // The host gave the app's existing window (one display per app task): it comes to [page], no second entry.
  if (webWins.value.some((v) => v.id === id)) {
    cameHere(id, page);
    toPage(page);
    return true;
  }
  hostGave(id);
  webWins.value = [...webWins.value, { id, key: m.key, label: m.label, page, x: vx - o.x, y: vy - o.y, w, h, task: m.task, ownFrame: m.ownFrame || undefined }];
  if (m.kwin != null) watchStart(id);
  // As any window opened on the page: a tiling there with an empty tile takes it (its floating frame kept for a float
  // out); otherwise it floats at that frame on top.
  fillEmptyTile(page, id);
  toPage(page);
  return true;
}

/**
 * RL1 (the user, 10-31 14:19: "my widgets A window behind my widgets."): the page's list lives in memory only, and a
 * reload (a shell update) dropped it while the host kept the windows - their app layers under home with no frame, bar
 * or close.
 *
 * Plan 2.4 (docs/WEB_WINDOWS.md "The host snapshot: the contract"): THE sync with the host. It reads the host snapshot
 * ("webwindows.list" true) on load, on every "webwindows.changed <generation>" and when the native port reconnects, and
 * makes the page agree with it: a window the page lacks is added (at its layout record's page and frame when the host
 * has one, else on the page on screen at the host's last frame), a window the host no longer has goes, host-owned facts
 * (state, live, failed, ownFrame, task) are applied, a KWin offer the page never got is adopted, and tilings and
 * tab groups come back from the page records for the windows it added. One sync runs at a time (a change meanwhile
 * runs it once more after); a snapshot older than the last applied is ignored. The count of windows added.
 */
export function rebuildFromHost(): Promise<number> {
  if (syncRun) {
    syncAgain = true;
    return syncRun;
  }
  syncRun = (async () => {
    let added = 0;
    do {
      syncAgain = false;
      added += await syncOnce();
    } while (syncAgain);
    return added;
  })().finally(() => (syncRun = null));
  return syncRun;
}

let syncRun: Promise<number> | null = null;
let syncAgain = false;
/** The generation of the last snapshot applied (-1: none yet): an older one is ignored. */
let appliedGen = -1;
/** The host's windows as the last applied snapshot had them: a host fact is applied when it CHANGED since ([hostFacts]). */
let lastHost = new Map<number, HostWebWindow>();
/** When the host gave the page each window (an open, an adoption): one given after a snapshot was asked for isn't in it. */
const givenAt = new Map<number, number>();
/** KWin windows the page is adopting now ([adoptWebWindow]): a snapshot's pending offer in flight isn't adopted twice. */
const offersSeen = new Set<number>();

/** For the gate: the last generation applied. */
export const syncedGeneration = () => appliedGen;

async function syncOnce(): Promise<number> {
  const asked = performance.now();
  const got = await powos.webwindows?.list?.(true).catch(() => null);
  if (!got) return 0;
  // A host from before the snapshot (and the gate's RL1/GH1 hosts): the bare array - add what's missing, as before.
  if (Array.isArray(got)) return addMissing(got, new Map());
  if (!Array.isArray(got.windows)) return 0;
  if (got.generation < appliedGen) {
    console.info(`[ww-sync] snapshot ${got.generation} ignored: ${appliedGen} applied already`);
    return 0;
  }
  appliedGen = got.generation;
  return applySnapshot(got, asked);
}

/** Snapshot [s] (asked for at [asked]) made the page's: removes, updates, adds, offers, tilings and tabs. */
function applySnapshot(s: HostWebWindowsSnapshot, asked: number): number {
  const gone = removeUnlisted(s.windows, asked);
  const before = lastHost;
  lastHost = new Map(s.windows.map((h) => [h.id, h]));
  const updated = s.windows.filter((h) => hostFacts(h, before.get(h.id))).length;
  const added = addMissing(s.windows, layoutsOf(s.windows));
  if (added) restoreAdded(s.pages ?? {}, webWins.peek().slice(-added).map((w) => w.id));
  for (const o of s.pendingLinux ?? []) if (!offersSeen.has(o.kwin)) void adoptWebWindow({ ...o, label: o.label || o.key }, shownPage());
  if (gone + updated + added > 0) console.info(`[ww-sync] generation ${s.generation}: +${added} -${gone} ~${updated}`);
  return added;
}

/**
 * Page windows the snapshot [list] doesn't name, gone (a launch's placeholder is the page's own) - unless the host gave
 * it to the page after the snapshot was [asked] for (an open racing the read). The host's ids set. The count removed.
 */
function removeUnlisted(list: HostWebWindow[], asked: number): number {
  const listed = new Set(list.map((h) => h.id));
  const late = (id: number) => (givenAt.get(id) ?? -1) > asked;
  hostIds.value = new Set([...listed, ...[...givenAt.keys()].filter(late)]);
  const gone = webWins.peek().filter((w) => w.id >= 0 && !w.pending && !listed.has(w.id) && !late(w.id));
  gone.forEach((w) => forget(w.id));
  return gone.length;
}

/** Windows [ids] a sync just added: their page records' tilings and tabs back, then each brought into reach. */
function restoreAdded(pages: Record<string, string>, ids: number[]) {
  const added = new Set(ids);
  for (const [key, json] of Object.entries(pages)) {
    const r = parsePage(json);
    if (!r) continue;
    if (r.tiling) restoreTiling(Number(key), r.tiling, added);
    for (const g of r.tabs ?? []) restoreTabs(g, added);
  }
  // A record's frame from another screen (a fold since) comes back into reach, as a fold's own [reachAll] does.
  ids.forEach(reach);
}

function parsePage(json: string): PageLayout | null {
  try {
    const r = JSON.parse(json) as PageLayout;
    return r?.v === 1 ? r : null;
  } catch {
    return null;
  }
}

/** Page [page]'s recorded tiling [t] back, of the windows on that page and in no tiling - if it names one just [added] and the page has none. */
function restoreTiling(page: number, t: Tiling, added: Set<number>) {
  if (tilings.peek()[page] || !t.ids.some((id) => id != null && added.has(id))) return;
  const on = new Set(webWins.peek().filter((w) => w.page === page && tiledOn(w.id) == null).map((w) => w.id));
  const ids = t.ids.map((id) => (id != null && on.has(id) ? id : null));
  if (ids.filter((v) => v != null).length >= 2) setTiling(page, { ...t, ids });
}

/** Recorded tab group [g] back, of its windows that are here and in no group - if it names one just [added]. */
function restoreTabs(g: Stack, added: Set<number>) {
  if (!g.ids.some((id) => added.has(id))) return;
  const here = new Set(webWins.peek().map((w) => w.id));
  const ids = g.ids.filter((id) => here.has(id) && !stackOf(id));
  if (ids.length >= 2) setStacks([...stacks.peek(), { ids, active: ids.includes(g.active) ? g.active : ids[0] }]);
}

/** Host windows in [list] the page has no element for, added; [records]: their layout records by id. The count. */
function addMissing(list: HostWebWindow[], records: Map<number, WindowLayout>): number {
  if (!list.length) return 0;
  const have = new Set(webWins.peek().map((w) => w.id));
  const page = shownPage();
  // One element per host window and task: a host window whose task the page shows already, or KWin's stand-in for an
  // Android app, is not a second one.
  const tasks = new Set(webWins.peek().map((w) => w.task).filter((t) => t != null));
  const add = list
    .filter((h) => h.id >= 0 && !have.has(h.id) && !h.key.startsWith(ANDROID_STAND_IN) && !(h.task != null && h.task >= 0 && tasks.has(h.task)))
    .map((h) => withRecord(fromHost(h, page), records.get(h.id)));
  if (!add.length) return 0;
  add.forEach((w) => hostGave(w.id));
  webWins.value = [...webWins.peek(), ...add];
  return add.length;
}

/** Each host window's layout record (plan 2.3, [WindowLayout] v1), parsed; a bad one is skipped. */
function layoutsOf(list: HostWebWindow[]): Map<number, WindowLayout> {
  const out = new Map<number, WindowLayout>();
  for (const h of list) {
    if (!h.layout) continue;
    try {
      const r = JSON.parse(h.layout) as WindowLayout;
      if (r?.v === 1 && r.frame && typeof r.page === "number") out.set(h.id, r);
    } catch {}
  }
  return out;
}

/** Entry [w] at its record [r]'s page and frame (and its maximise / tile / scale memory); host-owned state stays. */
function withRecord(w: WebWin, r: WindowLayout | undefined): WebWin {
  if (!r) return w;
  const { x, y, w: ww, h } = r.frame;
  return { ...w, page: r.page, x, y, w: ww, h, restore: r.restore, untiled: r.untiled, scale: r.scale };
}

/**
 * Host window [h]'s facts made the page's where they CHANGED since the last snapshot ([was]; undefined: the page never
 * saw it from a snapshot) and the page differs - the same paths as their per-fact events, so a late event and the
 * snapshot agree and either order ends the same (idempotent). A fact the host kept is never re-applied: the page's own
 * change on its way to the host (a minimise just tapped) isn't undone by a snapshot read before the host took it.
 * true: something changed.
 */
function hostFacts(h: HostWebWindow, was: HostWebWindow | undefined): boolean {
  const w = webWins.peek().find((v) => v.id === h.id);
  if (!w) return false;
  const moved = (k: keyof HostWebWindow) => !was || was[k] !== h[k];
  const change = factChange(w, h, moved);
  const any = Object.keys(change).length > 0;
  if (any) update(h.id, change);
  const state = moved("state") && pageState(w) !== h.state;
  if (state) toHostState(h.id, h.state, h.task);
  return any || state;
}

/**
 * [hostFacts]' field changes, as "webwindows.live" / ".failed" / ".frame" / ".full"'s task make them. Zoom is the
 * page's own call's (no event): the page's newer value is never taken back.
 */
function factChange(w: WebWin, h: HostWebWindow, moved: (k: keyof HostWebWindow) => boolean): Partial<WebWin> {
  const change: Partial<WebWin> = moved("live") || moved("failed") ? liveChange(w, h) : {};
  if (moved("ownFrame") && !!w.ownFrame !== !!h.ownFrame) change.ownFrame = h.ownFrame || undefined;
  const task = hostTask(h);
  if (moved("task") && task != null && w.task !== task) change.task = task;
  return change;
}

/** Host window [h]'s app task, undefined: none yet (-1). */
const hostTask = (h: HostWebWindow) => (h.task != null && h.task >= 0 ? h.task : undefined);

/** "webwindows.live" (true only) and ".failed" as the snapshot's [h] states them, where page window [w] differs. */
function liveChange(w: WebWin, h: HostWebWindow): Partial<WebWin> {
  if (h.failed) return w.failed === h.failed ? {} : { live: false, failed: h.failed };
  return h.live && !w.live ? { live: true } : {};
}

/** Window [w]'s state as the host names it. */
const pageState = (w: WebWin): HostWebWindow["state"] => (w.full ? "full" : w.pip ? "pip" : w.minimised ? "minimised" : "floating");

/** Window [id] to the host's [state], through the per-fact events' own paths (full, pip, state). */
function toHostState(id: number, state: HostWebWindow["state"], task?: number) {
  const w = webWins.peek().find((v) => v.id === id);
  if (!w) return;
  if (w.full && state !== "full") onFull({ id, on: false });
  if (w.pip && state !== "pip") onPip({ id, on: false });
  if (state === "full") return onFull({ id, on: true, task: task != null && task >= 0 ? task : undefined });
  if (state === "pip") return onPip({ id, on: true });
  onHostMinimised({ id, minimised: state === "minimised" });
}

/** Host window [h] as the page's entry on [page]: its frame (the body plus its bar) where the host last had it. */
function fromHost(h: HostWebWindow, page: number): WebWin {
  const bar = h.ownFrame ? 0 : TITLE;
  const body = h.body ?? (h.frame && { ...h.frame, top: h.frame.top + bar, height: h.frame.height - bar });
  const o = pageOrigin();
  const { vx, vy, w, h: hh } = adoptPlace(body, bar);
  return {
    id: h.id, key: h.key, label: h.label, page, x: vx - o.x, y: vy - o.y, w, h: hh,
    task: h.task != null && h.task >= 0 ? h.task : undefined,
    live: h.live || undefined, ownFrame: h.ownFrame || undefined,
    failed: h.failed || undefined,
    quick: h.key.startsWith("q:") ? { token: h.key.slice(2), pkg: "" } : undefined,
    ...stateOf(h),
    zoom: zoomOf(h),
  };
}

/** TS1: host window [h]'s content zoom, undefined at 1. */
/** Host window [h]'s state as the page's flags (minimised, full screen, PiP: PP1). */
const stateOf = (h: HostWebWindow) => ({ minimised: h.state === "minimised" || undefined, full: h.state === "full" || undefined, pip: h.state === "pip" || undefined });
const zoomOf = (h: HostWebWindow) => (h.zoom != null && h.zoom !== 1 ? h.zoom : undefined);
// Plan 2.4: the host says its snapshot moved on - read it unless this generation is applied already.
powos.on("webwindows.changed", (generation: number) => {
  if (typeof generation === "number" && generation <= appliedGen && !syncRun) return;
  void rebuildFromHost();
});
void rebuildFromHost();

/** The pointer kept by its element (a synthetic or already-ended pointer can't be: the drag still works). */
function capture(e: PointerEvent) {
  try {
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
  } catch {}
}

export function update(id: number, change: Partial<WebWin>) {
  const was = change.minimised === undefined ? undefined : !!webWins.value.find((w) => w.id === id)?.minimised;
  webWins.value = webWins.value.map((w) => (w.id === id ? { ...w, ...change } : w));
  if (was !== undefined && was !== !!change.minimised) minimisedChanged(id, !was);
}

/**
 * MN1/MN2 (the user, 2026-10-30 22:52: "Click the minimize button on for example YouTube. It should act as if I swiped
 * home on it"): every minimise (bar button, dock toggle, a tile's drop) and every way back reaches the host, which gives
 * the app a home gesture's lifecycle (it may go picture-in-picture) and brings it back into its window.
 */
function minimisedChanged(id: number, on: boolean) {
  if (!native.value || id < 0) return;
  if (on) void powos.webwindows?.minimise?.(id);
  else void powos.webwindows?.restore?.(id);
}

export function raise(id: number) {
  const list = webWins.value;
  if (list[list.length - 1]?.id === id) return;
  const win = list.find((w) => w.id === id);
  if (!win) return;
  webWins.value = [...list.filter((w) => w.id !== id), win];
}

/**
 * The host's window ids as its last "webwindows.alive" listed them, plus each one it gave the page since (an open, an
 * adoption); null: no list yet (the mock, a host before it). A window not in it has no host window: [WebWindowEl] gives
 * it its PowOS bar with a close button whatever its state (own frame, tiled), never a bare picture (10-31 03:05, "Clear
 * all": "like it's missing the title bar but it's not done properly").
 */
export const hostIds = signal<Set<number> | null>(null);
function hostGave(id: number) {
  givenAt.set(id, performance.now());
  const ids = hostIds.value;
  if (ids && !ids.has(id)) hostIds.value = new Set([...ids, id]);
}
/** Window [id] has no host window (the host's list doesn't name it): its bar shows, with a close button. */
export function orphaned(id: number): boolean {
  const ids = hostIds.value;
  return id >= 0 && ids != null && !ids.has(id);
}
function forget(id: number) {
  // A quick page's card closed: back to the search it was opened from (ui/quickpage.tsx returnAfterQuick).
  const token = webWins.value.find((w) => w.id === id)?.quick?.token;
  if (token) quickGone(token, "closed");
  leaveStack(id);
  untile(id, "gone");
  givenAt.delete(id);
  webWins.value = webWins.value.filter((w) => w.id !== id);
}
powos.on("webwindows.closed", (id: number) => {
  const ids = hostIds.value;
  if (ids?.has(id)) hostIds.value = new Set([...ids].filter((v) => v !== id));
  forget(id);
});
/**
 * The host's windows, by id (each reconcile, at least every 2 s): an entry it has no window for is a ghost - it goes,
 * as on "webwindows.closed". Placeholders (negative ids, a Linux launch's) are the page's own.
 */
powos.on("webwindows.alive", (ids: number[]) => {
  const alive = new Set(ids);
  hostIds.value = alive;
  for (const w of webWins.value) if (!(w.id < 0 || w.pending || alive.has(w.id))) forget(w.id);
});
/** Home to a page (by its number, as pages lists them): state.ts sets it (it imports this file, not the reverse). */
let toPage: (page: number) => void = () => {};
export function onWebWindowPage(f: (page: number) => void) {
  toPage = f;
}

/** Window [id] shown where it was: not minimised, on top, home on its page. */
function bringBack(id: number) {
  showTab(id);
  const w = webWins.value.find((v) => v.id === id);
  if (!w) return;
  update(id, { minimised: false });
  // WC1: back from full screen / PiP / minimised - reachAll skips full-screen and PiP frames, so one kept across a
  // fold or rotation comes back on the old screen's coordinates.
  reach(id);
  raise(id);
  toPage(w.page);
}

/**
 * The dock's group cell tapped (ui/dockgroups.tsx; the user 10-31 03:18: "the homebar doesn't really show them as
 * docked together"): every window of the group [ids] shown and in front, in their order, home on [page]. A stack's
 * hidden tabs stay hidden (its shown tab is the one brought).
 */
export function bringGroup(ids: number[], page: number) {
  for (const id of ids) {
    if (hiddenTab(id) || !webWins.value.some((v) => v.id === id)) continue;
    update(id, { minimised: false });
    raise(id);
  }
  toPage(page);
}

/**
 * TB4 (the user, 2026-10-30: "If I click on the icon of an open window I should be able to minimize it that way"): a
 * dock tap on app [key] with web windows, taskbar style - one code path for Android and Linux windows. Its window in
 * front (the top-most one showing on the page on screen) minimises; with several windows of the app the tap cycles
 * instead (its bottom-most one comes to the front, so each gets its turn). Not in front - minimised, under another
 * window or on another page - its top-most window comes back in front on ITS page (home goes there). false: no window
 * here (folded, none, or only a full-screen one): the caller goes on as before (launch -> openWebWindow).
 */
export function dockToggle(key: string): boolean {
  if (!wideHome.value) return false;
  const mine = webWins.value.filter((w) => w.key === key && !w.full);
  if (!mine.length) return false;
  const here = shownPage();
  const front = webWins.value.filter((w) => w.page === here && !w.minimised && !w.full && !w.pip && !hiddenTab(w.id)).at(-1);
  if (front?.key === key) {
    if (mine.length === 1) minimise(front.id);
    else bringBack(mine[0].id);
    return true;
  }
  bringBack(mine[mine.length - 1].id);
  return true;
}

/** Its app became a full-screen app (the window hides, its place kept) or is back in the window (shown on its page). */
powos.on("webwindows.full", (m: { id: number; on: boolean; task?: number }) => onFull(m));
function onFull(m: { id: number; on: boolean; task?: number }) {
  // A tile going full screen leaves its tile (the others close up); back in a window, it floats at its old frame.
  if (m.on) untile(m.id, "float");
  update(m.id, { full: m.on, task: m.task ?? webWins.value.find((w) => w.id === m.id)?.task, minimised: false });
  if (!m.on) bringBack(m.id);
  resendGeometry();
}
/** The host lost or re-made layer state (a mirror made again, home's surface re-attached): every window's state again. */
powos.on("webwindows.resend", () => resendNow());
/** TB1: its app hides its status bar (immersive) or shows it again, while maximised (WebWindows.immersiveScan). */
powos.on("webwindows.immersive", (m: { id: number; on: boolean }) => {
  if (!!webWins.value.find((w) => w.id === m.id)?.immersive === m.on) return;
  update(m.id, { immersive: m.on || undefined });
  if (!m.on) revealGone(m.id);
});
/** TB2: a full-screen Linux window's bar slid in by a pull from the top edge, or hidden again (WebWindows.revealFull). */
powos.on("webwindows.reveal", (m: { id: number; on: boolean }) => {
  if (m.on) fullReveal.value = m.id;
  else if (fullReveal.peek() === m.id) fullReveal.value = null;
});
/** Its app's first frame shows (WebWindows.liveWhenDrawn): the placeholder goes, the body is the app's. */
powos.on("webwindows.live", (id: number) => update(id, { live: true }));
/** Its app draws its own frame now, or no longer (WebWindows.linuxOwnFrame): its PowOS bar goes or comes. */
powos.on("webwindows.frame", (m: { id: number; own: boolean }) => update(m.id, { ownFrame: m.own || undefined }));
/**
 * Its app's own frame dragged (WebWindows.linuxMoveResize: its tab strip's drag, an edge of its own): the press on its
 * body that did it now moves ("move") or resizes (the edges) this frame, from the next pointer move on (Body).
 */
powos.on("webwindows.moveresize", (m: { id: number; edges: string }) => {
  appDrags.set(m.id, { edges: m.edges, start: null, moved: false, hold: 0 });
});
/**
 * The host's minimised state of window [m.id] (WebWindows.kt minimisedIs: the page's minimise or restore as the host
 * took it, its PiP expanded): the one source of [WebWin.minimised] - dockToggle reads what this set. Never told back to
 * the host (it is the host's). e2e round 193: Calculator (no PiP) stayed "floating" in the host's list after its
 * minimise, and Chrome came back in front behind the page's back.
 */
powos.on("webwindows.state", (m: { id: number; minimised: boolean }) => onHostMinimised(m));
function onHostMinimised(m: { id: number; minimised: boolean }) {
  const w = webWins.value.find((v) => v.id === m.id);
  if (!w || !!w.minimised === m.minimised) return;
  webWins.value = webWins.value.map((v) => (v.id === m.id ? { ...v, minimised: m.minimised } : v));
  if (!m.minimised) (reach(m.id), raise(m.id));
}
/** Its switcher card tapped (ShellBridge.openTask): back where it was, floating, on its page. */
powos.on("webwindows.show", (id: number) => bringBack(id));
/**
 * PP1 (the user, 11-01 15:48: "when I press PiP in Calculator, the PowOS title bar still sticks around"): its app went
 * to Android's PiP / a floating window by itself (WebWindows.kt pipEnter) - its frame and bar go at once; back
 * ([m.on] false: the PiP expanded) it shows where it was. Never the minimise path: the host already moved nothing.
 */
powos.on("webwindows.pip", (m: { id: number; on: boolean }) => onPip(m));
function onPip(m: { id: number; on: boolean }) {
  if (!!webWins.value.find((w) => w.id === m.id)?.pip === m.on) return;
  update(m.id, { pip: m.on || undefined });
  if (!m.on) bringBack(m.id);
}

// ---- the work area, and the host's events ----------------------------------------------------------------------------

/**
 * Where windows may be, viewport CSS px: the screen above home's foot (the dock and the bar - maximise and tiles stop
 * there, a desktop's reserved dock strip).
 */
export function workArea(): { left: number; top: number; right: number; bottom: number } {
  // The pages' own box (a side dock's column is not theirs: PS1, a maximised window never reaches the next page). The
  // box, not the page on screen: mid-swipe the area stays where the page rests.
  const pages = document.querySelector(".pages")?.getBoundingClientRect();
  const left = pages && pages.width > 0 ? Math.max(0, pages.left) : 0;
  const right = pages && pages.width > 0 ? Math.min(innerWidth, pages.right) : innerWidth;
  let bottom = innerHeight;
  for (const el of document.querySelectorAll<HTMLElement>(".home > .dock, .home > .bar")) {
    const r = el.getBoundingClientRect();
    if (r.height > 0 && r.top > innerHeight / 2) bottom = Math.min(bottom, r.top);
  }
  return { left, top: 0, right, bottom };
}

/**
 * Where tiles go: the work area below the status bar (a window's own bar under it couldn't be grabbed - the status
 * bar is a window above home's) and a gap above the dock.
 */
export function tileArea(): Area {
  const a = workArea();
  const inset = parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--inset-top")) || 0;
  return { ...a, top: Math.max(a.top, inset), bottom: a.bottom - TILE_GAP };
}

/**
 * RS5 (ww-resize.sh 11-08: 63-117 missed shell vsyncs per resize drag on the phone): the page-level layout that a
 * window's render reads - its pages' origin ([pageOrigin]), the tile area ([tileArea]) and the system strips - read
 * once per task and kept until the next one. Read in a render they forced a layout per read: each window's render runs
 * after the one before it wrote its frame's style, so every SwapHint's [aloneHalf] (a rect and a computed style) and
 * every Handles' [zoneKey] (8 zones x a rect and a computed style) laid the page out again - per pointer move, ~3 ms of
 * a gate frame's 3.5 (render scan: SwapHint 183 ms over 60 moves). None of the three moves with a window's own frame.
 */
let layoutCache: { origin: { x: number; y: number }; area: Area; strips: { top: number; bottom: number } } | null = null;
function renderLayout(): NonNullable<typeof layoutCache> {
  if (layoutCache) return layoutCache;
  layoutCache = { origin: pageOrigin(), area: tileArea(), strips: readStrips() };
  setTimeout(() => (layoutCache = null), 0);
  return layoutCache;
}

/**
 * The page on screen's top left AT REST (windows are page-local): its pages' box, never the page's own rect - that one
 * moves with the track's transform, so a window placed while the track slid (a page switch's spring: open from the
 * dock or switcher, cameHere + toPage) got up to a page width added to its x (11-03: Steam "on the very right side so
 * I can't work with it", Plasma's task at x 2136 on a 2268-wide screen).
 */
export function pageOrigin(): { x: number; y: number } {
  const page = document.querySelector(".page:not(.away)");
  const r = (page?.closest(".pages") ?? page)?.getBoundingClientRect();
  return r ? { x: r.left, y: r.top } : { x: 0, y: 0 };
}

/**
 * DB1 (the user, 2026-10-30: "We need to prevent windows from going up past the status bar"): a floating window's
 * place (page px) clamped so its bar never goes above the status bar's bottom and at least a third of the bar stays
 * on screen sideways and above the work area's bottom.
 */
export function clampPlace(x: number, y: number, w: number): { x: number; y: number } {
  const o = pageOrigin();
  const inset = parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--inset-top")) || 0;
  const a = workArea();
  // WC1: sideways against the work area, not the screen - a bar's third under the unfolded right dock is no grip (the
  // user 11-03: Steam "off the right edge ... couldn't be grabbed").
  const keep = Math.min(w / 3, a.right - a.left);
  const vx = Math.min(Math.max(x + o.x, a.left + keep - w), a.right - keep);
  const vy = Math.min(Math.max(y + o.y, inset), Math.max(inset, a.bottom - TITLE));
  return { x: vx - o.x, y: vy - o.y };
}

/**
 * WC1 (the user, 11-03: a window "off the right edge ... with no way to reach it"): window [w]'s frame change that
 * brings its bar back into reach ([clampPlace]), or null - it is reachable already. A maximised one fills the work area
 * NOW (a fold / rotation changed it), its floating frame kept; tiles (their tiling lays them out), full-screen, PiP and
 * quick windows are not floating frames.
 */
function reachOf(w: WebWin): Partial<WebWin> | null {
  if (w.quick || w.full || w.pip || tiledOn(w.id) != null) return null;
  return w.restore ? maxFillOf(w) : placeOf(w);
}

/** A maximised window's frame filling the work area now, or null: it does. */
function maxFillOf(w: WebWin): Partial<WebWin> | null {
  const a = workArea();
  const o = pageOrigin();
  const fill = { x: a.left - o.x, y: a.top - o.y, w: a.right - a.left, h: a.bottom - a.top };
  const same = fill.x === w.x && fill.y === w.y && fill.w === w.w && fill.h === w.h;
  return same ? null : fill;
}

/** A floating window's place with its bar in reach, or null: it is. */
function placeOf(w: WebWin): Partial<WebWin> | null {
  const at = clampPlace(w.x, w.y, w.w * (w.scale ?? 1));
  const [x, y] = [Math.round(at.x), Math.round(at.y)];
  return x !== Math.round(w.x) || y !== Math.round(w.y) ? { x, y } : null;
}

/** WC1: window [id] brought into reach (an open, a move or resize's end). */
export function reach(id: number) {
  const w = webWins.value.find((v) => v.id === id);
  const c = w && reachOf(w);
  if (c) update(id, c);
}

/** WC1: every window brought into reach - the screen changed (a fold / unfold, a rotation, a dock moving the work area). */
export function reachAll(): number {
  const moved = webWins.value.map((w) => [w, reachOf(w)] as const).filter(([, c]) => c);
  if (!moved.length) return 0;
  const by = new Map(moved.map(([w, c]) => [w.id, c]));
  webWins.value = webWins.value.map((w) => (by.has(w.id) ? { ...w, ...by.get(w.id) } : w));
  console.info(`[reach] ${moved.length} window(s) back on screen at ${innerWidth}x${innerHeight}`);
  return moved.length;
}

// After the resize's layout (the work area is the new screen's in the next frame): a fold, a rotation, a size change.
let reachFrame = 0;
const reachSoon = () => void (reachFrame ||= requestAnimationFrame(() => ((reachFrame = 0), reachAll())));
addEventListener("resize", reachSoon);
wideHome.subscribe(reachSoon);

/** Fills the work area, or goes back to where it was. */
export function toggleMaximise(id: number) {
  // A tile goes full screen as a free window (its tile closes up); restore brings back its floating frame.
  if (tiledOn(id) != null) untile(id, "float");
  const w = webWins.value.find((v) => v.id === id);
  if (!w) return;
  if (w.restore) return update(id, { ...w.restore, ...clampPlace(w.restore.x, w.restore.y, w.restore.w), restore: undefined });
  const a = workArea();
  const o = pageOrigin();
  update(id, { x: a.left - o.x, y: a.top - o.y, w: a.right - a.left, h: a.bottom - a.top, scale: 1, restore: { x: w.x, y: w.y, w: w.w, h: w.h } });
  raise(id);
}

/**
 * The window the user is in on home: the top one on the page on screen when it fills it (maximised, or its app full
 * screen) - or null (home, or a floating window over it). Over home the host names no task (a Linux window has none):
 * the switcher centres this one's card (ui/recents.tsx). The device, 11-02: opened over a maximised Dolphin, the
 * switcher centred on Lights.
 */
export function frontWindow(): WebWin | null {
  const page = shownPage();
  const top = webWins.value.findLast((w) => w.page === page && !w.minimised && !w.pip && !w.pending && !w.quick && !hiddenTab(w.id));
  return top && (top.restore || top.full) ? top : null;
}

export function minimise(id: number) {
  if (tiledOn(id) != null) return untile(id, "minimise");
  update(id, { minimised: true });
}

/** The host's maximise (a Linux window's full screen button, for now: WebWindows.fullScreen). */
powos.on("webwindows.control", (m: { id: number; action: string }) => {
  if (m.action === "minimise") minimise(m.id);
  else if (m.action === "maximise") toggleMaximise(m.id);
});

/** The windows pinned to home page [page] (not minimised), and its tiles' dividers: elements of that page, in z order. */
/**
 * RS5: the masks of [here]'s windows (bottom first) and their shadows in [box]: each one less the windows above it
 * ([holes]), written to its element's style when it changed - never by its render (a window under the one being
 * dragged keeps its vnode, its props unchanged). Preact never touches these properties (no render sets them).
 */
function cutAll(box: HTMLElement | null, here: WebWin[]) {
  if (!box) return;
  here.forEach((w, i) => {
    const above = here.slice(i + 1).filter(holed);
    const frame = box.querySelector<HTMLElement>(`.webwindow[data-wwid="${w.id}"]`);
    if (frame && !w.quick) setMask(frame, holes(above, { x: w.x, y: w.y, s: w.scale ?? 1 }));
    const shadow = box.querySelector<HTMLElement>(`.ww-shadow[data-wwid="${w.id}"]`);
    const b = frameBox(w);
    if (shadow) setMask(shadow, holes(above, { x: b.x - SHADOW_PAD, y: b.y - SHADOW_PAD, s: 1 }));
  });
}

const MASK_PROPS = ["maskImage", "maskSize", "maskPosition", "maskRepeat", "maskComposite"] as const;
/** The mask last written to each element (the same again is not written: no style change, no restyle). */
const maskOf = new WeakMap<HTMLElement, string>();
function setMask(el: HTMLElement, m: Record<string, string> | undefined) {
  const key = m ? MASK_PROPS.map((p) => m[p]).join("|") : "";
  if (maskOf.get(el) === key) return;
  maskOf.set(el, key);
  for (const p of MASK_PROPS) el.style[p] = m?.[p] ?? "";
}

/** The windows shown on home page [page], bottom first. */
const windowsHere = (page: number) => webWins.value.filter((w) => w.page === page && !w.minimised && !w.full && !w.pip && !hiddenTab(w.id));

export function WebWindowsOn({ page }: { page: number }) {
  const here = windowsHere(page);
  const strips = parkedOn(page);
  const revealed = fullBarOn(page);
  if (!here.length && !strips.length && !revealed && parkView.value?.page !== page) return null;
  const t = tilings.value[page];
  const o = renderLayout().origin;
  const box = useRef<HTMLDivElement>(null);
  // RS5: each window's and shadow's cut (the windows above it) written here, after this render, not as their props: a
  // resize or move of the top window changes only ITS props, so the windows under it skip the frame (render scan
  // 11-08: all four windows' AppWindowEl and WindowShadow rendered on each move of one, for their masks alone).
  useLayoutEffect(() => cutAll(box.current, here));
  return (
    // Clipped to its page (PS2): a window bigger than its page never shows on the next one.
    <div class="page-windows" ref={box}>
      {here.map((w, i) => (
        <WebWindowEl key={w.el ?? w.id} win={w} z={webWins.value.indexOf(w)} focused={i === here.length - 1} />
      ))}
      {t && dividers(t, renderLayout().area).map((d) => <DividerEl key={d.ratio} page={page} d={d} o={o} />)}
      <Previews page={page} o={o} />
      {strips.map((p) => <ParkStrip key={p.id} p={p} o={o} />)}
      {revealed && <FullBar key={revealed.id} win={revealed} o={o} />}
    </div>
  );
}

/** TB2: page [page]'s full-screen window whose bar is slid in ([fullReveal]), or null. */
function fullBarOn(page: number): WebWin | null {
  const id = fullReveal.value;
  return id == null ? null : (webWins.value.find((w) => w.id === id && w.page === page && w.full) ?? null);
}

/**
 * TB2 (docs/WEB_WINDOWS.md "Title bar: native parity"): a full-screen Linux window's bar, slid in by a pull from the
 * top (WebWindows.revealFull: the host crops the app's layer under it - the app keeps its size - and hides it again
 * 2250 ms after the last touch on it). AOSP's immersive header: the app, then back to a window and close.
 */
function FullBar({ win, o }: { win: WebWin; o: { x: number; y: number } }) {
  const press = (f: () => void) => ({ onPointerDown: (e: PointerEvent) => e.stopPropagation(), onClick: (e: MouseEvent) => (e.stopPropagation(), f()) });
  return (
    <div class="webwindow-title tile ww-full-bar" style={{ top: `${rootTokens().inset - o.y}px`, height: `${TITLE}px` }} onPointerDown={(e) => e.stopPropagation()}>
      <BarLabel win={win} aimed={null} merged={false} />
      <div class="ww-spacer" />
      <div class="ww-controls">
        <button class="ww-button" aria-label="Back to window" {...press(() => void backInWindow(win.id))}>
          <Mark kind="restore" />
        </button>
        <button class="ww-button ww-close" aria-label="Close" {...press(() => close(win.id))}>
          <Mark kind="close" />
        </button>
      </div>
    </div>
  );
}

/** A drag's ghosts on [page]: its tile drop, edge snap or park (TG3a). */
function Previews({ page, o }: { page: number; o: { x: number; y: number } }) {
  const d = [dropView.value, snapView.value, parkView.value, placeView.value].find((v) => v?.page === page);
  return d ? <DropPreview d={d} o={o} /> : null;
}

// ---- tiles -------------------------------------------------------------------------------------------------------------
//
// PowOS's own split screen (the user, 2026-10-30: "lets take full control and replace that too so we can unlock our
// own splitscreen capabilities maybe with like 3 of 4 apps at once"). A tiling is a state of one page's windows: a
// layout and which window is in which tile (a window in one is "tiled", the rest float above or below as usual). The
// windows' frames are the tiles' rects (the model stays x/y/w/h, so the host needs nothing new to place them); the
// dividers between tiles are DOM handles here ([DividerEl]). docs/WEB_WINDOWS.md "Tiles".

/**
 * "2h" left | right, "2v" top / bottom, "3" one big left + two stacked right, "4" a 2x2 grid. GL1 (a window docked
 * beside a tile, [dock]): "3r" two stacked left + one big right, "3t" one wide top + two below, "3b" two above + one
 * wide bottom, "3c" three columns, "3s" three rows.
 */
export type Layout = "2h" | "2v" | "3" | "3r" | "3t" | "3b" | "3c" | "3s" | "4";
export interface Tiling {
  layout: Layout;
  /** Window per tile, in [SLOTS] order; null: an empty tile (the next window opened on the page goes there). */
  ids: (number | null)[];
  /** The vertical divider's place (share of the work area's width) and the horizontal one's (of its height). */
  rx: number;
  ry: number;
}
export type Slot = "left" | "right" | "top" | "bottom" | "tl" | "tr" | "bl" | "br" | "grid" | "float";
const SLOTS: Record<Layout, string[]> = {
  "2h": ["left", "right"],
  "2v": ["top", "bottom"],
  "3": ["left", "rtop", "rbottom"],
  "3r": ["ltop", "lbottom", "right"],
  "3t": ["top", "bleft", "bright"],
  "3b": ["tleft", "tright", "bottom"],
  "3c": ["c1", "c2", "c3"],
  "3s": ["r1", "r2", "r3"],
  "4": ["tl", "tr", "bl", "br"],
};
/** Every layout but "4" as nested splits (leaves: slot indices, in slot order; the ratio each split takes). */
type Spec = number | ["x" | "y", "rx" | "ry", Spec, Spec];
const SPECS: Record<Exclude<Layout, "4">, Spec> = {
  "2h": ["x", "rx", 0, 1],
  "2v": ["y", "ry", 0, 1],
  "3": ["x", "rx", 0, ["y", "ry", 1, 2]],
  "3r": ["x", "rx", ["y", "ry", 0, 1], 2],
  "3t": ["y", "ry", 0, ["x", "rx", 1, 2]],
  "3b": ["y", "ry", ["x", "rx", 0, 1], 2],
  "3c": ["x", "rx", 0, ["x", "ry", 1, 2]],
  "3s": ["y", "ry", 0, ["y", "rx", 1, 2]],
};
/** Between tiles (CSS px): home shows through, the host's divider handle sits in it. */
export const TILE_GAP = 8;

/** Per home page (its number, as pages lists them). */
export const tilings = signal<Record<number, Tiling>>({});

interface Box {
  x: number;
  y: number;
  w: number;
  h: number;
}
type Area = ReturnType<typeof workArea>;

/**
 * Two apps split left | right unless the work area is clearly portrait: the unfolded screen (2268x2440) is portrait by
 * a hair and the user wants left | right there (2026-10-29: "two on top and bottom instead of one on the left, one on
 * the right" was the complaint about Android's split).
 */
const portrait = (a: Area) => a.bottom - a.top > 1.3 * (a.right - a.left);
const layoutFor = (n: number, a: Area): Layout => (n >= 4 ? "4" : n === 3 ? "3" : portrait(a) ? "2v" : "2h");

/** Each tile's rect, viewport CSS px, in [SLOTS] order. */
export function tileRects(t: Tiling, a: Area): Box[] {
  if (t.layout !== "4") {
    const rs = treeRects(treeOf(SPECS[t.layout], t, (i) => i), boxOf(a), TILE_GAP);
    return SLOTS[t.layout].map((_, i) => rs.get(i)!);
  }
  const g = TILE_GAP / 2;
  const xs = a.left + (a.right - a.left) * t.rx;
  const ys = a.top + (a.bottom - a.top) * t.ry;
  const r = (l: number, top: number, right: number, b: number): Box => ({ x: l, y: top, w: right - l, h: b - top });
  return [r(a.left, a.top, xs - g, ys - g), r(xs + g, a.top, a.right, ys - g), r(a.left, ys + g, xs - g, a.bottom), r(xs + g, ys + g, a.right, a.bottom)];
}

/**
 * A divider (viewport CSS px): a vertical one ("x") is the line at [pos] from [from] for [len]; [lo]..[hi] is the span
 * its ratio is of. [before]/[after]: the windows whose right (bottom) and left (top) edges follow it.
 */
export interface Divider {
  axis: "x" | "y";
  /** The tiling's ratio it sets. */
  ratio: "rx" | "ry";
  pos: number;
  from: number;
  len: number;
  lo: number;
  hi: number;
  before: number[];
  after: number[];
}

export function dividers(t: Tiling, a: Area): Divider[] {
  if (t.layout !== "4") return specDividers(SPECS[t.layout], t, boxOf(a));
  const at = (slots: number[]) => slots.map((i) => t.ids[i]).filter((v): v is number => v != null);
  const W = a.right - a.left;
  const H = a.bottom - a.top;
  const xs = a.left + W * t.rx;
  const ys = a.top + H * t.ry;
  const v = (before: number[], after: number[]): Divider => ({ axis: "x", ratio: "rx", pos: xs, from: a.top, len: H, lo: a.left, hi: a.right, before: at(before), after: at(after) });
  const h = (from: number, len: number, before: number[], after: number[]): Divider => ({ axis: "y", ratio: "ry", pos: ys, from, len, lo: a.top, hi: a.bottom, before: at(before), after: at(after) });
  return [v([0, 2], [1, 3]), h(a.left, W, [0, 1], [2, 3])];
}

const boxOf = (a: Area): Box => ({ x: a.left, y: a.top, w: a.right - a.left, h: a.bottom - a.top });

/** [spec] as a split tree of [t]'s ratios, its leaves [leaf](slot). */
function treeOf(spec: Spec, t: Tiling, leaf: (i: number) => number): Tree {
  if (typeof spec === "number") return leaf(spec);
  const [axis, r, a, b] = spec;
  return { axis, at: t[r], a: treeOf(a, t, leaf), b: treeOf(b, t, leaf) };
}

/** A spec'd layout's dividers: one per split, across its own box (the windows of each side before / after it). */
function specDividers(spec: Spec, t: Tiling, area: Box): Divider[] {
  const out: Divider[] = [];
  const ids = (s: Spec) => leaves(treeOf(s, t, (i) => i)).map((i) => t.ids[i]).filter((v): v is number => v != null);
  const walk = (s: Spec, b: Box) => {
    if (typeof s === "number") return;
    const [axis, ratio, a, c] = s;
    const x = axis === "x";
    const [lo, span] = x ? [b.x, b.w] : [b.y, b.h];
    const pos = lo + span * t[ratio];
    out.push({ axis, ratio, pos, from: x ? b.y : b.x, len: x ? b.h : b.w, lo, hi: lo + span, before: ids(a), after: ids(c) });
    const [ba, bc] = splitBox(b, axis, t[ratio], TILE_GAP);
    walk(a, ba);
    walk(c, bc);
  };
  walk(spec, area);
  return out;
}

/** The page whose tiling holds window [id], or null (it floats). */
export function tiledOn(id: number): number | null {
  for (const [p, t] of Object.entries(tilings.value)) if (t.ids.includes(id)) return Number(p);
  return null;
}

function setTiling(page: number, t: Tiling | null) {
  const next = { ...tilings.value };
  if (t) t = compact(t);
  if (t && t.ids.filter((v) => v != null).length >= 2) next[page] = t;
  else delete next[page];
  tilings.value = next;
  if (t) relayout(page);
}

/**
 * TG1 (the user, 10-31 00:17: "Why can't I expand grid further than a certain point? I mean, I guess it's expecting me
 * to have four apps"): never an empty tile. The grid follows the count - 2 apps fill the whole area (side by side, or
 * stacked when it is clearly portrait), 3 = one big + two, 4 = 2x2 - so a tiling with an empty slot (a corner snap, a
 * grid of fewer than four) is closed up to its windows, in slot order. Two left of a 2x2 grid in one column stack.
 */
function compact(t: Tiling): Tiling {
  if (!t.ids.includes(null)) return t;
  const at = t.ids.flatMap((v, i) => (v == null ? [] : [i]));
  const list = at.map((i) => t.ids[i] as number);
  if (list.length < 2) return { ...t, ids: list };
  const layout = compactLayout(t.layout, at);
  return { layout, ids: list, rx: layout === t.layout ? t.rx : 0.5, ry: layout === t.layout ? t.ry : 0.5 };
}

/** The layout for the windows left at slots [at] (2-4) of [was]: a 2-split keeps its direction, one column stacks. */
function compactLayout(was: Layout, at: number[]): Layout {
  if (at.length !== 2) return layoutFor(at.length, tileArea());
  if (was === "2h" || was === "2v") return was;
  return was === "4" && at[1] - at[0] === 2 ? "2v" : layoutFor(2, tileArea());
}

/** The page's tiled windows put at their tiles (full size, unzoomed, shown). */
function relayout(page: number) {
  const t = tilings.value[page];
  if (!t) return;
  const o = pageOrigin();
  const rects = tileRects(t, tileArea());
  webWins.value = webWins.value.map((w) => {
    const i = t.ids.indexOf(w.id);
    if (i < 0) return w;
    const r = rects[i];
    const untiled = w.untiled ?? w.restore ?? { x: w.x, y: w.y, w: w.w, h: w.h };
    return { ...w, x: Math.round(r.x - o.x), y: Math.round(r.y - o.y), w: Math.round(r.w), h: Math.round(r.h), scale: 1, restore: undefined, minimised: false, untiled };
  });
}

/** Floating windows on [page] other than [skip], topmost first. */
const floatingOn = (page: number, skip: number[]) =>
  webWins.value.filter((w) => w.page === page && !w.minimised && !w.full && !hiddenTab(w.id) && !skip.includes(w.id)).map((w) => w.id).reverse();

/**
 * Window [id] into tile [slot] of its page (the title bar's tile menu, a drag to a screen edge or corner): a half makes
 * a 2-split, a corner a 2x2 grid, "grid" tiles it with the page's other windows (2-4: the layout follows the count),
 * "float" takes it out. The page's other tiled windows keep a tile while there is one; an empty half of a new 2-split
 * takes the page's topmost floating window (two windows, one split - as Android's), an empty corner stays empty.
 */
export function tile(id: number, slot: Slot) {
  if (slot === "float") return untile(id, "float");
  const plan = slotPlan(id, slot);
  if (!plan) return;
  const { page, others, tiling } = plan;
  const { layout, ids } = tiling;
  // Alone: no tiling of one (SC1) - a half or a corner is just where it goes, a floating window at that tile's rect.
  if (plan.alone) return snapAlone(id, layout, ids.indexOf(id));
  // Tiled windows that found no tile float again.
  const left = others.filter((o) => !ids.includes(o));
  setTiling(page, tiling);
  for (const o of left) refloat(o);
  console.info(`[tiles] page ${page}: ${layout} [${ids.join(",")}] (${slot} for window ${id})`);
}

/** What [tile] (id, slot) makes, slot not "float": the page, its other tiled windows, the tiling (alone: no tiling of one). */
function slotPlan(id: number, slot: Slot) {
  const w = webWins.value.find((v) => v.id === id);
  if (!w || slot === "float") return null;
  const page = w.page;
  const others = (tilings.value[page]?.ids ?? []).filter((v): v is number => v != null && v !== id);
  const { layout, ids } = slot === "grid" ? gridOf(page, id, others) : slotOf(page, id, slot, others);
  const tiling: Tiling = { layout, ids, rx: 0.5, ry: 0.5 };
  return { page, others, tiling, alone: ids.filter((v) => v != null).length < 2 };
}

/** The rect (viewport CSS px) window [id] takes after [tile] (id, slot): its snap's preview ([snapView]). */
function slotRect(id: number, slot: Slot): Box | null {
  const plan = slotPlan(id, slot);
  if (!plan) return null;
  const t = plan.alone ? plan.tiling : compact(plan.tiling);
  return tileRects(t, tileArea())[t.ids.indexOf(id)] ?? null;
}

/** Window [id], the page's only one to tile, at tile [i] of [layout]'s rect (restore: its frame before). */
function snapAlone(id: number, layout: Layout, i: number) {
  const w = webWins.value.find((v) => v.id === id);
  if (!w || i < 0) return;
  const r = tileRects({ layout, ids: [], rx: 0.5, ry: 0.5 }, tileArea())[i];
  const o = pageOrigin();
  // Not "maximised" (no restore): a maximised window's bar merges into the status bar and squeezes it (TB1).
  update(id, { x: Math.round(r.x - o.x), y: Math.round(r.y - o.y), w: Math.round(r.w), h: Math.round(r.h), scale: 1, restore: undefined });
  raise(id);
  console.info(`[tiles] window ${id} alone: snapped to ${layout} tile ${i}, no tiling`);
}

/**
 * The switcher's split screen with web windows on (the user, 2026-10-30: "like 3 of 4 apps at once"): [apps] (2-4, by
 * key) opened as web windows on the home page on screen and tiled in that order. False when one can't be a web window
 * (not resizeable, ...): the caller uses Android's split.
 */
export async function tileApps(apps: { key: string; label: string }[]): Promise<boolean> {
  const page = shownPage();
  const ids: number[] = [];
  for (const a of apps.slice(0, 4)) {
    // TF1 (ask 1a1924af639, "I can't interact with this": Chrome and Discord full:true on the phone): a full-screen app
    // comes back into its window BEFORE openWindow - whose "to the front as its full-screen app" fired the host's
    // fullScreen again; its late "webwindows.full" on took the tile out, the last tile went full screen too (SC1), and
    // both apps sat full screen with no PowOS bar.
    const full = webWins.value.find((w) => w.key === a.key && w.full);
    if (full) await backInWindow(full.id);
    const id = await openWindow(a.key, a.label, page);
    if (id == null) {
      console.info(`[tiles] ${a.key} can't be a web window: Android's split instead`);
      return false;
    }
    ids.push(id);
  }
  tileWindows(page, ids);
  return true;
}

/** Full-screen app [id] back in its window (the host's toWindow; with none, the page's flag alone). */
async function backInWindow(id: number) {
  if (powos.webwindows?.toWindow) await powos.webwindows.toWindow(id).catch(() => false);
  update(id, { full: false });
}

/** "grid": [id] first, then the page's tiled windows, then its floating ones (topmost first), up to 4. */
function gridOf(page: number, id: number, others: number[]): { layout: Layout; ids: (number | null)[] } {
  const all = [id, ...others, ...floatingOn(page, [id, ...others])].slice(0, 4);
  const layout = all.length >= 2 ? layoutFor(all.length, tileArea()) : "4";
  return { layout, ids: SLOTS[layout].map((_, i) => all[i] ?? null) };
}

const HALVES: Record<string, Layout> = { left: "2h", right: "2h", top: "2v", bottom: "2v" };

/** A half or a corner: [id] there, the other tiled windows in the rest (a half: then the topmost floating one). The
 * empty corners close up ([compact]). */
function slotOf(page: number, id: number, slot: Slot, others: number[]): { layout: Layout; ids: (number | null)[] } {
  const layout = HALVES[slot] ?? "4";
  const ids: (number | null)[] = SLOTS[layout].map((s) => (s === slot ? id : null));
  // A corner takes the other tiled windows; with none, the topmost floating one (two corner snaps: a 2-split, TG1).
  const floating = floatingOn(page, [id, ...others]);
  const fill = layout !== "4" ? [...others, ...floating] : others.length ? others : floating.slice(0, 1);
  for (const o of fill) {
    const i = ids.indexOf(null);
    if (i < 0) break;
    ids[i] = o;
  }
  return { layout, ids };
}

/** Windows [ids] (2-4, in order) tiled on page [page]: the switcher's split screen. */
export function tileWindows(page: number, ids: number[]) {
  const list = ids.slice(0, 4);
  if (!list.length) return;
  const layout = layoutFor(Math.max(2, list.length), tileArea());
  for (const id of list) toPageOf(id, page);
  setTiling(page, { layout, ids: SLOTS[layout].map((_, i) => list[i] ?? null), rx: 0.5, ry: 0.5 });
  console.info(`[tiles] page ${page}: ${layout} [${list.join(",")}] (split screen)`);
}

/** Back to its floating frame, on top. */
function refloat(id: number) {
  const w = webWins.value.find((v) => v.id === id);
  if (!w) return;
  update(id, { ...(w.untiled ?? {}), untiled: undefined });
  // WC1: the floating frame kept from before its tile may be the old screen's (a fold / rotation while tiled).
  reach(id);
  raise(id);
}

/**
 * Window [id] out of its tiling: "float" back to its floating frame, "minimise" to the dock (its frame the floating
 * one), "keep" where it is now (dragged out), "gone" (closed). The others close up: 2-4 take the layout for their
 * count, a last one alone fills the work area (as Android's split ending: the other app full screen; restore gives
 * its floating frame back).
 */
function untile(id: number, how: "float" | "minimise" | "keep" | "gone") {
  const page = tiledOn(id);
  if (page == null) return;
  const t = tilings.value[page];
  const rest = t.ids.filter((v): v is number => v != null && v !== id);
  leave(id, how);
  if (rest.length >= 2) closeUp(page, t, rest);
  else {
    setTiling(page, null);
    // SC1 (the user, 10-31 00:06: "When there's only like one split-screen application left, it should return to like
    // a normal full-screen application"): no tiling of one - the last window goes full screen at once, the bar's way.
    if (rest.length) lastOfSplit(rest[0]);
  }
  console.info(`[tiles] window ${id} out of page ${page}'s tiles (${how}); ${rest.length} left`);
}

/** The leaving window's own frame (see [untile]). */
function leave(id: number, how: "float" | "minimise" | "keep" | "gone") {
  const w = webWins.value.find((v) => v.id === id);
  if (how === "float") refloat(id);
  else if (how === "minimise") update(id, { ...(w?.untiled ?? {}), untiled: undefined, minimised: true });
  else if (how === "keep") update(id, { untiled: undefined });
}

/** A 2-split's direction kept as one of its tiles goes: rows stay rows, columns columns. */
const TWO_OF: Partial<Record<Layout, Layout>> = { "2h": "2h", "2v": "2v", "3c": "2h", "3s": "2v" };

/** The [rest] (2-3) of [t] closed up: a 2-split keeps its direction, the split stays where it was if nothing moved. */
function closeUp(page: number, t: Tiling, rest: number[]) {
  const two = rest.length === 2 ? TWO_OF[t.layout] : undefined;
  const layout = two ?? layoutFor(rest.length, tileArea());
  const keep = layout === t.layout && !t.ids.includes(null);
  setTiling(page, { layout, ids: SLOTS[layout].map((_, i) => rest[i] ?? null), rx: keep ? t.rx : 0.5, ry: keep ? t.ry : 0.5 });
}

/**
 * The last window of a split: back at its floating frame (what "restore" gives back), then full screen as the bar's
 * button does it (F1: a real full-screen app on the host; with none, the work area).
 */
function lastOfSplit(id: number) {
  const w = webWins.value.find((v) => v.id === id);
  if (!w) return;
  update(id, { ...(w.untiled ?? {}), untiled: undefined, restore: undefined });
  fullScreen(id);
}

/**
 * A new window on [page] takes the first empty tile of its tiling - or, with no tiling there, the free half beside the
 * page's one window snapped to a left or right half (SF1, ask 1a1a1004151, 11-03: "When one window is docked to the
 * side and I open another window. It should be docked to other side."): the two become a real 2-split.
 */
function fillEmptyTile(page: number, id: number) {
  const t = tilings.value[page];
  if (!t) return fillOtherHalf(page, id);
  const i = t.ids.indexOf(null);
  if (i < 0) return;
  const ids = [...t.ids];
  ids[i] = id;
  setTiling(page, { ...t, ids });
}

/**
 * SF1: new window [id] on [page] (no tiling there) docked to the free side: when exactly one other shown window there
 * is snapped alone to a left or right half ([aloneHalf]), the two tile as a 2h split, the snapped one keeping its side
 * (its frame unchanged: a half of a 2h split at 0.5 is the same rect). A floating or maximised window, top/bottom
 * halves, or both halves taken (two lone halves): the new window floats as before.
 */
function fillOtherHalf(page: number, id: number) {
  const halves = floatingOn(page, [id]).flatMap((o) => {
    const w = webWins.value.find((v) => v.id === o);
    const half = w && aloneHalf(w);
    return half?.layout === "2h" ? [{ id: o, i: half.i }] : [];
  });
  if (halves.length !== 1) return;
  const [a] = halves;
  const ids = a.i === 0 ? [a.id, id] : [id, a.id];
  setTiling(page, { layout: "2h", ids, rx: 0.5, ry: 0.5 });
  raise(id);
  console.info(`[tiles] page ${page}: window ${id} opened beside window ${a.id}'s ${a.i ? "right" : "left"} half -> 2h [${ids.join(",")}]`);
}

// ---- GL1: a dragged window docked into the tiles (Golden Layout's model; the zones: ui/tiledrop.ts) -------------------

/** What a drop makes: the page's new tiling, the tiled windows it puts out (a swap), the dropped window's tile rect. */
interface Landing {
  page: number;
  id: number;
  rect: Box;
  tiling: Tiling;
  out: number[];
}

/** The drop in progress (a floating window's bar dragged over its page's tiles): its zone and landing ([DropPreview]). */
export const dropView = signal<(Landing & { zone: Zone }) | null>(null);
/** A bar drag's edge snap in progress (no tile or tab drop there): the rect window [id] would take ([DropPreview]). */
export const snapView = signal<{ id: number; page: number; slot: Slot; rect: Box } | null>(null);
/** A drag's previews gone (let go, cancelled). */
const clearAim = () => (dropView.value = tabView.value = snapView.value = parkView.value = placeView.value = null);

// ---- WG1: the free region around the finger as the snap target beside the widgets (ui/tiledrop.ts freeRegion) -------
//
// The user, 10-31 20:19: "fill out the space between the widgets ... And for the floating window, show a preview of
// where it will appear." One ghost ([DropPreview]) for both: the free region's rect, or the floating rect the window
// opens at; the drop lands exactly on the ghost.

/** Home's grid on a page, from ui/grid.tsx ([provideHomeGrid]: it imports this module, so it hands the grid in). */
export interface HomeGrid {
  cols: number;
  rows: number;
  /** The tiles' spans (cells). */
  taken: Box[];
  /** Cell (0, 0)'s top left on screen, viewport CSS px, and a cell's size. */
  left: number;
  top: number;
  cellW: number;
  cellH: number;
}
let homeGrid: ((page: number) => HomeGrid | null) | null = null;
export const provideHomeGrid = (f: (page: number) => HomeGrid | null) => void (homeGrid = f);
/** A cell span's rect on screen (viewport CSS px). */
const cellBox = (g: HomeGrid, c: Box): Box => ({ x: g.left + c.x * g.cellW, y: g.top + c.y * g.cellH, w: c.w * g.cellW, h: c.h * g.cellH });

/** A drop on home's free space: "region" (the free region around the finger) or "float" (where it floats). Viewport px. */
export interface Place {
  page: number;
  kind: "region" | "float";
  rect: Box;
}
/** A floating window's drag over home: the place it lands ([DropPreview]); [id]: the window. */
export const placeView = signal<(Place & { id: number }) | null>(null);

/** Page [page]'s grid where web windows are (unfolded); null folded or not measured yet. */
const gridOn = (page: number) => {
  const g = wideHome.value ? homeGrid?.(page) : null;
  return g && g.cellW > 0 && g.cellH > 0 ? g : null;
};

/** The free region around (x, y) on [page]: the tiles kept [TILE_GAP] off, inside the tile area; null if too small. */
function regionAt(page: number, x: number, y: number): Box | null {
  const g = gridOn(page);
  if (!g) return null;
  const a = tileArea();
  const bounds = { x: a.left + TILE_GAP, y: a.top + TILE_GAP, w: a.right - a.left - 2 * TILE_GAP, h: a.bottom - a.top - TILE_GAP };
  const r = freeRegion(bounds, g.taken.map((c) => cellBox(g, c)), { x, y }, TILE_GAP);
  return r && r.w >= MIN_W && r.h >= MIN_H ? r : null;
}

/**
 * Where a new window of [size] let go at (x, y) on [page] goes (the dock's drag-out, dockout.tsx): the free region
 * there, else floating at [size] centred under the finger, kept inside the tile area. null folded (no web windows).
 */
export function placeAt(page: number, x: number, y: number, size = cascade()): Place | null {
  if (!wideHome.value) return null;
  const region = regionAt(page, x, y);
  if (region) return { page, kind: "region", rect: region };
  const a = tileArea();
  const w = Math.min(size.w, a.right - a.left);
  const h = Math.min(size.h, a.bottom - a.top);
  const left = Math.min(Math.max(x - w / 2, a.left), a.right - w);
  const top = Math.min(Math.max(y - h / 2, a.top), a.bottom - h);
  return { page, kind: "float", rect: { x: left, y: top, w, h } };
}

/** Window [id]'s bar dragged to (x, y): the free region there, else where it floats now (its own frame); or null. */
function placeAim(id: number, x: number, y: number): (Place & { id: number }) | null {
  const w = webWins.value.find((v) => v.id === id);
  if (!w || !gridOn(w.page)) return null;
  const region = regionAt(w.page, x, y);
  if (region) return { id, page: w.page, kind: "region", rect: region };
  const o = pageOrigin();
  const s = w.scale ?? 1;
  return { id, page: w.page, kind: "float", rect: { x: w.x + o.x, y: w.y + o.y, w: w.w * s, h: w.h * s } };
}

/** Window [id] at [rect] (viewport px) exactly: its frame there, its zoom and scale kept, on top. */
export function placeWindow(id: number, rect: Box) {
  const w = webWins.value.find((v) => v.id === id);
  if (!w) return;
  const o = pageOrigin();
  const s = w.scale ?? 1;
  update(id, { x: rect.x - o.x, y: rect.y - o.y, w: rect.w / s, h: rect.h / s, restore: undefined });
  raise(id);
  console.info(`[place] window ${id} at ${Math.round(rect.x)},${Math.round(rect.y)} ${Math.round(rect.w)}x${Math.round(rect.h)}`);
}

/**
 * A NEW window of app [key] on [page] (the dock's drag-out, an icon's "new window"; the user 11-03: "if I want to open up
 * another chrome instance on this page I could"), where a tap fronts its window: with no window yet, as a tap; with one,
 * a second instance - Android: the host forces one for every app that can run twice (else the app's window moves here);
 * Linux: a second process with its own placeholder (a new toplevel takes only a waiting placeholder, never the running
 * window). Its id, or null (not a web window).
 */
export async function openNewWindow(key: string, label: string, page: number): Promise<number | null> {
  if (!webWins.value.some((w) => w.key === key && !w.failed)) return key.startsWith("l:") ? linuxWindow(key, label, page) : openWindow(key, label, page);
  if (!wideHome.value || !(await enabled())) return null;
  if (key.startsWith("l:")) return linuxPlaceholder(key, label, page);
  return key.startsWith("a:") ? openHost(key, label, page, true) : null;
}

/** A new window for app [key] on [page] at [p] (the dock's drag-out): false when it can't be a web window. */
export async function openWindowAt(key: string, label: string, p: Place): Promise<boolean> {
  const id = await openNewWindow(key, label, p.page);
  if (id == null) return false;
  if (tiledOn(id) == null) placeWindow(id, p.rect);
  return true;
}

/** [t] as a split tree of its windows ("4": two columns of two). */
function treeOfTiling(t: Tiling): Tree {
  const id = (i: number) => t.ids[i] as number;
  if (t.layout !== "4") return treeOf(SPECS[t.layout], t, id);
  const col = (a: number, b: number): Tree => ({ axis: "y", at: t.ry, a: id(a), b: id(b) });
  return { axis: "x", at: t.rx, a: col(0, 2), b: col(1, 3) };
}

/** Window [id] dropped at [zone] of page [page]'s tiling: what it makes, or null (a fifth tile, an empty tile...). */
function landing(page: number, id: number, zone: Zone): Landing | null {
  const t = tilings.value[page];
  if (!t || t.ids.includes(null) || t.ids.includes(id)) return null;
  if (zone.kind !== "swap" && t.ids.length >= 4) return null;
  const target = zone.tile < 0 ? -1 : (t.ids[zone.tile] as number);
  const tiling = tilingOf(dropInto(treeOfTiling(t), zone, target, id));
  const rects = tileRects(tiling, tileArea());
  // As the dividers (TG2, the native split's minimum): a drop that would make a tile smaller than [MIN_TILE] is no zone.
  if (rects.some((r) => r.w < MIN_TILE.x || r.h < MIN_TILE.y)) return null;
  const rect = rects[tiling.ids.indexOf(id)];
  return rect ? { page, id, rect, tiling, out: zone.kind === "swap" ? [target] : [] } : null;
}

/** A split tree of 2-4 windows as a tiling (TG1: the layout follows the count; 4 is always the 2x2 grid). */
function tilingOf(tree: Tree): Tiling {
  const ids = leaves(tree);
  if (typeof tree === "number" || ids.length >= 4) return fourOf(tree);
  if (ids.length === 2) return tree.axis === "x" ? { layout: "2h", ids, rx: tree.at, ry: 0.5 } : { layout: "2v", ids, rx: 0.5, ry: tree.at };
  return threeOf(tree, ids);
}

/** Three windows: one beside a split of two ("3", "3r", "3t", "3b") or three in a row ("3c", "3s"). */
function threeOf(tree: Exclude<Tree, number>, ids: number[]): Tiling {
  const leafFirst = typeof tree.a === "number";
  const inner = (leafFirst ? tree.b : tree.a) as Exclude<Tree, number>;
  const row = inner.axis === tree.axis;
  const layout = THREES[`${tree.axis}${row ? "=" : leafFirst ? "<" : ">"}`];
  // Three in a row: as spec'd (the leaf first) its ratios; else the same lines as shares of the whole - the tiles not
  // split keep their size (the native split's way: a neighbour added never resizes the others).
  const first = tree.at * inner.at;
  const [r1, r2] = !row || leafFirst ? [tree.at, inner.at] : [first, (tree.at - first) / (1 - first)];
  return tree.axis === "x" ? { layout, ids, rx: r1, ry: r2 } : { layout, ids, ry: r1, rx: r2 };
}
/** A 3-tree's layout by its root's axis and its leaf's side ("<" first, ">" second, "=" the other two split the same way). */
const THREES: Record<string, Layout> = { "x<": "3", "x>": "3r", "y<": "3t", "y>": "3b", "x=": "3c", "y=": "3s" };

/** Four windows in the 2x2 grid, each in the quarter nearest where [tree] would put it (the dropped one where previewed). */
function fourOf(tree: Tree): Tiling {
  const want = treeRects(tree, boxOf(tileArea()), TILE_GAP);
  const grid = tileRects({ layout: "4", ids: [], rx: 0.5, ry: 0.5 }, tileArea());
  const far = (a: Box, b: Box) => Math.hypot(a.x + a.w / 2 - b.x - b.w / 2, a.y + a.h / 2 - b.y - b.h / 2);
  const cost = (p: number[]) => p.reduce((s, id, i) => s + far(want.get(id)!, grid[i]), 0);
  const best = perms(leaves(tree).slice(0, 4)).reduce((m, p) => (cost(p) < cost(m) ? p : m));
  return { layout: "4", ids: best, rx: 0.5, ry: 0.5 };
}

const perms = (a: number[]): number[][] => (a.length <= 1 ? [a] : a.flatMap((v, i) => perms([...a.slice(0, i), ...a.slice(i + 1)]).map((p) => [v, ...p])));

/**
 * Window [id]'s bar dragged to (x, y): the drop it would make there, previewed; a haptic tick as the target changes.
 * Another window's bar (floating or tiled: WT1) takes it as a tab; else, [docks] (a floating window's drag), the tiles'
 * zones (GL1).
 */
function aim(id: number, x: number, y: number, docks = true) {
  const a = aimAt(id, x, y, docks);
  const was: Aim = { next: dropView.value, tab: tabView.value, snap: snapView.value, park: parkView.value, place: placeView.value };
  if (aimKey(a) === aimKey(was)) return followFloat(a);
  if (a.next || a.tab || a.snap || a.park || a.place?.kind === "region") hapticTick();
  dropView.value = a.next;
  tabView.value = a.tab;
  snapView.value = a.snap;
  parkView.value = a.park;
  placeView.value = a.place;
}

/** What a bar drag at (x, y) aims at: a park, a tab drop, a tile drop, an edge snap or home's free cells (at most one). */
function aimAt(id: number, x: number, y: number, docks: boolean): Aim {
  // TG3a: a window dragged out of the tiles parks at the screen's very edge (beyond the snap) - before anything else.
  const none: Aim = { next: null, tab: null, snap: null, park: null, place: null };
  const park = docks ? null : parkAim(id, x);
  if (park) return { ...none, park };
  if (carryTo(x) != null) return none;
  const tab = tabTarget(id, x, y);
  if (tab) return { ...none, tab };
  const next = docks ? tileDrop(id, x, y) : null;
  if (next) return { ...none, next };
  const snap = snapAim(id, x, y);
  if (snap || !docks) return { ...none, snap };
  // WG1: no tile, tab or edge there - a floating window over home fills the free region there, else floats.
  return { ...none, place: placeAim(id, x, y) };
}
/** The same target as before: only a floating ghost moves (it follows the window); the rest stand still. */
function followFloat(a: Aim) {
  if (a.place?.kind === "float") placeView.value = a.place;
}

interface Aim {
  next: ReturnType<typeof tileDrop>;
  tab: ReturnType<typeof tabTarget>;
  snap: ReturnType<typeof snapAim>;
  park: ReturnType<typeof parkAim>;
  place: ReturnType<typeof placeAim>;
}
const placeKey = (p: Aim["place"]) => (p?.kind === "region" ? `${Math.round(p.rect.x)},${Math.round(p.rect.y)},${Math.round(p.rect.w)},${Math.round(p.rect.h)}` : (p?.kind ?? ""));
const aimKey = (a: Aim) => `${dropKey(a.next?.zone)}|${tabKey(a.tab)}|${a.snap?.slot ?? ""}|${a.park?.side ?? ""}|${placeKey(a.place)}`;

/** The edge snap window [id]'s bar makes let go at (x, y) ([release]'s fallback): its slot and rect, or null. */
function snapAim(id: number, x: number, y: number) {
  const slot = snapSlot(x, y);
  const rect = slot && slotRect(id, slot);
  const w = rect && webWins.value.find((v) => v.id === id);
  return w && slot && rect ? { id, page: w.page, slot, rect } : null;
}

/**
 * WT1: the tab drop window [id]'s bar makes at (x, y) - another window's bar there, or (WT3) anywhere on a maximised
 * window but the snap edges: the group stays maximised, the dropped one its shown tab ([joinStack]) - or null.
 */
function tabTarget(id: number, x: number, y: number) {
  const z = tabAt(x, y, barsUnder(id), snapSlot(x, y) == null);
  return z?.kind === "tab" ? { id, target: z.tile, at: z.at } : null;
}

/** GL1: the tile drop window [id] makes at (x, y) over its page's tiles (a tile's bar is the tab drop's), or null. */
function tileDrop(id: number, x: number, y: number) {
  const w = webWins.value.find((v) => v.id === id);
  const t = w && tilings.value[w.page];
  if (!w || !t) return null;
  const grid = { tiles: tileRects(t, tileArea()), area: boxOf(tileArea()), bar: TITLE };
  return dropAt(x, y, grid, (z) => (z.kind === "tab" ? null : landing(w.page, id, z)));
}

/** Let go of window [id]'s bar drag at (x, y): the previewed tab drop or tile drop, else an edge snap. */
function release(id: number, x: number, y: number) {
  const drop = dropView.value;
  const tab = tabView.value;
  const park = parkView.value;
  const place = placeView.value;
  clearAim();
  if (park?.id === id) return parkWindow(park);
  if (tab?.id === id) return joinStack(tab);
  // GL1: over the tiles, the previewed drop; with none (no tiles yet, a full grid), an edge snap as before.
  if (drop?.id === id) return dock(drop);
  const to = carryTo(x);
  if (to != null) return carry(id, to);
  const slot = snapSlot(x, y);
  if (slot) return tile(id, slot);
  landPlace(id, place);
}

/** Window [id] let go on home's free space: the free region's ghost filled; floating it stays (its frame is the ghost). */
function landPlace(id: number, place: (Place & { id: number }) | null) {
  if (place?.kind === "region" && place.id === id) placeWindow(id, place.rect);
  // WC1: a floating drag's end - the moves clamp the unscaled width, a pinch-zoomed frame can still end out of reach.
  reach(id);
}

/** The previewed drop made: the new tiling, a swapped-out window floating again, the tiles re-flowing ([reflow]). */
function dock(l: Landing) {
  reflow(l.page);
  setTiling(l.page, l.tiling);
  for (const o of l.out) refloat(o);
  holdAppSizes(l.tiling.ids);
  console.info(`[tiles] window ${l.id} docked: page ${l.page} ${l.tiling.layout} [${l.tiling.ids.join(",")}]`);
}

// ---- EC1: a window carried to the next page ---------------------------------------------------------------------------
//
// A window's bar let go at the screen's very left / right edge - or past the work area, over a side dock's column -
// goes to the page that way, and home with it (the old floating windows' "windows.edge", desktops.ts toEdge). E2E 194 step 38: the
// right edge never carried - a finger at the screen's edge was over the unfolded right dock, outside the work area,
// and only an edge snap (to the half) was ever made there (the left edge's "pass" was home already on page 0: it
// snapped to the half too). The zone: past the work area (over a side dock's column, from the dock's inner edge) or
// the screen's last [CARRY_PX] - a finger slid off the screen pins there. The edge snap keeps the strip inside the
// work area (WG1 drops at a.left/a.right +-4 still snap).
// No page that way: the edge snap, as before.

/** The finger this near the screen's left/right edge (CSS px), or past the work area's, carries the window that way. */
const CARRY_PX = 2;

/** The page a bar let go at [x] carries its window to, or null: not at an edge, or no page that way. */
function carryTo(x: number): number | null {
  const a = workArea();
  const side = x < a.left || x <= CARRY_PX ? -1 : x > a.right || x >= innerWidth - CARRY_PX ? 1 : 0;
  return side ? pageBeside(side) : null;
}

/** Window [id] onto page [to], floating, on top; home goes there with it. */
function carry(id: number, to: number) {
  if (tiledOn(id) != null) untile(id, "keep");
  cameHere(id, to);
  update(id, insideArea(id));
  console.info(`[windows] window ${id} carried to page ${to}`);
  toPage(to);
}

/**
 * Window [id]'s frame pulled whole inside the work area (page-local; every page rests at the same origin). E2E 197
 * step 39: a carry kept the frame where the bar was let go - past the screen's edge, its bar under the right dock - so
 * the next grab of its bar hit the dock's Chrome icon instead.
 */
function insideArea(id: number): Partial<WebWin> {
  const w = webWins.value.find((v) => v.id === id);
  if (!w) return {};
  const a = tileArea();
  const o = pageOrigin();
  const s = w.scale ?? 1;
  const [fw, fh] = [w.w * s, w.h * s];
  const x = Math.max(a.left, Math.min(w.x + o.x, a.right - fw));
  const y = Math.max(a.top, Math.min(w.y + o.y, a.bottom - fh));
  return { x: Math.round(x - o.x), y: Math.round(y - o.y) };
}

// ---- TG3a: the edge drawer - a tile parked at the screen's edge (the native split's SplitDrawer, FLOAT_PULL) ----------
//
// The user, 10-31 01:37: "There's more clues we can steal from the Android version of the grid. For example, the drawer
// stuff that we made, I think is really great." A tiled window's bar dragged so the finger is within [PARK_PX] of the
// screen's left or right edge (past the edge snap) and let go there parks it: out of the tiling (the rest close up as
// for any untile), minimised (its layer hidden, the app running: the minimise path), and a slim strip with its icon on
// that edge. A tap on the strip, or a drag from it inward, brings it back into the tiles on that side. Folded there
// are no tiles, so nothing parks.

/** The finger this near the screen's left / right edge (CSS px) parks a window dragged out of the tiles. */
const PARK_PX = 12;
/** A strip: [PARK_W] wide, [PARK_H] tall, [PARK_GAP] between strips stacked on one edge, vertically centred. */
const PARK_W = 28;
const PARK_H = 72;
const PARK_GAP = 8;

export interface Parked {
  id: number;
  page: number;
  side: "left" | "right";
}
/** The parked windows, in the order they were parked (one strip each, stacked per edge). */
export const parked = signal<Parked[]>([]);
/** A park in progress: the strip window [id] would get, previewed ([DropPreview]). */
export const parkView = signal<(Parked & { rect: Box }) | null>(null);

/** Page [page]'s strips: windows still there and still minimised (a dock tap that brought one back ends its strip). */
const parkedOn = (page: number) => parked.value.filter((p) => p.page === page && webWins.value.some((w) => w.id === p.id && w.minimised));

/** The strip rect (viewport CSS px) of the [i]th of [n] strips on [side]. */
function stripRect(side: Parked["side"], i: number, n: number): Box {
  const top = innerHeight / 2 - (n * PARK_H + (n - 1) * PARK_GAP) / 2 + i * (PARK_H + PARK_GAP);
  return { x: side === "left" ? 0 : innerWidth - PARK_W, y: Math.round(top), w: PARK_W, h: PARK_H };
}

/** The park window [id]'s bar makes with the finger at [x]: its edge and strip, or null (not at an edge). */
function parkAim(id: number, x: number) {
  const side = x <= PARK_PX ? "left" : x >= innerWidth - PARK_PX ? "right" : null;
  const w = side && webWins.value.find((v) => v.id === id);
  if (!w || !side) return null;
  const on = parkedOn(w.page).filter((p) => p.side === side && p.id !== id);
  return { id, page: w.page, side, rect: stripRect(side, on.length, on.length + 1) } as Parked & { rect: Box };
}

/** Window [p.id] parked: minimised (out of the tiles if it still is in them), a strip on its edge. */
function parkWindow(p: Parked) {
  minimise(p.id);
  parked.value = [...parked.value.filter((v) => v.id !== p.id), { id: p.id, page: p.page, side: p.side }];
  hapticConfirm();
  console.info(`[tiles] window ${p.id} parked on page ${p.page}'s ${p.side} edge`);
}

/**
 * A strip tapped (or dragged inward): its window back into the page's tiles on the side it was parked - a new full-height
 * column there when the page has a tiling, else a 2-split with the page's window (a full-screen one back in a window
 * first, as [tileApps]). The strip goes.
 */
export async function unpark(id: number) {
  const p = parked.value.find((v) => v.id === id);
  parked.value = parked.value.filter((v) => v.id !== id);
  const w = webWins.value.find((v) => v.id === id);
  if (!p || !w) return;
  update(id, { page: p.page, minimised: false });
  const l = tilings.value[p.page] && landing(p.page, id, { kind: "outer", tile: -1, side: p.side });
  if (l) return dock(l);
  for (const f of webWins.value.filter((v) => v.page === p.page && v.full && v.id !== id)) await backInWindow(f.id);
  tile(id, p.side);
  console.info(`[tiles] window ${id} unparked into page ${p.page}'s ${p.side} side`);
}

/** A parked window's strip: its icon on the shared glass; the accent outline while a finger is on it. */
function ParkStrip({ p, o }: { p: Parked; o: { x: number; y: number } }) {
  const [held, setHeld] = useState(false);
  const from = useRef<number | null>(null);
  const on = parkedOn(p.page).filter((v) => v.side === p.side);
  const r = stripRect(p.side, on.indexOf(p), on.length);
  const w = webWins.value.find((v) => v.id === p.id);
  const icon = w && iconOf(w.key);
  const style = { position: "absolute", left: `${r.x - o.x}px`, top: `${r.y - o.y}px`, width: `${r.w}px`, height: `${r.h}px`, zIndex: 1001, touchAction: "none" } as const;
  const end = (e: PointerEvent, cancelled: boolean) => {
    e.stopPropagation();
    setHeld(false);
    const x0 = from.current;
    from.current = null;
    // A tap, or a drag inward (away from its edge); a drag along the edge or outward is no ask.
    const inward = x0 == null ? 0 : (e.clientX - x0) * (p.side === "left" ? 1 : -1);
    if (!cancelled && x0 != null && (inward > SLOP || Math.abs(e.clientX - x0) <= SLOP)) void unpark(p.id);
  };
  return (
    <div
      class={`ww-park tile ${p.side}${held ? " ww-park-held" : ""}`}
      data-parked={p.id}
      style={style}
      onPointerDown={(e) => (e.stopPropagation(), capture(e), (from.current = e.clientX), setHeld(true))}
      onPointerUp={(e) => end(e, false)}
      onPointerCancel={(e) => end(e, true)}
    >
      {icon && <img class="ww-icon" src={icon} alt="" draggable={false} />}
    </div>
  );
}

// ---- tabs: windows stacked under one bar (WT1-WT3) -------------------------------------------------------------------
//
// The user, 10-31 01:30/01:31: "we should be able to like add tabs. So that I can like, group Dolphin and Chrome
// together." / "grab the title bar of Dolphin and drag it into the title bar of Chrome, and then they can share a title
// bar and they can tap between them." A stack is windows (Android or Linux alike) sharing one frame: its shown tab is a
// window like any other (moved, resized, tiled, paged, minimised as one), the others are hidden - not rendered, sent to
// the host as hidden entries of the same size ([hiddenEntry]) - and keep running. A switch hands the shown tab's frame,
// tile and z place to the new one ([showTab]). Held in a signal beside [tilings], with the same lifetime.

export interface Stack {
  /** Its windows, in tab order (2 or more: a stack of one is no stack). */
  ids: number[];
  /** The shown tab. */
  active: number;
}
export const stacks = signal<Stack[]>([]);
/** A drag's tab drop in progress: window [id] (with its stack) onto [target]'s bar, at tab index [at] (-1: the end). */
export const tabView = signal<{ id: number; target: number; at: number } | null>(null);
const tabKey = (v: { target: number; at: number } | null | undefined) => (v ? `tab:${v.target}:${v.at}` : "");

export const stackOf = (id: number) => stacks.value.find((s) => s.ids.includes(id));
/** Window [id] is a stack's hidden tab (not shown, running). */
export const hiddenTab = (id: number) => {
  const s = stackOf(id);
  return !!s && s.active !== id;
};
const setStacks = (next: Stack[]) => (stacks.value = next.filter((s) => s.ids.length >= 2));

/** Tab [id] shown: it takes the shown tab's frame, tile and place in the z order; that one is hidden (running). */
export function showTab(id: number) {
  const s = stackOf(id);
  if (!s || s.active === id) return;
  const from = webWins.value.find((w) => w.id === s.active);
  const me = webWins.value.find((w) => w.id === id);
  stacks.value = stacks.value.map((v) => (v === s ? { ...v, active: id } : v));
  if (!from || !me) return;
  const rest = webWins.value.filter((w) => w.id !== id);
  rest.splice(rest.indexOf(from) + 1, 0, me);
  webWins.value = rest;
  const p = tiledOn(from.id);
  if (p != null) tilings.value = { ...tilings.value, [p]: { ...tilings.value[p], ids: tilings.value[p].ids.map((v) => (v === from.id ? id : v)) } };
  if (tileMenu.value === from.id) tileMenu.value = null;
  const { page, x, y, w, h, scale, restore, untiled, minimised } = from;
  update(id, { page, x, y, w, h, scale, restore, untiled, minimised });
}

/** Window [id] out of its stack (closed, undocked): shown, its neighbour takes its place first. */
function leaveStack(id: number) {
  const s = stackOf(id);
  if (!s) return;
  const i = s.ids.indexOf(id);
  if (s.active === id) showTab(s.ids[i + 1] ?? s.ids[i - 1]);
  setStacks(stacks.value.map((v) => (v.ids.includes(id) ? { ...v, ids: v.ids.filter((t) => t !== id) } : v)));
}

/** The previewed tab drop made: window [id] (its whole stack, if it has one) into [target]'s tabs at [at], shown. */
function joinStack(t: { id: number; target: number; at: number }) {
  const moving = stackOf(t.id)?.ids ?? [t.id];
  const into = stackOf(t.target);
  const base = (into?.ids ?? [t.target]).filter((v) => !moving.includes(v));
  const at = t.at < 0 ? base.length : Math.min(t.at, base.length);
  const ids = [...base.slice(0, at), ...moving, ...base.slice(at)];
  setStacks([...stacks.value.filter((v) => v !== into && !v.ids.includes(t.id)), { ids, active: into?.active ?? t.target }]);
  showTab(t.id);
  hapticConfirm();
  console.info(`[tabs] window ${t.id} joined ${t.target}: [${ids.join(",")}]`);
}

/** Tab [id] dragged out of its stack's bar: a floating window of the stack's size, shown, on top (the drag goes on). */
function undock(id: number) {
  const s = stackOf(id);
  const from = s && webWins.value.find((w) => w.id === s.active);
  if (!from) return;
  const size = from.restore ?? from;
  leaveStack(id);
  update(id, { page: from.page, w: size.w, h: size.h, scale: from.scale, restore: undefined, untiled: undefined, minimised: false });
  reach(id);
  raise(id);
  hapticTick();
}

/** Tab [id] dragged along its bar to [x]: its place among the others' tabs (a tick as it changes). */
function reorder(id: number, shown: number, x: number) {
  const s = stackOf(id);
  if (!s) return;
  const els = [...document.querySelectorAll<HTMLElement>(`.webwindow[data-wwid="${shown}"] .ww-tab[data-tab]`)].filter((e) => Number(e.dataset.tab) !== id);
  const others = els.map((e) => Number(e.dataset.tab));
  const at = insertAt(els.map((e) => boxOfRect(e.getBoundingClientRect())), x);
  const ids = [...others.slice(0, at), id, ...others.slice(at)];
  if (ids.join() === s.ids.join()) return;
  stacks.value = stacks.value.map((v) => (v === s ? { ...v, ids } : v));
  hapticTick();
}

const boxOfRect = (r: DOMRect): Box => ({ x: r.left, y: r.top, w: r.width, h: r.height });

/** The other windows on [id]'s page (bottom first): their frames, bars and tabs, viewport px ([tabAt]). */
function barsUnder(id: number): Bar[] {
  const own = document.querySelector<HTMLElement>(`.webwindow[data-wwid="${id}"]`);
  const out: Bar[] = [];
  for (const el of own?.parentElement?.querySelectorAll<HTMLElement>(":scope > .webwindow[data-wwid]") ?? []) {
    const wid = Number(el.dataset.wwid);
    if (wid === id) continue;
    const bar = el.querySelector(".webwindow-title");
    const tabs = [...el.querySelectorAll(".ww-tab[data-tab]")];
    const list = tabs.length ? tabs : [...el.querySelectorAll(".ww-title-label")];
    const max = !!webWins.value.find((w) => w.id === wid)?.restore;
    out.push({ id: wid, frame: boxOfRect(el.getBoundingClientRect()), bar: bar ? boxOfRect(bar.getBoundingClientRect()) : undefined, tabs: list.map((t) => boxOfRect(t.getBoundingClientRect())), max });
  }
  return out;
}

/** How long the windows glide to their new tiles after a drop ("ww-reflow" in shell.css: the same time). */
const REFLOW_MS = 220;
/** The page whose windows are re-flowing (their frames transition), or null. */
const reflowing = signal<number | null>(null);
let reflowTimer = 0;
function reflow(page: number) {
  reflowing.value = page;
  clearTimeout(reflowTimer);
  reflowTimer = window.setTimeout(() => {
    reflowing.value = null;
    for (const id of held.splice(0)) resizing.delete(id);
    resendGeometry();
  }, REFLOW_MS);
}

/**
 * RS1 for the glide: each app relayouts ONCE, to its final tile (paced as a resize drag, never re-paced while the frame
 * moves), not on every frame of the transition; the end sends the bodies' own sizes.
 */
const held: number[] = [];
function holdAppSizes(ids: (number | null)[]) {
  for (const w of webWins.value) {
    if (!ids.includes(w.id) || resizing.has(w.id)) continue;
    resizing.set(w.id, { cw: w.w, ch: w.h - (w.ownFrame ? 0 : TITLE), frame: 0, last: Infinity, lastAt: Infinity, steps: 0, reqs: 0 });
    held.push(w.id);
  }
  if (held.length) kick();
}

/** The drop's preview: the tile the window would take, translucent; it glides between zones. */
function DropPreview({ d, o }: { d: { rect: Box; zone?: Zone; slot?: Slot; kind?: Place["kind"] }; o: { x: number; y: number } }) {
  const r = d.rect;
  // A dragged window's floating ghost is its own frame: under the windows, never over the window it previews.
  const style = { left: `${r.x - o.x}px`, top: `${r.y - o.y}px`, width: `${r.w}px`, height: `${r.h}px`, zIndex: d.kind === "float" ? 0 : 999 };
  return (
    <div class={`ww-drop ${d.zone?.kind ?? d.kind ?? "snap"}`} data-zone={d.zone ? dropKey(d.zone) : d.kind ? `place:${d.kind}` : `snap:${d.slot}`} style={style}>
      {d.zone?.kind === "swap" && <span class="ww-drop-label tile">Swap</span>}
    </div>
  );
}

/**
 * TG2: a divider goes anywhere across the area - only a tile's minimum size ([MIN_TILE], CSS px along the divider's
 * axis) limits it, with a light pull to the half (within [HALF_PULL] px). Pushed past that minimum to within
 * [DROP_PX] of the edge, the squeezed side goes to the dock.
 */
export const MIN_TILE = { x: 160, y: 96 };
const HALF_PULL = 12;
export const DROP_PX = 32;
/** The divider's ratio of [span] px let go at [r]: a tile at least [MIN_TILE] each side, pulled to the half. */
export function dividerRatio(r: number, span: number, axis: "x" | "y"): number {
  const min = Math.min(0.5, MIN_TILE[axis] / span);
  const near = Math.abs(r - 0.5) * span < HALF_PULL ? 0.5 : r;
  return Math.min(1 - min, Math.max(min, near));
}

/**
 * A divider drag ended ([DividerEl]): "<page>:<axis>" at [ratio] (already snapped), or [drop]: the windows squeezed to an
 * edge. Those go to the dock (minimised, alive: a tap on their dock icon brings them back floating), the rest close
 * up. Not closed (the app's state would go) and not floated on top (it would cover the tile the user just widened);
 * the user asked the same of Android's split, 2026-10-29: dragging it to the edge should tuck it away, not close it.
 */
function divided(m: { key: string; ratio: number; drop?: number[] }) {
  const [p, which] = m.key.split(":");
  const page = Number(p);
  const t = tilings.value[page];
  if (!t) return;
  if (m.drop?.length) {
    for (const id of m.drop) untile(id, "minimise");
    return;
  }
  setTiling(page, which === "x" || which === "rx" ? { ...t, rx: m.ratio } : { ...t, ry: m.ratio });
}

// ---- WX1: swapping sides (the user, 10-31 15:47-15:52: "a swap icon ... so that I can like swap side", "If I click the
// separator here, it should swap the windows") - a tap on a divider, or the ⇄ hint on a snapped window's inner edge.

/** A split of one window against two flips its layout (one big left | two right <-> two left | one big right). */
const MIRROR: Partial<Record<Layout, Layout>> = { "3": "3r", "3r": "3", "3t": "3b", "3b": "3t" };
type Sides = Pick<Divider, "ratio" | "before" | "after">;

/**
 * [t] with divider [d]'s two sides traded: as many windows each side, pairwise in slot order; one against two, the
 * layout mirrored. Each side keeps its size (the ratio flips), so every window keeps its own tile's size and state.
 */
export function swappedTiling(t: Tiling, d: Sides): Tiling {
  const slot = (ids: number[]) => ids.map((id) => t.ids.indexOf(id));
  const [a, b] = [slot(d.before), slot(d.after)];
  const flip = { ...t, [d.ratio]: 1 - t[d.ratio] };
  if (a.length === b.length) {
    const ids = [...t.ids];
    a.forEach((s, i) => ([ids[s], ids[b[i]]] = [t.ids[b[i]], t.ids[s]]));
    return { ...flip, ids };
  }
  const ids = [...b, ...a].map((s) => t.ids[s]);
  return { ...flip, layout: MIRROR[t.layout] ?? t.layout, ids };
}

/** Divider [d] of [page]'s tiling tapped: its sides swap, gliding there ([reflow]); the host gets the frames as usual. */
export function swapAt(page: number, d: Sides) {
  const t = tilings.value[page];
  if (!t) return;
  const next = swappedTiling(t, d);
  reflow(page);
  setTiling(page, next);
  holdAppSizes(next.ids);
  console.info(`[tiles] page ${page}: divider ${d.ratio} tapped, swapped -> ${next.layout} [${next.ids.join(",")}]`);
}

type Edge4 = "e" | "w" | "s" | "n";
const halfEdge = (layout: "2h" | "2v", i: number): Edge4 => (layout === "2h" ? (i === 0 ? "e" : "w") : i === 0 ? "s" : "n");

/** Which inner edge of window [w] the ⇄ hint sits on ("e": a left half's right edge...), or null: not a snapped half. */
export function swapEdge(w: WebWin): Edge4 | null {
  const page = tiledOn(w.id);
  const t = page != null ? tilings.value[page] : null;
  if (t) return t.layout === "2h" || t.layout === "2v" ? halfEdge(t.layout, t.ids.indexOf(w.id)) : null;
  const half = aloneHalf(w);
  return half ? halfEdge(half.layout, half.i) : null;
}

/** A lone window snapped to a half (SC1: no tiling of one): which, by its frame on the half's rect. */
function aloneHalf(w: WebWin): { layout: "2h" | "2v"; i: number } | null {
  if (w.restore || w.minimised || w.full || (w.scale ?? 1) !== 1) return null;
  const { origin: o, area: a } = renderLayout();
  const on = (r: Box) => [r.x - o.x - w.x, r.y - o.y - w.y, r.w - w.w, r.h - w.h].every((v) => Math.abs(v) <= 2);
  for (const layout of ["2h", "2v"] as const) {
    const i = tileRects({ layout, ids: [], rx: 0.5, ry: 0.5 }, a).findIndex(on);
    if (i >= 0) return { layout, i };
  }
  return null;
}

/** The ⇄ hint tapped on window [id]: its split's two sides swap; a lone snapped half moves to the empty other half. */
export function swapWindow(id: number) {
  const page = tiledOn(id);
  const t = page != null ? tilings.value[page] : null;
  if (page != null && t) return swapAt(page, { ratio: t.layout === "2v" ? "ry" : "rx", before: [t.ids[0]!], after: [t.ids[1]!] });
  const w = webWins.value.find((v) => v.id === id);
  const half = w && aloneHalf(w);
  if (!w || !half) return;
  reflow(w.page);
  snapAlone(id, half.layout, 1 - half.i);
  console.info(`[tiles] window ${id} swapped to the other ${half.layout} half`);
}

/** WX1: a press let go within [TAP_PX] of where it went down and inside [TAP_MS] is a tap (a swap), not a drag. */
const TAP_PX = 6;
const TAP_MS = 300;
const isTap = (p: { x: number; y: number; at: number }, e: PointerEvent) => Math.hypot(e.clientX - p.x, e.clientY - p.y) < TAP_PX && e.timeStamp - p.at < TAP_MS;

/**
 * A divider between tiles: a DOM handle in its page (it moves with a page swipe, home's swipes leave it alone). Its drag
 * follows the finger; let go, the split snaps to a third, a half or two thirds - or, within [DROP_SHARE] of an edge,
 * the squeezed side's windows go to the dock (see "webwindows.divider" above, the same rules). A tap swaps its sides.
 */
function DividerEl({ page, d, o }: { page: number; d: Divider; o: { x: number; y: number } }) {
  const [shift, setShift] = useState(0);
  const start = useRef<number | null>(null);
  const press = useRef({ x: 0, y: 0, at: 0 });
  const vertical = d.axis === "x";
  const style = {
    position: "absolute",
    left: `${(vertical ? d.pos - TILE_GAP / 2 + shift : d.from) - o.x}px`,
    top: `${(vertical ? d.from : d.pos - TILE_GAP / 2 + shift) - o.y}px`,
    width: `${vertical ? TILE_GAP : d.len}px`,
    height: `${vertical ? d.len : TILE_GAP}px`,
    zIndex: 1000,
    touchAction: "none",
  } as const;
  const at = (e: PointerEvent) => (vertical ? e.clientX : e.clientY);
  const end = (e: PointerEvent, cancelled: boolean) => {
    if (start.current == null) return;
    e.stopPropagation();
    if (!cancelled && isTap(press.current, e)) {
      start.current = null;
      setShift(0);
      return swapAt(page, d);
    }
    const span = d.hi - d.lo;
    const p = d.pos + at(e) - start.current - d.lo;
    const r = p / span;
    start.current = null;
    setShift(0);
    if (cancelled) return;
    const drop = p < DROP_PX ? d.before : p > span - DROP_PX ? d.after : [];
    const ratio = dividerRatio(r, span, d.axis);
    divided({ key: `${page}:${d.ratio}`, ratio, drop });
    console.info(`[tiles] divider ${page}:${d.axis} let go at ${r.toFixed(2)} -> ${drop.length ? `windows ${drop} to the dock` : `at ${ratio.toFixed(2)}`}`);
  };
  return (
    <div
      class="webwindow ww-divider"
      data-div={`${page}:${d.ratio}`}
      // The split's axis, not its ratio's name: "3"'s right column splits top / bottom on "ry", "3c"'s on "ry" too but
      // left | right - the pill's orientation follows this (shell.css; 10-31 15:10 an upright pill over Discord's bar).
      data-axis={d.axis}
      style={style}
      onPointerDown={(e) => {
        e.stopPropagation();
        capture(e);
        start.current = at(e);
        press.current = { x: e.clientX, y: e.clientY, at: e.timeStamp };
      }}
      onPointerMove={(e) => {
        if (start.current == null) return;
        e.stopPropagation();
        // To the very edge (TG2): past the minimum tile it shows the drop to the dock.
        const lo = d.lo + TILE_GAP - d.pos;
        const hi = d.hi - TILE_GAP - d.pos;
        setShift(Math.min(hi, Math.max(lo, at(e) - start.current)));
      }}
      onPointerUp={(e) => end(e, false)}
      onPointerCancel={(e) => end(e, true)}
    />
  );
}

// ---- geometry to the host (docs/WEB_WINDOWS.md "Element model") ----------------------------------------------------------
//
// Each frame while there are windows, every window's BODY element is measured as it shows: its rect after every
// transform (a page swipe, the screens' slide to PowOS AI, the drawer's zoom, the window's own scale), the part its
// ancestors' clips and the screen let show, its visibility (off page, under a full-screen overlay, faded out) and its
// DOM order. The host puts the app's layer exactly there, on the draw that shows this frame (FrameSync), so the layer
// and the page's pixels can't be a frame apart - mid-swipe too.

const px = (v: number) => (Math.round(v * 100) / 100).toString();
let lastGeometry = "";
/** The native port was up once: a later port is a reconnect (plan 2.4: sync). */
let nativeSeen = false;
let raf = 0;

/** Overlays that cover all of home: a window under one is hidden (its layer, not only its pixels). */
const OVERLAYS = ".folder-view.open";

type Clip = [number, number, number, number];

/** [clip] narrowed to [q] along x and/or y. */
function narrow(clip: Clip, q: DOMRect, x: boolean, y: boolean) {
  if (x) (clip[0] = Math.max(clip[0], q.left), (clip[2] = Math.min(clip[2], q.right)));
  if (y) (clip[1] = Math.max(clip[1], q.top), (clip[3] = Math.min(clip[3], q.bottom)));
}

/** An ancestor as [shown] reads it: its clip box and axes (null: it clips nothing), its opacity (0: hidden). */
interface Ancestor {
  box: DOMRect | null;
  x: boolean;
  y: boolean;
  alpha: number;
}
/** RS5: one [geometry]'s ancestors, read once for all its windows (they share the page, the track, home ...). */
let ancestorsSeen: Map<HTMLElement, Ancestor> | null = null;

function readAncestor(a: HTMLElement): Ancestor {
  const cs = getComputedStyle(a);
  // Its own page's area always clips it (PS2), whatever the page's overflow.
  const page = a.classList.contains("page");
  const x = page || cs.overflowX !== "visible";
  const y = page || cs.overflowY !== "visible";
  return { box: x || y ? a.getBoundingClientRect() : null, x, y, alpha: cs.visibility === "hidden" || cs.display === "none" ? 0 : parseFloat(cs.opacity) || 0 };
}

/** One ancestor's share of [shown]: its opacity (0: hidden), and its clip into [clip]. */
function ancestor(a: HTMLElement, clip: Clip): number {
  let v = ancestorsSeen?.get(a);
  if (!v) (v = readAncestor(a)), ancestorsSeen?.set(a, v);
  if (v.box) narrow(clip, v.box, v.x, v.y);
  return v.alpha;
}

/** What of [el] its clipping ancestors and the screen let show (viewport CSS px, l t r b), and its ancestors' opacity. */
function shown(el: HTMLElement): { clip: Clip; alpha: number } {
  const r = el.getBoundingClientRect();
  const clip: Clip = [Math.max(0, r.left), Math.max(0, r.top), Math.min(innerWidth, r.right), Math.min(innerHeight, r.bottom)];
  let alpha = 1;
  for (let a = el.parentElement; a && a !== document.body; a = a.parentElement) alpha *= ancestor(a, clip);
  return { clip, alpha };
}

/**
 * Maximised, the bar merges with the status bar: "<title's end> <controls' start>" (the status bar's between), else "-1 -1".
 * Never a tiled window's (the status bar spans the full screen while tiled - 10-31: its clock sat at x 234, laid out
 * to a lone tile's bar, when the last tile was made a maximised window), and only while that bar is on the strip.
 */
function mergeOf(w: WebWin, el: HTMLElement): string {
  // TB1: an auto-hidden bar is never on the strip (slid in, it sits under the status bar's room).
  if (!w.restore || tiledOn(w.id) != null || barAutoHidden(w)) return "-1 -1";
  const title = el.querySelector(".ww-title-label")?.getBoundingClientRect();
  const controls = el.querySelector(".ww-controls")?.getBoundingClientRect();
  const inset = rootTokens().inset || TITLE;
  return title && controls && title.top < inset ? `${px(title.right)} ${px(controls.left)}` : "-1 -1";
}

/**
 * One window's entry, or null (its page isn't in the DOM): "<id> <frame x y w h> <body x y w h> <clip l t r b>
 * <radius> <visible> <alpha> <scale> <maximised> <titleEnd> <controls> <resizing> <app w> <app h> <fill>", viewport
 * CSS px after transforms ([sizeOf]: the app's paced size during a resize drag, unscaled; [fillOf]: the theme surface).
 */
export function entry(w: WebWin): string | null {
  const el = document.querySelector<HTMLElement>(`.webwindow[data-wwid="${w.id}"]`);
  const body = el?.querySelector<HTMLElement>(".webwindow-body");
  if (!el || !body) return null;
  const f = el.getBoundingClientRect();
  const b = body.getBoundingClientRect();
  const scale = body.offsetWidth ? b.width / body.offsetWidth : 1;
  const { clip, alpha } = shown(body);
  const visible = !document.querySelector(OVERLAYS) && alpha > 0.01 && clip[2] > clip[0] && clip[3] > clip[1];
  const rects = [f.left, f.top, f.width, f.height, b.left, b.top, b.width, b.height, ...clip].map(px);
  return [w.id, ...rects, RADIUS * scale, visible ? 1 : 0, px(alpha), px(scale), maximisedWord(w), mergeOf(w, el), sizeOf(w, body), fillOf()].join(" ");
}

/**
 * The entry's <maximised>: 0, 1, or (TB1) 2 - maximised with its bar auto-hidden, the window in front: the host hides
 * home's status bar so the app has the whole screen (AOSP's full immersive desktop task), a swipe shows it for a moment.
 */
function maximisedWord(w: WebWin): number {
  if (!w.restore) return 0;
  return barAutoHidden(w) && frontWindow()?.id === w.id ? 2 : 1;
}

/**
 * TB1 (docs/WEB_WINDOWS.md "Title bar: native parity"): window [w]'s bar auto-hides - its app is immersive while the
 * window fills the work area (maximised, not tiled), as AOSP's desktop header in full immersive. A floating or tiled
 * window keeps its bar whatever its app asks (AOSP: a freeform task's header is always shown).
 */
export function barAutoHidden(w: WebWin): boolean {
  return !!w.immersive && !!w.restore && !w.ownFrame && tiledOn(w.id) == null;
}

/** TB2: the full-screen Linux window whose bar a pull from the top slid in (the host's "webwindows.reveal"), or null. */
export const fullReveal = signal<number | null>(null);

// A slid-in bar stays while its tile menu is open on it.
revealKept.now = (id) => tileMenu.peek() === id;

// ---- RS1/RS2: a resize drag paces the app's relayouts --------------------------------------------------------------
// The frame (and the layer's crop) follows the finger every frame; the app's own size - what the host resizes its
// display / KWin window to, each one a relayout and a new buffer - only every [RELAYOUT_FRAMES] frames and at least
// [RELAYOUT_MS] apart, newest size wins. Until it draws at it, the host shows the app's last buffer anchored top left,
// clipped to the body, over the theme's surface (never stretched). The press ends: the body's size, once (the final).
// Before (10-30, the user: "it's just lagging after, eventually it's catching up"): one VD resize per step, queued.

/** RS1: at least this many page frames, and ms, between two of the app's relayouts while an edge is dragged. */
const RELAYOUT_FRAMES = 3;
const RELAYOUT_MS = 40;

/** A resize drag in progress, by window id: the app's paced size (body CSS px, unscaled), its counts for the log. */
interface Resizing {
  cw: number;
  ch: number;
  frame: number;
  last: number;
  lastAt: number;
  steps: number;
  reqs: number;
}
const resizing = new Map<number, Resizing>();

/** A resize grab on window [id] began: its app's size paced from now ([pace]) until [resizeEnd]. */
function resizeStart(id: number) {
  resizing.set(id, { cw: -1, ch: -1, frame: 0, last: -Infinity, lastAt: -Infinity, steps: 0, reqs: 0 });
  liftStart(id);
  glassDrags.add(id);
  glassDrag(true);
  kick();
}

/** RJ2: nativeglass.ts's blur regions off for a resize drag (its HACK note: they force SF GPU composition each frame). */
const glassDrags = new Set<number>();
const glassDrag = (on: boolean) => (globalThis as { __glassDrag?: (on: boolean) => void }).__glassDrag?.(on);

/** The grab ended: the next "w.f" has the body's size as the app's (the final relayout); the counts kept for the gate. */
function resizeEnd(id: number) {
  const r = resizing.get(id);
  if (!r) return;
  resizing.delete(id);
  if (glassDrags.delete(id) && !glassDrags.size) glassDrag(false);
  unslice(id, webWins.peek().find((v) => v.id === id));
  // RS5c: the live frame committed (a new WebWin: the window's one render with it).
  if (liveSized.delete(id)) update(id, {});
  reach(id);
  liftEnd(id);
  lastResize = { id, steps: r.steps, reqs: r.reqs };
  resendGeometry();
}
let lastResize: { id: number; steps: number; reqs: number } | null = null;

// ---- LH1: a resize drag's window lifted over home's surface: no hole in the page follows it -------------------------
// The phone's resize traces (11-11, ww-resize-1111-00*): every move rewrote the CSS masks that cut the dragged window's
// hole - `.page-under`'s mask layer and each lower window's frame (its own content, 360 paints at 16% of the page over
// 2x60 moves) repainted and re-rastered per move, home's DrawFrame p90 12-15 ms against the 8.3 ms budget. A CSS mask
// can't follow by transform. So for the drag the window's app layer goes ABOVE home's buffer (the host:
// WebWindows.lift), where nothing of the page needs a hole, and its hole leaves the masks once; the drag's end writes
// the exact masks once and the layer goes back under home. The page frame and the host's layer move together
// (FrameSync), and each switch keeps a [LIFT_FRAMES] overlap where BOTH are true (lifted with its hole still cut: the
// same pixels), so a geometry the host applies a frame late never shows the page over the app.
// Only the top window of its page lifts (one under another would cover it); while lifted its bar is drawn solid (no
// hole under its glass) and the live size label sits in the bar (shell.css LH1: DOM over the body is under the app).

/**
 * Page frames each lift switch overlaps (the hole kept after the lift, the lift kept after the hole is back).
 * HACK: a frame count, not a confirmation - FrameSync applies a "w.f" on the draw of its page frame, but N2's
 * predicted frames and a late page can put it a frame or two off. Real fix: the host acks the page frame its lift
 * landed on ("webwindows.lifted <id> <frame>"), and the hole switches on that.
 */
const LIFT_FRAMES = 3;
/** "up": lifted, hole still cut; "lifted": no hole; "down": hole back, still lifted ([LIFT_FRAMES] ticks). */
type Lift = { phase: "up" | "lifted" | "down"; frames: number; page: number };
const lifts = new Map<number, Lift>();
/** [w]'s hole is cut from the page's masks (every window but a lifted one). */
const holed = (w: WebWin) => lifts.get(w.id)?.phase !== "lifted";

/** Window [id]'s resize drag began: lifted when it is the top window on its page, floating (not maximised, quick). */
function liftStart(id: number) {
  const w = webWins.peek().find((v) => v.id === id);
  if (!w || w.restore || w.quick || w.full || lifts.has(id)) return;
  const here = windowsHere(w.page);
  if (here[here.length - 1]?.id !== id) return;
  lifts.set(id, { phase: "up", frames: LIFT_FRAMES, page: w.page });
}

/** The drag ended: the exact hole now (this frame), the lift dropped [LIFT_FRAMES] page frames later ([liftTick]). */
function liftEnd(id: number) {
  const l = lifts.get(id);
  if (!l || l.phase === "down") return;
  if (l.phase === "up") return void lifts.delete(id);
  l.phase = "down";
  l.frames = LIFT_FRAMES;
  recut(id, l.page);
}

/** Once per page frame, before the geometry goes out: each lift's next phase when its overlap ran out. */
function liftTick() {
  for (const [id, l] of lifts) {
    if (l.phase !== "down" && !resizing.has(id)) {
      liftEnd(id);
      continue;
    }
    if (--l.frames > 0) continue;
    if (l.phase === "up") (l.phase = "lifted"), recut(id, l.page);
    else if (l.phase === "down") lifts.delete(id), resendGeometry();
  }
}

/** Page [page]'s masks written again for window [id]'s lift (its hole out or back), its frame marked lifted or not. */
function recut(id: number, page: number) {
  const frame = document.querySelector<HTMLElement>(`.webwindow[data-wwid="${id}"]`);
  if (frame) frame.toggleAttribute("data-lifted", lifts.get(id)?.phase === "lifted");
  const box = frame?.closest<HTMLElement>(".page-windows") ?? null;
  cutAll(box, windowsHere(page));
  const under = box?.closest(".page")?.querySelector<HTMLElement>(":scope > .page-under");
  if (under) writeMask(under, underWindows(page));
}

/** Once per page frame, before measuring: window [id]'s app size moves to its body's when its pace allows. */
function pace(id: number, r: Resizing, now: number) {
  r.frame++;
  const body = document.querySelector<HTMLElement>(`.webwindow[data-wwid="${id}"] .webwindow-body`);
  if (!body) return;
  const [w, h] = [body.offsetWidth, body.offsetHeight];
  if (w === r.cw && h === r.ch) return;
  if (r.frame - r.last < RELAYOUT_FRAMES || now - r.lastAt < RELAYOUT_MS) return;
  (r.cw = w), (r.ch = h), (r.last = r.frame), (r.lastAt = now), r.reqs++;
}

/**
 * "<resizing> <app w> <app h>": the app's size in CSS px - a paced drag's, else the body's layout size. Always the
 * layout size, never one measured after transforms: the host rounds it to device px ONCE (x dpr), so a page zoom, a
 * swipe or a rounded scale can't move the app's display by a pixel each frame (10-30: "After I rescaled YouTube it's
 * like flickering" - the size came from the transformed rect / a 2-decimal scale, a resize per frame).
 */
function sizeOf(w: WebWin, body: HTMLElement): string {
  const r = resizing.get(w.id);
  // LH1: 2 = resizing and lifted over home's surface, 3 = lifted only (the drag's end, until its exact hole is drawn).
  const up = lifts.has(w.id);
  if (r && r.cw > 0) return `${up ? 2 : 1} ${r.cw} ${r.ch}`;
  const [lw, lh] = layoutSize(body);
  return `${up ? 3 : 0} ${px(lw)} ${px(lh)}`;
}

/**
 * [body]'s layout size in CSS px, unrounded and untransformed (its computed width/height plus its padding and border
 * for a content-box): offsetWidth/offsetHeight round to whole CSS px, and x dpr that missed the screen - a full-screen
 * game's window settled at 2268x2439 on the 2268x2440 screen (bf-pacing 11-08 02:19), so Xwayland couldn't flip it.
 */
function layoutSize(body: HTMLElement): [number, number] {
  const cs = getComputedStyle(body);
  let w = parseFloat(cs.width);
  let h = parseFloat(cs.height);
  if (!(w >= 0) || !(h >= 0)) return [body.offsetWidth, body.offsetHeight];
  if (cs.boxSizing !== "border-box") {
    const n = (k: string) => parseFloat(cs.getPropertyValue(k)) || 0;
    w += n("padding-left") + n("padding-right") + n("border-left-width") + n("border-right-width");
    h += n("padding-top") + n("padding-bottom") + n("border-top-width") + n("border-bottom-width");
  }
  return [w, h];
}

/** The theme's surface as "rrggbb" (the host's fill under a resized app's last buffer), cached by its token's value. */
let fillKey = "";
let fillHex = "000000";
function fillOf(): string {
  const v = rootTokens().surface;
  if (v === fillKey) return fillHex;
  fillKey = v;
  const ctx = document.createElement("canvas").getContext("2d", { willReadFrequently: true });
  if (!ctx || !v) return fillHex;
  ctx.fillStyle = v;
  ctx.fillRect(0, 0, 1, 1);
  const [r, g, b] = ctx.getImageData(0, 0, 1, 1).data;
  fillHex = [r, g, b].map((c) => c.toString(16).padStart(2, "0")).join("");
  return fillHex;
}

/**
 * W-IN1: bumped in the frame any window's geometry changes - a move, a resize, a snap or its transition, open, close,
 * raise, full screen, a page swipe carrying it, a fold. Home re-reports the pull-exclusion regions from it (home.tsx),
 * so they follow the same per-frame geometry as the layer (03:15: "the window resized, but ... the touch handlers
 * didn't realize": they were refreshed only on webWins changes, then read mid-transition).
 */
export const windowFrame = signal(0);

/**
 * Fix plan 1.5: the root's tokens every window's entry reads ([mergeOf]'s --inset-top, [fillOf]'s --color-surface),
 * read once per measure ([geometry]) instead of a getComputedStyle of the root per window; outside one, read fresh.
 */
let tokensSeen: { inset: number; surface: string } | null = null;
function rootTokens(): { inset: number; surface: string } {
  if (tokensSeen) return tokensSeen;
  const cs = getComputedStyle(document.documentElement);
  return { inset: parseFloat(cs.getPropertyValue("--inset-top")) || 0, surface: cs.getPropertyValue("--color-surface").trim() };
}

/** "<dpr> <n> <entries...>": every window the page shows, bottom first (DOM order = z-order). */
export function geometry(): string {
  const parts: string[] = [];
  ancestorsSeen = new Map();
  tokensSeen = rootTokens();
  try {
    for (const w of webWins.value) entriesOf(w, parts);
  } finally {
    ancestorsSeen = null;
    tokensSeen = null;
  }
  return [devicePixelRatio, parts.length, ...parts].join(" ");
}

/** Window [w]'s entry into [parts], its stack's hidden tabs first (none: it isn't shown). */
function entriesOf(w: WebWin, parts: string[]) {
  const e = w.pending || hiddenTab(w.id) ? null : entry(w);
  if (!e) return;
  for (const t of stackOf(w.id)?.ids ?? []) if (t !== w.id) parts.push(hiddenEntry(e, t));
  parts.push(e);
}

/**
 * WT3: a stack's hidden tab [id] as its shown tab's [entry] - the same frame, body and app size (so its display keeps
 * the stack's size and a switch is instant, no relayout) - but not visible: the host hides its layer (WebWindows.place:
 * "hidden is the layer, never the display's surface"), as for any window off screen, and it composites nothing. Its app
 * keeps running on its display; never minimised (that is a home gesture: PiP, its task to display 0).
 */
function hiddenEntry(entry: string, id: number): string {
  const f = entry.split(" ");
  // 0 id, 1-12 frame/body/clip, 13 radius, 14 visible, 15 alpha, 16 scale, 17 maximised, 18-19 merge.
  f[0] = String(id);
  f[14] = "0";
  f[17] = "0";
  f[18] = f[19] = "-1";
  return f.join(" ");
}

/** For the gate and CDP (`__ww.sent`): the last "w.f" lines (sent, or measured with no host), newest last. */
const sent: string[] = [];
(globalThis as { __ww?: unknown }).__ww = {
  sent,
  geometry,
  get tickMs() {
    return tickMs;
  },
  /** How many frames the tick has run (the gate's ww-idle-tick: none while every window is still). */
  get ticks() {
    return ticks;
  },
  get dirtyBy() {
    return `${dirtyBy}; running ${[...running].map((t) => (t as Element).className).join(", ")}`;
  },
  get lastResize() {
    return lastResize;
  },
  /** N2: frame-ahead lines sent, and per frame how far the next frame's own measure was from the prediction (px). */
  get ahead() {
    return aheadStats;
  },
  /** N2 without a host (the gate), or an A/B run (ww-glue.sh WW_AHEAD): compute and keep the frame-ahead geometry. */
  get aheadOn() {
    return geometryChannel.ahead;
  },
  set aheadOn(on: boolean) {
    geometryChannel.ahead = on;
  },
  /** N1: the motions measured so far (frames sent, and those a compositor-run animation moved a window in). */
  get glue() {
    return { ...glue, last: lastGlue };
  },
  get direct() {
    return geometryChannel.direct;
  },
  set direct(on: boolean) {
    geometryChannel.direct = on;
  },
};

/**
 * Each frame while there are windows: their geometry tagged with this page frame, when it changed. The line ends with
 * the frame's rAF time as wall-clock ms (Date.now() less the time since the rAF timestamp; WebView's timeOrigin read
 * ~593 s off the host's clock on the phone, 10-30): the host counts the window draws
 * between it and the apply (FrameSync.pageLag, "pf=" in the host's "w.f" log).
 */
function tick(ts: number) {
  raf = 0;
  ticks++;
  const t0 = performance.now();
  if (moving()) {
    dirty = false;
    for (const [id, r] of resizing) pace(id, r, ts);
    liftTick();
    send(ts);
  } else glueEnd();
  tickMs.push(performance.now() - t0);
  if (tickMs.length > 240) tickMs.shift();
  // The next frame only while something still moves a window (a transition on one, a resize drag): idle - every window
  // still, or none on screen - no rAF at all (the title's "window tick", perf-1793970543446: a frame callback every
  // vsync with nothing to do). What moves one next kicks it again (markDirty, transitionrun, webWins, resend).
  if (webWins.value.length && moving()) raf = requestAnimationFrame(tick);
  else glueEnd();
}

// ---- N1: native-glued windows - every motion that carries a window runs on the main thread -------------------------
// docs/WEB_WINDOWS.md "Native-glued windows". The host moves an app's layer on the draw that shows the page frame its
// "w.f" was measured in (FrameSync.next). That holds for what the main thread moves (a finger, a rAF, a main-thread
// transition): the measured frame IS the committed one. A transition the compositor runs (transform, translate, scale,
// rotate, opacity) is ticked at the draw, a frame after the page measured it - the app's layer then trails its page by
// a frame's travel (a page switch: ~60 px a frame mid-slide). So while a window exists the page track and its glass
// slide on registered properties (html.ww-glued, shell.css --track-x/--glass-x), and every frame sent is checked here:
// [offThread] = a compositor-run animation on a window or an ancestor (want 0), logged per motion and kept for the gate.

/** Properties Chrome animates on the compositor thread (a transition/animation of one of them is off the main thread). */
const COMPOSITED = /^(transform|translate|scale|rotate|opacity)$/;
const glue = { motions: 0, frames: 0, offThread: 0 };
let lastGlue = { frames: 0, offThread: 0, by: "" };
let episode = { frames: 0, offThread: 0, by: "" };

/** The compositor-run animation moving a window this frame, as "<element>.<class> <property>", or "". */
function offThreadMover(): string {
  for (const a of frameAnimations()) {
    if (a.playState !== "running") continue;
    const t = (a.effect as KeyframeEffect | null)?.target;
    if (!t || !carriesWindow(t)) continue;
    const props =
      a instanceof CSSTransition ? [a.transitionProperty] : ((a.effect as KeyframeEffect).getKeyframes().flatMap((k) => Object.keys(k)) as string[]);
    const hit = props.find((p) => COMPOSITED.test(p));
    // Opacity only fades (the host takes the measured alpha): a frame late is a shade, never a misplaced window.
    if (hit && hit !== "opacity") return `${t.localName}.${t.getAttribute("class") ?? ""} ${hit}`;
  }
  return "";
}

/** A frame was sent: counted into this motion. */
function glueFrame() {
  const by = offThreadMover();
  episode.frames++;
  glue.frames++;
  if (by) {
    episode.offThread++;
    glue.offThread++;
    episode.by ||= by;
  }
}

/** The motion ended (nothing moves a window): one log line, to logcat (PowosShell) - the phone check reads it. */
function glueEnd() {
  if (!episode.frames) return;
  glue.motions++;
  lastGlue = episode;
  if (episode.frames > 2) console.info(`ww glue: ${episode.frames} frames, ${episode.offThread} off-thread${episode.by ? ` (${episode.by})` : ""}`);
  episode = { frames: 0, offThread: 0, by: "" };
}

/** N1: any window on home glues the page track to the main thread (shell.css html.ww-glued). */
effect(() => {
  document.documentElement.classList.toggle("ww-glued", webWins.value.some((w) => !w.full));
});

// ---- WT-IDLE: the tick measures only when something could have moved a window ------------------------------------
// perf-1793458433606 (10-31): [geometry] every frame - a querySelector, two rects and a computed-style walk up to the
// body per window - forced the layout the owl widget dirtied each frame: tick 61-83 ms of script with nothing moving.
// Now a frame measures only when [dirty] (set by what moves windows: a style/class/child change on or around a window,
// a page swipe's transform, a resize/scroll/viewport change, a window's size, webWins/tilings/stacks, a resend), or
// while a transition or animation runs on a window or its ancestors, or a resize drag paces; else it's a flag check.

/** Something may have moved a window since the last measure. */
let dirty = true;
/** Transitions/animations running on a window, inside one, or on one's ancestors (a snap, a page slide). */
const running = new Set<EventTarget>();
/** The last frames' tick durations (ms), for the gate (`__ww.tickMs`). */
const tickMs: number[] = [];
let ticks = 0;
const winEls = document.getElementsByClassName("webwindow");

function moving(): boolean {
  if (dirty || resizing.size || lifts.size) return true;
  if (!running.size) return false;
  for (const t of running) if (!(t as Node).isConnected) running.delete(t);
  return running.size > 0;
}

/** [t] can carry or reshape a window: the root, a window's ancestor or descendant, or a whole-home overlay. */
function aroundWindow(t: Node | null): boolean {
  if (!t || !(t instanceof Element)) return false;
  if (t === document.documentElement || t === document.body || t.matches(".folder-view")) return true;
  for (let i = 0; i < winEls.length; i++) {
    const w = winEls[i];
    if (t.contains(w) || w.contains(t)) return true;
  }
  return false;
}

/** [t] contains a window or is inside one (a transition or animation on it moves or reshapes the window). */
function carriesWindow(t: Node): boolean {
  if (!(t instanceof Element)) return false;
  for (let i = 0; i < winEls.length; i++) if (t.contains(winEls[i]) || winEls[i].contains(t)) return true;
  return false;
}

/**
 * Paint-only properties: a transition of one of them inside a window (a grip's or a button's fade, a hover colour)
 * moves and reshapes nothing - the window's own opacity is its alpha, so on the window or around it they still count.
 * The ship gate's ww-idle-tick on 11-06: "transitionrun svg.ww-grip" restarted the tick 7x in 120 still frames.
 */
const PAINT_ONLY = /^(opacity|color|background(-color)?|fill|stroke|box-shadow|filter|outline(-color)?|border(-\w+)?-color|visibility|text-decoration-color|caret-color)$/;
function decorationOnly(e: Event): boolean {
  if (!(e instanceof TransitionEvent) || !PAINT_ONLY.test(e.propertyName)) return false;
  const t = e.target as Element;
  for (let i = 0; i < winEls.length; i++) if (t === winEls[i] || t.contains(winEls[i])) return false;
  return true;
}

/** For the gate's failure line: what last made a frame measure ("mutation <class>", "running <class>", an event). */
let dirtyBy = "";
function markDirty(e?: Event | string) {
  dirtyBy = typeof e === "string" ? e : (e?.type ?? "kick");
  // No window: nothing to measure (a scroll or tap anywhere on home asked a frame); the next window kicks it (webWins).
  if (!webWins.peek().length) return void (dirty = true);
  kick();
}

new MutationObserver((records) => {
  if (dirty || !winEls.length) return;
  for (const r of records) if (aroundWindow(r.target)) return markDirty(`mutation ${r.type} ${r.attributeName ?? ""} ${(r.target as Element).className}`);
}).observe(document.documentElement, { subtree: true, childList: true, attributes: true, attributeFilter: ["style", "class", "hidden", "data-z"] });
const sizes = new ResizeObserver(() => markDirty("size"));
new MutationObserver(() => {
  sizes.disconnect();
  for (let i = 0; i < winEls.length; i++) sizes.observe(winEls[i]);
}).observe(document.documentElement, { subtree: true, childList: true });
for (const type of ["transitionrun", "animationstart"] as const)
  addEventListener(type, (e) => {
    // Only what carries or reshapes a window: it contains one or is inside one (not any descendant of a shared
    // ancestor such as the page track - an SVG ring on another page is no reason to re-measure).
    if (!e.target || !carriesWindow(e.target as Node) || decorationOnly(e)) return;
    running.add(e.target);
    // getAttribute: an SVG element's className is an SVGAnimatedString, not its classes.
    markDirty(`${e.type} ${(e.target as Element).localName}.${(e.target as Element).getAttribute("class") ?? ""}`);
  }, true);
for (const type of ["transitionend", "transitioncancel", "animationend", "animationcancel"] as const)
  addEventListener(type, (e) => {
    if (e.target && running.delete(e.target)) kick();
  }, true);
for (const type of ["resize", "scroll", "pointerup", "pointercancel"] as const) addEventListener(type, markDirty, true);
visualViewport?.addEventListener("resize", markDirty);

/**
 * Fix plan 1.5: document.getAnimations() once per [send] - [glueFrame] (N1's off-thread check) and [sendAhead] (N2)
 * both walk it; null outside a send (read fresh).
 */
let animsSeen: Animation[] | null = null;
function frameAnimations(): Animation[] {
  return animsSeen ?? (animsSeen = document.getAnimations());
}

/** [tick]'s send: the windows' geometry as one "w.f" line tagged with frame time [ts], when it changed. */
function send(ts: number) {
  animsSeen = null;
  try {
    sendFrame(ts);
  } finally {
    animsSeen = null;
  }
}

/** [send]'s body: measure, send when changed, then N2's frame ahead. */
function sendFrame(ts: number) {
  const g = geometry();
  if (g !== lastGeometry) {
    lastGeometry = g;
    windowFrame.value++;
    const id = nextFrameId();
    const now = Date.now();
    // Two stamps (wall-clock ms): the rAF's frame time, and now - the send - so the host splits its "rx=" into the page's
    // own share (vsync to this send: rAF scheduling and measuring) and the hop to the host.
    // N2: a frame the last one predicted (sendAhead), measured different from the prediction (its frame came late, a
    // sub-pixel miss), is that prediction's CORRECTION (third stamp "2"): the host puts it on the draw the prediction
    // waits for (FrameSync.correct), as this frame's commit is the one that request rides. Sent as a plain newer frame it
    // was applied at once and the waiting prediction dropped (phone 11-07: 341 predictions sent, 4 applied).
    const fix = predicted != null && geometryChannel.ahead ? " 2" : "";
    if (fix) aheadStats.corrections++;
    const line = `w.f ${id} ${g} ${(now - (performance.now() - ts)).toFixed(2)} ${now}${fix}`;
    sent.push(line);
    if (sent.length > 120) sent.shift();
    glueFrame();
    if (native.value) {
      console.timeStamp(`ww f${id}`);
      sendGeometry(line);
    }
  }
  sendAhead(ts, g);
}

// ---- N2: geometry one frame ahead, bound to the commit that shows it --------------------------------------------
// docs/WEB_WINDOWS.md "Native-glued windows" N2. FrameSync.next applies a "w.f" on the first window draw after it
// arrives - right only when the page's commit is ready by then (pf0 86 % on the phone, 11-07). A visual-state
// request names the draw exactly, but it reaches the renderer after the commit that sent it: it rides the NEXT one.
// So while only main-thread transitions move windows (N1's glued slides; no finger, no resize drag - their next frame
// isn't known yet) the page also sends the geometry of its NEXT frame - each running transition sampled one frame
// on (currentTime + the frame's period, then put back) - with a third stamp "1": the host posts its visual-state
// request now, it rides that next commit, and the layer moves on exactly the draw that shows it. The next frame's own
// measure, when it matches, sends nothing more; when it doesn't (a finger came), it goes out as a normal "w.f" and,
// being newer, wins.

/** Pointers down anywhere on the page: a finger drives the next frame, it can't be sampled ahead. */
const downs = new Set<number>();
addEventListener("pointerdown", (e) => downs.add(e.pointerId), true);
for (const type of ["pointerup", "pointercancel"] as const) addEventListener(type, (e) => downs.delete(e.pointerId), true);
/** The page's frame period (ms), from its rAF times. */
let period = 1000 / 60;
let lastTs = 0;
/** The last frame-ahead geometry, and how the next frame's own measure matched it (gate: `__ww.ahead`). */
let predicted: string | null = null;
const aheadStats = { sent: 0, corrections: 0, errors: [] as number[], steps: [] as number[], jitter: [] as number[], dts: [] as number[] };
let previous: string | null = null;

/** The largest difference between two geometry strings' numbers (their words in the same order), or Infinity. */
function geometryDiff(a: string, b: string): number {
  const x = a.split(" ");
  const y = b.split(" ");
  if (x.length !== y.length) return Infinity;
  let d = 0;
  for (let i = 0; i < x.length; i++) {
    const u = Number(x[i]);
    const v = Number(y[i]);
    if (Number.isFinite(u) && Number.isFinite(v)) d = Math.max(d, Math.abs(u - v));
    else if (x[i] !== y[i]) return Infinity;
  }
  return d;
}

/** The running transitions that carry a window, when ALL of them run on the main thread (registered properties). */
function aheadAnimations(): CSSTransition[] | null {
  const out: CSSTransition[] = [];
  for (const a of frameAnimations()) {
    if (a.playState !== "running") continue;
    const t = (a.effect as KeyframeEffect | null)?.target;
    if (!t || !carriesWindow(t)) continue;
    if (!(a instanceof CSSTransition) || !a.transitionProperty.startsWith("--")) return null;
    out.push(a);
  }
  return out.length ? out : null;
}

/** [send]'s second half: this frame's measure [g] checked against the last prediction, then the next frame's sent. */
function sendAhead(ts: number, g: string) {
  scoreAhead(ts, g);
  const anims = geometryChannel.ahead && !downs.size && !resizing.size ? aheadAnimations() : null;
  if (!anims) return;
  const next = sampleAhead(anims);
  predicted = next;
  // The next frame's own measure compares against this; equal, it isn't sent again.
  lastGeometry = next;
  aheadStats.sent++;
  const now = Date.now();
  const line = `w.f ${nextFrameId()} ${next} ${(now - (performance.now() - ts) + period).toFixed(2)} ${now} 1`;
  if (native.value) sendGeometry(line);
}

/** This frame (rAF time [ts], measured [g]) against the last prediction: its miss, its step, how late the frame came. */
function scoreAhead(ts: number, g: string) {
  const dt = lastTs ? ts - lastTs : period;
  if (predicted != null) {
    aheadStats.errors.push(geometryDiff(predicted, g));
    aheadStats.steps.push(previous != null ? geometryDiff(previous, g) : NaN);
    // The frame came this far off the period the prediction assumed (a page's own jank: the miss is that, not N2's).
    aheadStats.jitter.push(Math.abs(dt - period));
    aheadStats.dts.push(dt);
  }
  if (aheadStats.errors.length > 240) trimAhead();
  if (lastTs) period = Math.min(34, Math.max(4, 0.8 * period + 0.2 * dt));
  lastTs = ts;
  previous = g;
  predicted = null;
}

/** The oldest of [aheadStats]' rows dropped (each list one row per predicted frame). */
function trimAhead() {
  for (const v of [aheadStats.errors, aheadStats.steps, aheadStats.jitter, aheadStats.dts]) v.shift();
}

/** The geometry one frame on: each of [anims] moved on by the period, measured, put back. */
function sampleAhead(anims: CSSTransition[]): string {
  const at = anims.map((a) => Number(a.currentTime));
  anims.forEach((a, i) => {
    const end = Number(a.effect?.getComputedTiming().endTime ?? 0);
    a.currentTime = Math.min(at[i] + period, end - 0.01);
  });
  const next = geometry();
  anims.forEach((a, i) => (a.currentTime = at[i]));
  return next;
}

function kick() {
  dirty = true;
  if (!raf) raf = requestAnimationFrame(tick);
}

/**
 * The next frame sends every window's geometry even if unchanged: a transition (full screen and back, a resize's end,
 * a layer the host re-made) commits the whole layer state - parent, z, crop, position, visibility - at once, never
 * only on the next move (10-30 22:59: a window back from full screen showed a bare hole until it was dragged).
 */
function resendGeometry() {
  lastGeometry = "";
  kick();
}

/**
 * The host's resend ("webwindows.resend": home's surface re-made, the render watchdog's probe or rebind) sends now, not
 * on the next rAF: 10-31 15:37 home's surface came back while the page's rAF was still paused (document hidden), the
 * resend waited for a frame that never ran and the windows stayed empty ~9 s until the watchdog reloaded home. A rAF
 * held from a hidden spell is dropped and asked for again, so the frame loop restarts on the new surface.
 */
function resendNow() {
  lastGeometry = "";
  dirty = true;
  if (webWins.value.length) send(performance.now());
  restartFrames();
}

function restartFrames() {
  if (raf) cancelAnimationFrame(raf);
  raf = 0;
  kick();
}
// Back from hidden (an app full screen, the screen off, home's surface re-made): every window's state at once.
document.addEventListener("visibilitychange", () => {
  if (!document.hidden) resendNow();
});
webWins.subscribe(kick);
tilings.subscribe(kick);
stacks.subscribe(kick);
// A new port (the page reloaded or the host came back): its layers know nothing yet.
native.subscribe((port) => {
  lastGeometry = "";
  kick();
  // Plan 2.4: events sent while the port was down are lost - the snapshot catches the page up.
  if (port && nativeSeen) void rebuildFromHost();
  nativeSeen ||= !!port;
});

// ---- the window element: DOM title bar, buttons, edges, tile menu, the body ------------------------------------------

/** The window whose tile menu is open, or null. */
export const tileMenu = signal<number | null>(null);

/** A double tap on the bar within this (ms): full screen, as its bar's full screen button (the user, 10-30). */
const DOUBLE_TAP_MS = 350;
/** A bar drag let go this near the work area's left/right edge snaps to that half; near a corner, its quarter. */
const SNAP_EDGE = 24;
const SNAP_CORNER = 120;
const SLOP = 6;

/** The corner or half each side snaps to: top, middle, bottom of the work area. */
const SNAPS_AT: Record<"l" | "r", [Slot, Slot, Slot]> = { l: ["tl", "left", "bl"], r: ["tr", "right", "br"] };

/** Where a bar drag let go at ([x], [y]) snaps (docs "Tiles": drag to an edge), or null. */
function snapSlot(x: number, y: number): Slot | null {
  const a = tileArea();
  const side = x <= a.left + SNAP_EDGE ? "l" : x >= a.right - SNAP_EDGE ? "r" : null;
  if (!side) return null;
  const row = y <= a.top + SNAP_CORNER ? 0 : y >= a.bottom - SNAP_CORNER ? 2 : 1;
  return SNAPS_AT[side][row];
}

/**
 * Its bar's buttons, right to left: close, full screen, minimise, tile (the old native bar's order). Only the id and
 * whether it is maximised: the whole window re-rendered them (4 Marks) on every frame of its drag (render scan 10-31).
 */
const Controls = memo(function Controls({ id, restore }: { id: number; restore: boolean }) {
  const press = (f: () => void) => ({
    onPointerDown: (e: PointerEvent) => e.stopPropagation(),
    onClick: (e: MouseEvent) => (e.stopPropagation(), f()),
  });
  return (
    <div class="ww-controls">
      <button class="ww-button" aria-label="Tile" {...press(() => (tileMenu.value = tileMenu.value === id ? null : id))}>
        <Mark kind="tile" />
      </button>
      <button class="ww-button" aria-label="Minimise" {...press(() => minimise(id))}>
        <Mark kind="minimise" />
      </button>
      <button class="ww-button" aria-label="Full screen" {...press(() => fullScreen(id))}>
        <Mark kind={restore ? "restore" : "maximise"} />
      </button>
      <button class="ww-button ww-close" aria-label="Close" {...press(() => close(id))}>
        <Mark kind="close" />
      </button>
    </div>
  );
});

/** Full screen = a real full-screen app on the main display (WebWindows.fullScreen); with no host, the work area. */
function fullScreen(id: number) {
  tileMenu.value = null;
  if (native.value && powos.webwindows?.fullScreen && id >= 0) void powos.webwindows.fullScreen(id);
  else toggleMaximise(id);
}

function close(id: number) {
  tileMenu.value = null;
  // A placeholder (id < 0, LW3) is the page's alone.
  if (native.value && powos.webwindows?.close && id >= 0) void powos.webwindows.close(id);
  else {
    leaveStack(id);
    untile(id, "gone");
    webWins.value = webWins.value.filter((w) => w.id !== id);
  }
}

/** The tile menu, under the tile button: DOM over the window's body (it takes its taps by DOM order). */
function TileMenu({ win, leaving }: { win: WebWin; leaving: boolean }) {
  const tiled = tiledOn(win.id) != null;
  const items: [Slot, string][] = [["left", "Left half"], ["right", "Right half"], ["top", "Top half"], ["bottom", "Bottom half"], ["grid", "Grid"]];
  if (tiled) items.push(["float", "Float"]);
  return (
    <div class={`ww-tile-menu tile sheet pop ${leaving ? "leaving" : ""}`} inert={leaving || undefined} onPointerDown={(e) => e.stopPropagation()}>
      {items.map(([slot, label]) => (
        <button
          key={slot}
          class="ww-tile-item"
          data-slot={slot}
          onClick={(e) => {
            e.stopPropagation();
            tileMenu.value = null;
            tile(win.id, slot);
          }}
        >
          {label}
        </button>
      ))}
    </div>
  );
}
// A press anywhere else closes the tile menu.
addEventListener("pointerdown", (e) => {
  if (tileMenu.value != null && !(e.target as Element | null)?.closest?.(".ww-tile-menu, .ww-button")) tileMenu.value = null;
}, true);

/**
 * A window's one-finger gesture in progress (its bar's move, an edge's resize, its body's press to the app): how to end
 * it unfinished when a second finger makes the gesture a pinch ([usePinch]). The body's sends the app a cancel.
 */
const oneFinger = new Map<number, () => void>();

/** PZ1: a window's body taking another finger of its gesture that landed off the body (the bar, a zone), by window id. */
const bodyFinger = new Map<number, (e: PointerEvent) => void>();

/** A pinch's floor (the old native frame's MIN_SCALE) and ceiling (never past the work area either: [usePinch]). */
export const MIN_SCALE = 0.4;
export const MAX_SCALE = 1.5;

/** TS1: a tiled window's content zoom range (the host's WindowDpi.MIN_ZOOM..MAX_ZOOM). */
export const MIN_ZOOM = 0.5;
export const MAX_ZOOM = 2;

/** TS1: a pinch on a tiled window's bar in progress: the body's preview scale (new zoom / old), by window id. */
export const zoomPreview = signal<{ id: number; k: number } | null>(null);

/** TS1: window [id]'s content zoom [k] (clamped, 3 decimals) kept on it and sent to the host (its display's dpi). */
export function setZoom(id: number, k: number) {
  const z = Math.round(Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, k)) * 1000) / 1000;
  update(id, { zoom: z === 1 ? undefined : z });
  if (id >= 0) void powos.webwindows?.zoom?.(id, z).catch(() => false);
}

/** TS1: a tiled window's pinch [p] let go: its preview ends, the app's display takes the new density. */
function zoomReleased(id: number, p: { s0: number; k: number }) {
  if (zoomPreview.value?.id === id) zoomPreview.value = null;
  if (p.k !== p.s0) setZoom(id, p.k);
  p.s0 = p.k;
}

/** TS1: a tiled window's pinch from zoom [s0] at spread [spread0]: the zoom at spread [d], clamped. */
function zoomAt(s0: number, spread0: number, d: number) {
  return spread0 > 0 ? Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, (s0 * d) / spread0)) : s0;
}

/**
 * SC1 (the user, 10-31: "Doing the two finger scaling motion is no longer scaling it, it's resizing it"): two fingers
 * on a window (bar or body) SCALE it - the whole frame, bar and app, zoomed uniformly like a picture; the app keeps its
 * size (w, h: no relayout), its layer is drawn at the frame's measured scale (entry()). Scale = start x spread / start
 * spread, [MIN_SCALE]..[MAX_SCALE] and no bigger than the work area; the window point under the fingers' centroid stays
 * under it. The scale is saved with the window. An edge or a grip RESIZES (w, h; the bar stays [TITLE]: RB1). The
 * first finger's gesture ends unfinished ([oneFinger]). One finger never scales: a primary pointer down starts a new
 * touch.
 * PZ1 (the user, 10-31 01:40: "I shouldn't be able to rescale the window with two fingers unless I'm pressing the
 * corners/resizers. If I zoom normally IN the app, I'm now resizing the window"): only a gesture whose FIRST finger is on
 * the chrome (the bar, an edge zone or corner grip) scales; a second finger on the body then is still the pinch's. A
 * gesture that starts on the body is the app's, every finger ([Body]: one multi-touch gesture, a pinch zooms Chrome's
 * page), a later finger off the body included ([bodyFinger]).
 * TS1 (the user, 10-31 15:31: "when I try to scale it, it just detaches the window"): on a TILED window the same pinch
 * scales the app's CONTENT ([WebWin.zoom]): the tile stays where it is, in the tiling; the body previews it (a CSS
 * scale of the app's layer, [zoomPreview]) and the host's display takes the new density on release ([setZoom]).
 */
function usePinch(win: WebWin) {
  const fingers = useRef(new Map<number, { x: number; y: number }>());
  const pinch = useRef<{ spread0: number; s0: number; px: number; py: number; tiled: boolean; k: number } | null>(null);
  const onBody = useRef(false);
  const live = useRef(win);
  live.current = win;
  const spread = () => {
    const [a, b] = [...fingers.current.values()];
    return { cx: (a.x + b.x) / 2, cy: (a.y + b.y) / 2, d: Math.hypot(a.x - b.x, a.y - b.y) };
  };
  // PZ1: finger [e] counted; true = the gesture is the body's (its first finger was there): never a pinch.
  const bodyGesture = (e: PointerEvent) => {
    const inBody = !!(e.target as Element | null)?.closest?.(".webwindow-body");
    if (!fingers.current.size) onBody.current = inBody;
    fingers.current.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (onBody.current && !inBody) (e.stopPropagation(), bodyFinger.get(win.id)?.(e));
    return onBody.current;
  };
  const down = (e: PointerEvent) => {
    // The first finger of a new touch starts clean: an earlier finger's up that landed outside this frame was never
    // seen here, and a stale entry made the next one-finger drag a pinch (10-30: "dragging with one finger rescales").
    if (e.isPrimary) (fingers.current.clear(), (pinch.current = null));
    if (bodyGesture(e) || fingers.current.size !== 2 || pinch.current) return;
    e.stopPropagation();
    oneFinger.get(win.id)?.();
    oneFinger.delete(win.id);
    const w = live.current;
    const o = pageOrigin();
    const f = spread();
    // TS1: a tiled window's pinch zooms its content in place (it once untiled the window here: the detach).
    const tiled = tiledOn(w.id) != null;
    const s0 = (tiled ? w.zoom : w.scale) ?? 1;
    pinch.current = { spread0: f.d, s0, px: (f.cx - o.x - w.x) / s0, py: (f.cy - o.y - w.y) / s0, tiled, k: s0 };
  };
  const move = (e: PointerEvent) => {
    if (!fingers.current.has(e.pointerId)) return;
    fingers.current.set(e.pointerId, { x: e.clientX, y: e.clientY });
    const p = pinch.current;
    if (!p) return;
    e.stopPropagation();
    if (fingers.current.size < 2) return;
    const f = spread();
    const w = live.current;
    if (p.tiled) return void ((p.k = zoomAt(p.s0, p.spread0, f.d)), (zoomPreview.value = { id: w.id, k: p.k / p.s0 }));
    const a = workArea();
    const top = Math.max(MIN_SCALE, Math.min(MAX_SCALE, (a.right - a.left) / w.w, (a.bottom - a.top) / w.h));
    const k = p.spread0 > 0 ? Math.min(top, Math.max(MIN_SCALE, (p.s0 * f.d) / p.spread0)) : p.s0;
    const o = pageOrigin();
    const at = clampPlace(f.cx - o.x - p.px * k, f.cy - o.y - p.py * k, w.w * k);
    update(w.id, { x: Math.round(at.x), y: Math.round(at.y), scale: Math.round(k * 1000) / 1000, restore: undefined });
  };
  const up = (e: PointerEvent) => {
    fingers.current.delete(e.pointerId);
    if (!pinch.current) return;
    e.stopPropagation();
    if (pinch.current.tiled && fingers.current.size < 2) zoomReleased(live.current.id, pinch.current);
    if (fingers.current.size === 0) pinch.current = null;
  };
  return { onPointerDownCapture: down, onPointerMoveCapture: move, onPointerUpCapture: up, onPointerCancelCapture: up };
}

/**
 * Its title bar: moves it (a drag), full screen (a double tap), snaps it to a tile (let go at an edge). [auto] (TB1): it
 * auto-hides - out of the layout, slid in over the app by a pull from the top (ui/barreveal.ts), kept while pressed.
 */
function TitleBar({ win, auto = false }: { win: WebWin; auto?: boolean }) {
  const drag = useRef<{ px: number; py: number; x: number; y: number; moved: boolean; tiled: boolean } | null>(null);
  const lastTap = useRef(0);
  const merged = !!win.restore && !auto;
  const end = (e: PointerEvent, cancelled: boolean) => {
    if (auto) releaseReveal(win.id);
    const d = drag.current;
    if (!d) return;
    e.stopPropagation();
    drag.current = null;
    if (cancelled || !d.moved) clearAim();
    if (cancelled) return;
    if (!d.moved) {
      const now = performance.now();
      if (now - lastTap.current < DOUBLE_TAP_MS) (fullScreen(win.id), (lastTap.current = 0));
      else lastTap.current = now;
      return;
    }
    release(win.id, e.clientX, e.clientY);
  };
  const aimed = tabView.value?.target === win.id ? tabView.value : null;
  return (
    <div
      class={`webwindow-title ${merged ? "merged" : "tile"}${aimed ? " ww-tab-target" : ""}`}
      style={{ height: `${TITLE}px`, flex: `0 0 ${TITLE}px`, touchAction: "none" }}
      onPointerDown={(e) => {
        e.stopPropagation();
        if (auto) holdReveal(win.id);
        raise(win.id);
        capture(e);
        drag.current = { px: e.clientX, py: e.clientY, x: win.x, y: win.y, moved: false, tiled: tiledOn(win.id) != null };
        oneFinger.set(win.id, () => ((drag.current = null), clearAim()));
      }}
      onPointerMove={(e) => {
        const d = drag.current;
        if (!d) return;
        e.stopPropagation();
        const dx = e.clientX - d.px;
        const dy = e.clientY - d.py;
        if (!d.moved && Math.hypot(dx, dy) < SLOP) return;
        if (!d.moved && tiledOn(win.id) != null) untile(win.id, "keep");
        d.moved = true;
        update(win.id, { ...clampPlace(d.x + dx, d.y + dy, win.w), restore: undefined });
        // GL1: a floating window docks; one dragged out of the tiles floats (the tiles fill the area: it would re-dock).
        // WT1: either one joins another window's bar as a tab.
        aim(win.id, e.clientX, e.clientY, !d.tiled);
      }}
      onPointerUp={(e) => end(e, false)}
      onPointerCancel={(e) => end(e, true)}
    >
      <BarLabel win={win} aimed={aimed} merged={merged} />
      <div class="ww-spacer" />
      <div class={merged ? "tile ww-controls-glass" : "ww-controls-glass"}>
        <Controls id={win.id} restore={merged} />
      </div>
    </div>
  );
}

/**
 * WT2: a stack's bar is its tab strip - each tab its app's icon, name and a close; the shown one lit. A drop aimed at
 * this bar ([tabView]) lights the bar and shows a ghost tab where it would land, browser-style (also on a window of
 * one: what the stack would look like).
 */
/** The bar's title: its icon and name, or (a stack, or a tab drop aimed here) the tab strip. */
function BarLabel({ win, aimed, merged }: { win: WebWin; aimed: { id: number; at: number } | null; merged: boolean }) {
  const stack = stackOf(win.id);
  if (stack || aimed) return <Tabs win={win} ids={stack?.ids ?? [win.id]} aimed={aimed} merged={merged} />;
  return (
    <div class={`ww-title-label ${merged ? "tile" : ""}`}>
      {iconOf(win.key) && <img class="ww-icon" src={iconOf(win.key)!} alt="" draggable={false} />}
      <span>{win.label}</span>
    </div>
  );
}

function Tabs({ win, ids, aimed, merged }: { win: WebWin; ids: number[]; aimed: { id: number; at: number } | null; merged: boolean }) {
  const list = ids.map((id) => webWins.value.find((w) => w.id === id)).filter((w): w is WebWin => !!w);
  const items = list.map((w) => <Tab key={w.id} w={w} active={w.id === win.id} shown={win.id} />);
  const ghost = aimed && webWins.value.find((w) => w.id === aimed.id);
  if (ghost) {
    items.splice(aimed.at < 0 ? items.length : aimed.at, 0, (
      <div key="ghost" class="ww-tab ghost">
        {iconOf(ghost.key) && <img class="ww-icon" src={iconOf(ghost.key)!} alt="" draggable={false} />}
        <span>{ghost.label}</span>
      </div>
    ));
  }
  return <div class={`ww-title-label ww-tabs ${merged ? "tile" : ""}`}>{items}</div>;
}

function Tab({ w, active, shown }: { w: WebWin; active: boolean; shown: number }) {
  return (
    <div class={`ww-tab${active ? " active" : ""}`} data-tab={w.id} onPointerDown={(e) => tabPress(e, w.id, shown)}>
      {iconOf(w.key) && <img class="ww-icon" src={iconOf(w.key)!} alt="" draggable={false} />}
      <span>{w.label}</span>
      <button
        class="ww-tab-close"
        aria-label={`Close ${w.label}`}
        onPointerDown={(e) => e.stopPropagation()}
        onClick={(e) => (e.stopPropagation(), close(w.id))}
      >
        <Mark kind="close" />
      </button>
    </div>
  );
}

let lastTabTap = { id: 0, at: 0 };
/**
 * A press on tab [id] of the stack shown as [shown]: a tap shows it (a double tap: full screen, as the bar's), a drag
 * along the bar reorders it, out of the bar (a bar's height off it, or past its ends) undocks it - then it is a bar drag
 * (move, tile drop, edge snap, another bar's tabs). Window listeners: the tab's element goes when its stack does.
 */
function tabPress(e: PointerEvent, id: number, shown: number) {
  if (!e.isPrimary) return;
  e.stopPropagation();
  raise(shown);
  const pid = e.pointerId;
  const bar = (e.currentTarget as HTMLElement).closest(".webwindow-title")!.getBoundingClientRect();
  const grabX = Math.min(e.clientX - (e.currentTarget as HTMLElement).getBoundingClientRect().left, 120);
  const start = { x: e.clientX, y: e.clientY };
  let moved = false;
  let out = false;
  const stop = () => {
    removeEventListener("pointermove", move, true);
    removeEventListener("pointerup", up, true);
    removeEventListener("pointercancel", cancel, true);
    oneFinger.delete(shown);
  };
  const cancel = (ev: PointerEvent) => {
    if (ev.pointerId !== pid) return;
    stop();
    clearAim();
  };
  const move = (ev: PointerEvent) => {
    if (ev.pointerId !== pid) return;
    ev.stopPropagation();
    if (!moved && Math.hypot(ev.clientX - start.x, ev.clientY - start.y) < SLOP) return;
    moved = true;
    const off = Math.abs(ev.clientY - (bar.top + bar.height / 2)) > bar.height || ev.clientX < bar.left - TITLE || ev.clientX > bar.right + TITLE;
    if (!out && off) (out = true), undock(id);
    if (!out) return reorder(id, shown, ev.clientX);
    const w = webWins.value.find((v) => v.id === id);
    if (!w) return;
    const o = pageOrigin();
    update(id, clampPlace(ev.clientX - o.x - grabX, ev.clientY - o.y - TITLE / 2, w.w));
    aim(id, ev.clientX, ev.clientY);
  };
  const up = (ev: PointerEvent) => {
    if (ev.pointerId !== pid) return;
    ev.stopPropagation();
    stop();
    if (out) return release(id, ev.clientX, ev.clientY);
    if (moved) return;
    const now = performance.now();
    if (lastTabTap.id === id && now - lastTabTap.at < DOUBLE_TAP_MS) return (fullScreen(id), (lastTabTap = { id: 0, at: 0 }));
    lastTabTap = { id, at: now };
    showTab(id);
  };
  addEventListener("pointermove", move, true);
  addEventListener("pointerup", up, true);
  addEventListener("pointercancel", cancel, true);
  oneFinger.set(shown, () => (stop(), clearAim()));
}

const MIN_W = 220;
const MIN_H = 160;
const EDGES = ["n", "s", "e", "w", "ne", "nw", "se", "sw"] as const;

type Grab = { px: number; py: number; x: number; y: number; w: number; h: number };

/** RZ4: a resized frame's side this near (screen px) a tile's (half, third, quarter of the work area, gaps out) snaps to it. */
const SNAP_SIZE = 16;
const SNAP_PARTS = [2, 3, 4];

/** Length [len] (frame px at scale [k]) snapped to a tile's along a work area [span] wide (screen px), or as it is. */
function snapLen(len: number, k: number, span: number): number {
  for (const n of SNAP_PARTS) {
    const t = (span - (n - 1) * TILE_GAP) / n / k;
    if (Math.abs(len - t) * k <= SNAP_SIZE) return t;
  }
  return len;
}

/** One axis of a resize: the frame's new length when its far side ([sign] 1) or near side (-1) follows [d] (0: neither). */
function resizeLen(len: number, d: number, sign: number, o: { min: number; k: number; span: number }): number {
  if (!sign) return len;
  return Math.max(o.min, snapLen(len + sign * d, o.k, o.span));
}
/** A side's sign along an axis: [far] in [side] 1, [near] -1, neither 0. */
const signOf = (side: string, far: string, near: string) => (side.includes(far) ? 1 : side.includes(near) ? -1 : 0);

/** RZ4: the resize in progress (its live size outline): the window, and its snapped sides ("w", "h", "wh" or ""). */
export const resizeView = signal<{ id: number; snapped: string } | null>(null);

/** Window [id]'s frame resized from [s] by pointer [e] on edges [side] (an Edge grab, or the app's own), scale [k]. */
function resizeBy(id: number, s: Grab & { side: string; k: number }, e: PointerEvent) {
  const { side, k } = s;
  const a = renderLayout().area;
  const dx = (e.clientX - s.px) / k;
  const dy = (e.clientY - s.py) / k;
  const r = {
    x: s.x,
    y: s.y,
    w: resizeLen(s.w, dx, signOf(side, "e", "w"), { min: MIN_W, k, span: a.right - a.left }),
    h: resizeLen(s.h, dy, signOf(side, "s", "n"), { min: MIN_H, k, span: a.bottom - a.top }),
  };
  if (side.includes("w")) r.x = s.x + s.w - r.w;
  if (side.includes("n")) r.y = s.y + s.h - r.h;
  // DB1: the top edge stops at the status bar (the bar stays reachable).
  const top = clampPlace(r.x, r.y, r.w).y;
  if (r.y < top) (r.h -= top - r.y), (r.y = top);
  const pacing = resizing.get(id);
  if (pacing) pacing.steps++;
  showSnap(id, r, k, a);
  const next = { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.w), h: Math.round(r.h) };
  if (!resizeLive(id, next)) update(id, { ...next, restore: undefined });
}

/**
 * RS5c (ww-resize-cost 11-08 after RS5b: 16 component renders a move - both pages' PageUnder and WebWindowsOn, the
 * dragged window's whole tree - most of a move's script): a resize drag's move renders nothing. Window [id]'s WebWin
 * takes its new frame [next] IN PLACE (no webWins write: every reader - the tick's entry, clamps, holes, a render for
 * another reason - sees the live frame), and the move writes only what the frame drives, straight to the DOM: the
 * frame's box, its shadow's, the outline's size, the masks of the windows under it and of the page's own content.
 * [resizeEnd] commits it (a new WebWin: one render, every derived prop exact). A Preact render diffs against its last
 * vnode, never the DOM, and each value written here is the one that render would write, so the two never disagree.
 * false: a move that changes more (a maximised frame's restore, a zone height near a system strip): [update] it.
 */
function resizeLive(id: number, next: { x: number; y: number; w: number; h: number }): boolean {
  const w = webWins.peek().find((v) => v.id === id);
  const frame = document.querySelector<HTMLElement>(`.webwindow[data-wwid="${id}"]`);
  if (!w || !frame || !liveable(w, next)) return false;
  Object.assign(w, next);
  liveSized.add(id);
  writeFrame(frame, w);
  cutAll(frame.closest<HTMLElement>(".page-windows"), windowsHere(w.page));
  const under = frame.closest(".page")?.querySelector<HTMLElement>(":scope > .page-under");
  if (under) writeMask(under, underWindows(w.page));
  return true;
}
/** [w]'s drag may take [next] live: a resize drag's, a floating frame, its zones' heights (near the strips) unchanged. */
const liveable = (w: WebWin, next: Partial<WebWin>) => resizing.has(w.id) && !w.restore && !w.quick && zoneKey({ ...w, ...next }) === zoneKey(w);

/** [w]'s frame [frame], its shadow and its size outline as its render would write them (RS5c: [resizeLive]). */
function writeFrame(frame: HTMLElement, w: WebWin) {
  setBox(frame, w);
  const shadow = frame.parentElement?.querySelector<HTMLElement>(`.ww-shadow[data-wwid="${w.id}"]`);
  const b = frameBox(w);
  if (shadow) sliceShadow(shadow, w.id, { x: b.x - SHADOW_PAD, y: b.y - SHADOW_PAD, w: b.w + 2 * SHADOW_PAD, h: b.h + 2 * SHADOW_PAD });
  const size = frame.querySelector(".ww-outline-size");
  // Its text nodes' data (the size, " × ", the size): Preact keeps these nodes and diffs their text on its next render.
  if (size?.firstChild instanceof Text && size.lastChild instanceof Text) {
    size.firstChild.data = String(Math.round(b.w));
    size.lastChild.data = String(Math.round(b.h));
  }
}
/**
 * RS6 (11-11, the phone's resize trace: the shadow's element resized every move re-rastered its blur into the page's
 * windows layer, `.page-windows`, 97 tiles over a 1.7 s drag): through a resize drag a window's shadow is a 9-slice of
 * itself as it was at the drag's start - 4 corners moved, 4 edges moved and stretched along their length (a box
 * shadow's edge is the same all along it, so the stretch is exact), each its own composited layer: a move sets 8
 * transforms and repaints nothing. The element keeps its start box until [unslice] at the drag's end (the commit render
 * writes the final one). Not sliced: a shadow masked by a window above it (its mask would cut a piece past its box), or
 * one too small for the corners.
 */
/** A 9-slice corner: the shadow's reach past the frame and the frame's rounded corner with room. */
const S9_IN = 48;
const S9_PIECES = [
  ["nw", 0, 0], ["n", 1, 0], ["ne", 2, 0], ["w", 0, 1], ["e", 2, 1], ["sw", 0, 2], ["s", 1, 2], ["se", 2, 2],
] as const;
const S9 = () => SHADOW_PAD + S9_IN;
type Slice = { el: HTMLElement; x: number; y: number; w: number; h: number; pieces: HTMLElement[] };
const sliced = new Map<number, Slice>();
function sliceShadow(shadow: HTMLElement, id: number, box: Box) {
  let s = sliced.get(id);
  if (!s) {
    const st = shadow.style;
    const r = { x: parseFloat(st.left), y: parseFloat(st.top), w: parseFloat(st.width), h: parseFloat(st.height) };
    if (st.maskImage || !(r.w > 2 * S9() && r.h > 2 * S9() && box.w > 2 * S9() && box.h > 2 * S9())) return setBox(shadow, box);
    s = { el: shadow, ...r, pieces: S9_PIECES.map(([, i, j]) => slicePiece(shadow, r, i, j)) };
    shadow.classList.add("sliced");
    sliced.set(id, s);
  }
  if (box.w <= 2 * S9() || box.h <= 2 * S9()) return; // MIN_W/MIN_H keep a frame past this; the last good place stays
  const dx = box.x - s.x, dy = box.y - s.y, ew = box.w - s.w, eh = box.h - s.h;
  const sx = (box.w - 2 * S9()) / (s.w - 2 * S9()), sy = (box.h - 2 * S9()) / (s.h - 2 * S9());
  S9_PIECES.forEach(([, i, j], k) => {
    const tx = dx + (i === 2 ? ew : 0), ty = dy + (j === 2 ? eh : 0);
    s.pieces[k].style.transform = `translate(${tx}px, ${ty}px) scale(${i === 1 ? sx : 1}, ${j === 1 ? sy : 1})`;
  });
}
/** One piece of [shadow]'s 9-slice (column [i], row [j]; 1 = the stretched middle) at its start box [r]. */
function slicePiece(shadow: HTMLElement, r: Box, i: number, j: number): HTMLElement {
  const at = (k: number, len: number) => (k === 0 ? 0 : k === 1 ? S9() : len - S9());
  const size = (k: number, len: number) => (k === 1 ? len - 2 * S9() : S9());
  const p = document.createElement("div");
  p.className = "ww-s9";
  const px = at(i, r.w), py = at(j, r.h);
  setBox(p, { x: px, y: py, w: size(i, r.w), h: size(j, r.h) });
  const inner = document.createElement("div");
  inner.className = "ww-s9-in";
  setBox(inner, { x: SHADOW_PAD - px, y: SHADOW_PAD - py, w: r.w - 2 * SHADOW_PAD, h: r.h - 2 * SHADOW_PAD });
  p.append(inner);
  shadow.append(p);
  return p;
}
/** Window [id]'s shadow whole again at frame [w]'s box (the drag's end; the commit render writes the same box). */
function unslice(id: number, w: WebWin | undefined) {
  const s = sliced.get(id);
  if (!s) return;
  sliced.delete(id);
  s.pieces.forEach((p) => p.remove());
  s.el.classList.remove("sliced");
  if (!w) return;
  const b = frameBox(w);
  setBox(s.el, { x: b.x - SHADOW_PAD, y: b.y - SHADOW_PAD, w: b.w + 2 * SHADOW_PAD, h: b.h + 2 * SHADOW_PAD });
}

/** Windows resized live ([resizeLive]) since their drag began: [resizeEnd] commits them. */
const liveSized = new Set<number>();
const setBox = (el: HTMLElement, b: { x: number; y: number; w: number; h: number }) => {
  el.style.left = `${b.x}px`;
  el.style.top = `${b.y}px`;
  el.style.width = `${b.w}px`;
  el.style.height = `${b.h}px`;
};
/** [m] on [el]'s inline style where it differs (the same value again is no style change: no restyle). */
function writeMask(el: HTMLElement, m: Record<string, string> | undefined) {
  for (const p of MASK_PROPS) if (el.style[p] !== (m?.[p] ?? "")) el.style[p] = m?.[p] ?? "";
}

/** The outline's snapped sides for frame [r]; a haptic tick as a side snaps (RZ4). */
function showSnap(id: number, r: { w: number; h: number }, k: number, a: Area) {
  const on = (len: number, span: number) => SNAP_PARTS.some((n) => Math.abs(len - (span - (n - 1) * TILE_GAP) / n / k) < 0.5);
  const snapped = (on(r.w, a.right - a.left) ? "w" : "") + (on(r.h, a.bottom - a.top) ? "h" : "");
  const was = resizeView.value;
  if (was?.id === id && was.snapped === snapped) return;
  if (snapped && snapped !== was?.snapped) hapticTick();
  resizeView.value = { id, snapped };
}

/** A hold this long, still, on the app's own drag (its tab strip): the tile menu - PowOS's frame features for it. */
const HOLD_MS = 500;

/** An app's own frame drag in progress ("webwindows.moveresize"), by window id: the Body's pointer drives it. */
interface AppDrag {
  edges: string;
  start: Grab | null;
  moved: boolean;
  hold: number;
}
const appDrags = new Map<number, AppDrag>();

/** An edge zone's press this near (frame px) a corner resizes from that corner (RZ2: the strips' ends are the corner's). */
const CORNER_ALONG = 24;

/** GR1: how far (screen px) a bottom corner's zone reaches in over the frame's corner, under its drawn grip (shell.css). */
export const CORNER_IN = 14;

/** The sides a press [e] on edge zone [side] resizes: a strip's end near a corner is that corner. */
function sideAt(side: string, e: PointerEvent): string {
  if (side.length === 2) return side;
  const f = (e.currentTarget as HTMLElement).parentElement!.getBoundingClientRect();
  const near = (v: number, lo: number, hi: number) => (v < lo + CORNER_ALONG ? 0 : v > hi - CORNER_ALONG ? 1 : -1);
  if (side === "e" || side === "w") return (["n", "s"][near(e.clientY, f.top, f.bottom)] ?? "") + side;
  return side + (["w", "e"][near(e.clientX, f.left, f.right)] ?? "");
}

/**
 * RZ7: a press on an outer zone that lands on ANOTHER window's frame is that window's - the zone is invisible, the
 * window under it is what the finger sees. Cascaded windows sit 32 dp apart ([cascade]), exactly a zone's depth, so
 * the newer window's top zone covered the whole visible strip of the one under it - its bar and its close button: a
 * tap there grabbed the newer window instead (window-bench 11-08: the storm's closes missed, the apps stayed open and
 * their next launches only raised them - "NOT LOADING storm 6 kate"). Now a button under the press is pressed, else
 * that window comes on top (a bar tap's switch). true: passed on (no resize).
 */
function zonePassedOn(e: PointerEvent): boolean {
  const own = (e.currentTarget as HTMLElement).closest(".webwindow");
  const under = document.elementsFromPoint(e.clientX, e.clientY).find((el) => !own?.contains(el));
  const other = under?.closest<HTMLElement>(".webwindow[data-wwid]");
  if (!under || !other) return false;
  const button = under.closest<HTMLElement>("button");
  if (button && other.contains(button)) button.click();
  else raise(Number(other.dataset.wwid));
  return true;
}

/**
 * A resize grab (RZ2): an invisible zone OUTSIDE the frame - 32 dp along each edge, 48x48 dp off each corner - so it
 * never covers the app or the bar's buttons (the bottom corners also reach CORNER_IN in, under their drawn grips: GR1); a higher window's content is over a lower window's zones (z order: the
 * DOM's hit test). The frame follows the finger, the app's size paced ([pace]: RS1), the final on release; a haptic
 * tick on the grab, the live size outline ([resizeView]) while it lasts, tile sizes snapped to ([snapLen]: RZ4).
 */
function Edge({ id, side, height }: { id: number; side: (typeof EDGES)[number]; height?: string }) {
  const start = useRef<(Grab & { side: string }) | null>(null);
  const stop = (e: PointerEvent) => {
    if (!start.current) return;
    e.stopPropagation();
    start.current = null;
    resizeView.value = null;
    resizeEnd(id);
  };
  return (
    <div
      class={`ww-edge ww-edge-${side}`}
      style={{ height }}
      onPointerDown={(e) => {
        e.stopPropagation();
        if (zonePassedOn(e)) return;
        const win = webWins.value.find((w) => w.id === id);
        if (!win) return;
        raise(id);
        flashGrips(id);
        capture(e);
        if (tiledOn(id) != null) untile(id, "keep");
        start.current = { px: e.clientX, py: e.clientY, x: win.x, y: win.y, w: win.w, h: win.h, side: sideAt(side, e) };
        hapticTick();
        resizeView.value = { id, snapped: "" };
        resizeStart(id);
        oneFinger.set(id, () => ((start.current = null), (resizeView.value = null), resizeEnd(id)));
      }}
      onPointerMove={(e) => {
        const s = start.current;
        if (!s) return;
        e.stopPropagation();
        resizeBy(id, { ...s, k: webWins.value.find((w) => w.id === id)?.scale ?? 1 }, e);
      }}
      onPointerUp={stop}
      onPointerCancel={stop}
    />
  );
}

const CORNERS = ["se", "sw", "ne", "nw"] as const;

/** RZ6 (the user, 10-31: "We just need to show this briefly ... like when we activate the windows"): how long the grips show. */
export const GRIPS_MS = 1500;
/** The window whose corner grips show now ([flashGrips]); null: none (the zones stay live without them). */
export const gripsOn = signal<number | null>(null);
let gripsTimer = 0;

/** Shows window [id]'s grips for [GRIPS_MS] (an activation, a press on its edge zones), then they fade out. */
export function flashGrips(id: number) {
  gripsOn.value = id;
  clearTimeout(gripsTimer);
  gripsTimer = window.setTimeout(() => {
    if (gripsOn.peek() === id) gripsOn.value = null;
  }, GRIPS_MS);
}

// A window coming to the front (opened, raised, focused): its grips flash.
let frontId: number | undefined;
effect(() => {
  const top = webWins.value.at(-1)?.id;
  if (top === frontId) return;
  frontId = top;
  if (top != null) flashGrips(top);
});

/** The screen's system strips (px from the top / bottom): the status bar's and the gesture bar's, 24 px at least. */
function systemStrips(): { top: number; bottom: number } {
  return renderLayout().strips;
}

function readStrips(): { top: number; bottom: number } {
  const css = getComputedStyle(document.documentElement);
  const inset = (name: string) => parseFloat(css.getPropertyValue(name)) || 0;
  return { top: Math.max(24, inset("--inset-top")), bottom: Math.max(24, inset("--inset-bottom")) };
}

/**
 * RZ5: zone [side]'s height clamped out of the system strips (frame px at scale [k]): an n/ne/nw zone never reaches
 * into the status strip, an s/se/sw one never into the bottom gesture area - those touches stay the system's. Undefined:
 * the zone's own size (CSS).
 */
function zoneHeight(win: WebWin, side: string): string | undefined {
  const k = win.scale ?? 1;
  const strips = systemStrips();
  const top = renderLayout().origin.y + win.y;
  const zone = side.length === 2 ? 48 : 32;
  if (side.startsWith("n")) {
    const room = Math.max(0, top - strips.top);
    return room < zone ? `${room / k}px` : undefined;
  }
  if (side.startsWith("s")) {
    const room = Math.max(0, innerHeight - strips.bottom - (top + win.h * k));
    // GR1: a bottom corner's square starts CORNER_IN screen px inside the frame (shell.css), so it keeps that part.
    const inset = side.length === 2 ? CORNER_IN : 0;
    return room < zone ? `${(room + inset) / k}px` : undefined;
  }
  return undefined;
}

/** RZ1: a corner's grip - a short arc hugging the frame's rounded corner, outside it (drawn; the zone takes the press). */
function Grip({ corner }: { corner: (typeof CORNERS)[number] }) {
  return (
    <svg class={`ww-grip ww-grip-${corner}`} viewBox="0 0 22 22" aria-hidden="true">
      <path d="M19 2A17 17 0 0 1 2 19" />
    </svg>
  );
}

/**
 * WX1: the ⇄ hint on a snapped half's inner edge, beside the divider's pill (centre-right of a left half...): round
 * glass, shown and faded with the grips (RZ6: [flashGrips]), its hit area only its circle and nothing while faded.
 * A tap swaps the two sides ([swapWindow]); its grips flash again so it stays to swap back.
 */
function SwapHint({ win }: { win: WebWin }) {
  const edge = swapEdge(win);
  if (!edge) return null;
  return (
    <button
      class={`ww-swap tile ww-swap-${edge}`}
      aria-label="Swap sides"
      onPointerDown={(e) => e.stopPropagation()}
      onPointerUp={(e) => {
        e.stopPropagation();
        swapWindow(win.id);
        flashGrips(win.id);
      }}
    >
      <svg viewBox="0 0 24 24" aria-hidden="true">
        <path d={edge === "e" || edge === "w" ? "M4 8h15l-4-4M20 16H5l4 4" : "M8 20V5L4 9M16 4v15l4-4"} />
      </svg>
    </button>
  );
}

/**
 * A free window's 8 resize zones and 4 grips: only its id, so a frame of its own move or resize (the window re-renders)
 * leaves them, and their arrays' Fragments, alone (render scan 10-31: all 8 Edges, 4 Grips every frame).
 */
/** The top/bottom zones' heights near the system strips ([zoneHeight]), as one string: [Handles] re-renders only
 *  when one of them changes, not on every frame of a drag. */
const zoneKey = (win: WebWin) => EDGES.map((side) => zoneHeight(win, side) ?? "").join("|");

const Handles = memo(function Handles({ id, zones }: { id: number; zones: string }) {
  const heights = zones.split("|");
  return (
    <>
      {EDGES.map((side, i) => <Edge key={side} id={id} side={side} height={heights[i] || undefined} />)}
      {CORNERS.map((c) => <Grip key={c} corner={c} />)}
    </>
  );
});

/** RZ4: the live size outline round a frame being resized, its size (screen px) in it; brighter on a snapped tile size. */
function ResizeOutline({ win, leaving }: { win: WebWin; leaving: boolean }) {
  const k = win.scale ?? 1;
  const v = resizeView.value;
  return (
    <div class={`ww-outline ${v?.snapped ? "snapped" : ""} ${leaving ? "leaving" : ""}`}>
      <span class="ww-outline-size tile">
        {Math.round(win.w * k)} × {Math.round(win.h * k)}
      </span>
    </div>
  );
}

/**
 * WS1: a window's drop shadow, the widgets' lift but deeper (it floats higher), the focused one's stronger: its own
 * element under the frame, so the frame's mask (a higher window's hole) never cuts it; masked itself where the windows
 * above it are (a lower window's shadow never darkens a higher one's app). Outside the frame only: never on its app.
 */
function WindowShadow({ win, z, focused }: { win: WebWin; z: number; focused: boolean }) {
  if (win.restore) return null;
  const b = frameBox(win);
  const style = {
    left: `${b.x - SHADOW_PAD}px`,
    top: `${b.y - SHADOW_PAD}px`,
    width: `${b.w + 2 * SHADOW_PAD}px`,
    height: `${b.h + 2 * SHADOW_PAD}px`,
    zIndex: 20 + z,
    // Its mask (the windows above it): WebWindowsOn's cutAll, after the render.
  };
  return (
    <div class={`ww-shadow ${focused ? "focused" : ""} ${reflowing.value === win.page ? "ww-reflow" : ""}`} data-wwid={win.id} style={style}>
      <div style={{ inset: `${SHADOW_PAD}px` }} />
    </div>
  );
}
/** How far past the frame its shadow's element reaches (its blur and offset fit in it). */
const SHADOW_PAD = 64;

/**
 * The app's place. Live, it paints NOTHING: the page is transparent over it and the app's layer (under home's buffer)
 * shows there. Until its first frame it is a solid placeholder (the app's icon and a quiet progress line on the theme's
 * surface: the manager's LW1), never a hole. A press on it (the DOM's hit test: anything above it in the DOM wins) goes
 * to the app - the window raised, so it is in front and focused, the same for Android and Linux apps.
 */
function Body({ win, body }: { win: WebWin; body: { current: HTMLDivElement | null } }) {
  // PZ1: its fingers down now (pointer id -> finger 0, 1, ...: the lowest free), each sent to the app as that finger.
  const pressed = useRef(new Map<number, number>());
  const toApp = (e: PointerEvent, action: "down" | "move" | "up" | "cancel", finger = 0) => {
    e.stopPropagation();
    const el = body.current;
    const r = el?.getBoundingClientRect();
    // The body's on-screen scale as measured (its own scale times every ancestor's: the page's zoom, a swipe), the same
    // as entry()'s: dividing by win.scale alone put presses in the wrong place at a page zoom (x0.53).
    const s = el && el.offsetWidth ? r!.width / el.offsetWidth : (win.scale ?? 1);
    if (r && win.id >= 0) void powos.webwindows?.input(win.id, action, { x: (e.clientX - r.left) / s, y: (e.clientY - r.top) / s, finger });
  };
  const down = (e: PointerEvent) => {
    const p = pressed.current;
    // TB1: a press at an auto-hidden bar's edge may be a pull that slides it in (the app gets the touch too, as Android's).
    if (barAutoHidden(win) && body.current) edgeDown(win.id, e, body.current.getBoundingClientRect().top, rootTokens().inset);
    // A new touch: fingers whose up this body never saw end first (the app's gesture never keeps a stale finger).
    if (e.isPrimary && p.size) (p.clear(), toApp(e, "cancel"));
    if (!p.size) raise(win.id);
    try {
      body.current?.setPointerCapture(e.pointerId);
    } catch {}
    let n = 0;
    while ([...p.values()].includes(n)) n++;
    p.set(e.pointerId, n);
    toApp(e, "down", n);
    if (n === 0)
      oneFinger.set(win.id, () => {
        if (!p.size) return;
        p.clear();
        toApp(e, "cancel");
      });
  };
  bodyFinger.set(win.id, down);
  const end = (e: PointerEvent, action: "up" | "cancel") => {
    edgeEnd(e.pointerId);
    const n = pressed.current.get(e.pointerId);
    if (n === undefined) return;
    pressed.current.delete(e.pointerId);
    // A cancel ends the app's whole gesture (the host's ACTION_CANCEL is every finger's).
    if (action === "cancel") pressed.current.clear();
    if (n === 0 && appDragEnd(win.id, e, action === "cancel")) return;
    toApp(e, action, n);
  };
  const icon = iconOf(win.key);
  return (
    <div
      class={`webwindow-body ${win.live ? "live" : "placeholder"}`}
      ref={body}
      style={{ flex: 1, touchAction: "none", ...previewOf(win.id) }}
      onPointerDown={down}
      onPointerMove={(e) => {
        edgeMove(e.pointerId, e.clientY);
        const n = pressed.current.get(e.pointerId);
        if (n !== undefined && !(n === 0 && appDragMove(win.id, e))) toApp(e, "move", n);
      }}
      onPointerUp={(e) => end(e, "up")}
      onPointerCancel={(e) => end(e, "cancel")}
    >
      {!win.live && <Placeholder win={win} icon={icon} />}
    </div>
  );
}

/** Until its first frame: its icon and a progress line; one that couldn't start (LW3) says so, with a close. */
function Placeholder({ win, icon }: { win: WebWin; icon: string | undefined }) {
  return (
    <div class={`ww-placeholder ${win.failed ? "failed" : ""}`}>
      {icon && <img class="ww-placeholder-icon" src={icon} alt="" draggable={false} />}
      {!win.failed && <div class="ww-progress" />}
      {!win.failed && win.phase && <div class="ww-phase">{win.phase}</div>}
      {win.failed && <div class="ww-failed-text">Couldn't start {win.label}. {win.failed}</div>}
      {win.failed && (
        <button class="ww-failed-close" onPointerDown={(e) => e.stopPropagation()} onClick={(e) => (e.stopPropagation(), close(win.id))}>
          Close
        </button>
      )}
    </div>
  );
}

/**
 * The app's own frame drag ([appDrags]) with this body's pointer: true = the move was the frame's (the host stopped
 * sending the touch to the app). Its first move is the start; a move as the bar's drag (untiles, clamped), a resize as
 * an edge grab. Held still for [HOLD_MS] from its start: the tile menu instead (PowOS's frame features without a bar).
 */
function appDragMove(id: number, e: PointerEvent): boolean {
  const d = appDrags.get(id);
  if (!d) return false;
  e.stopPropagation();
  const w = webWins.value.find((v) => v.id === id);
  if (!w) return true;
  if (!d.start) {
    d.start = { px: e.clientX, py: e.clientY, x: w.x, y: w.y, w: w.w, h: w.h };
    d.hold = window.setTimeout(() => {
      if (appDrags.get(id) !== d || d.moved) return;
      appDrags.delete(id);
      tileMenu.value = id;
    }, HOLD_MS);
    return true;
  }
  const dx = e.clientX - d.start.px;
  const dy = e.clientY - d.start.py;
  if (!d.moved && Math.hypot(dx, dy) < SLOP) return true;
  if (!d.moved) appDragBegins(id, d.edges);
  d.moved = true;
  if (d.edges === "move") update(id, { ...clampPlace(d.start.x + dx, d.start.y + dy, w.w), restore: undefined });
  else resizeBy(id, { ...d.start, side: d.edges, k: w.scale ?? 1 }, e);
  return true;
}

/** An app's own frame drag's first move: a tiled window untiled; a resize's app size paced from now (RS1). */
function appDragBegins(id: number, edges: string) {
  if (tiledOn(id) != null) untile(id, "keep");
  if (edges !== "move") resizeStart(id);
}

/** The press ended: an app's own frame drag ends with it (let go at an edge: tiled, as the bar's). True: it was one. */
function appDragEnd(id: number, e: PointerEvent, cancelled: boolean): boolean {
  const d = appDrags.get(id);
  if (!d) return false;
  appDrags.delete(id);
  clearTimeout(d.hold);
  e.stopPropagation();
  if (d.edges !== "move") (resizeEnd(id), (resizeView.value = null));
  if (!cancelled && d.moved && d.edges === "move") {
    const slot = snapSlot(e.clientX, e.clientY);
    if (slot) tile(id, slot);
  }
  return true;
}

/**
 * The window: an element of its page (it slides with it, sits in z by DOM order). Its frame, bar and edges paint
 * here; over its body the page is transparent (the app's layer). A lower window is masked where a higher window is
 * (the app's pixels are under home's buffer, so DOM there would paint over that app, or show through its bar's glass).
 */
// RS5: memo - a window whose props (its WebWin, z, the windows above) didn't change skips another window's resize or
// move frame (render scan 11-08: all four windows' AppWindowEl and SwapHint rendered on each move of one); its signals
// (resizeView, tileMenu, grips, tilings ...) still re-render it on their own.
const WebWindowEl = memo(function WebWindowEl({ win, z, focused }: { win: WebWin; z: number; focused: boolean }) {
  if (win.quick) return <QuickEl win={win} z={z} />;
  return <AppWindowEl win={win} z={z} focused={focused} />;
});

function AppWindowEl({ win, z, focused }: { win: WebWin; z: number; focused: boolean }) {
  const body = useRef<HTMLDivElement>(null);
  const pinch = usePinch(win);
  // SC1: a pinch's scale zooms the whole frame (bar and body); the app keeps its size (sizeOf sends the layout size).
  const s = win.scale ?? 1;
  const frame = {
    position: "absolute",
    left: `${win.x}px`,
    top: `${win.y}px`,
    width: `${win.w}px`,
    height: `${win.h}px`,
    transform: s === 1 ? undefined : `scale(${s})`,
    transformOrigin: "0 0",
    zIndex: 20 + z,
    display: "flex",
    flexDirection: "column",
    // Its mask (the windows above it): WebWindowsOn's cutAll, after the render.
  } as const;
  const free = !win.restore && tiledOn(win.id) == null;
  const sizing = resizeView.value?.id === win.id;
  // The outline and the tile menu leave on the spring (§6: both were gone in one frame).
  const outline = usePresence(sizing);
  const menu = usePresence(tileMenu.value === win.id);
  const auto = barAutoHidden(win);
  const cls = frameClass(win, focused, sizing, auto);
  return (
    <>
      <WindowShadow win={win} z={z} focused={focused} />
      <div class={cls} data-wwid={win.id} data-z={z} style={{ ...frame, "--ww-k": s }} {...pinch}>
        {(!win.ownFrame || orphaned(win.id)) && <TitleBar win={win} auto={auto} />}
        <Body win={win} body={body} />
        {free && <Handles id={win.id} zones={zoneKey(win)} />}
        <SwapHint win={win} />
        {outline.on && <ResizeOutline win={win} leaving={outline.leaving} />}
        {menu.on && <TileMenu win={win} leaving={menu.leaving} />}
      </div>
    </>
  );
}

/** TS1: a tiled window's body during its zoom pinch: scaled about its top left (the host draws its layer so). */
function previewOf(id: number) {
  const p = zoomPreview.value;
  return p?.id === id && p.k !== 1 ? { transform: `scale(${p.k})`, transformOrigin: "0 0" } : {};
}

/**
 * The frame element's classes: maximised, live, focused (the top window: its grips, RZ1), being resized; TB1 [auto]:
 * its bar auto-hides, and is slid in now.
 */
function frameClass(win: WebWin, focused: boolean, sizing: boolean, auto: boolean): string {
  const shown = auto && barReveal.value === win.id;
  const on: [boolean, string][] = [[!!win.restore, "maximised"], [!!win.live, "live"], [focused, "focused"], [sizing, "ww-resizing"], [gripsOn.value === win.id, "ww-grips"], [reflowing.value === win.page, "ww-reflow"], [zoomPreview.value?.id === win.id, "ww-zooming"], [auto, "ww-bar-auto"], [shown, "ww-bar-shown"]];
  return ["webwindow", ...on.filter(([b]) => b).map(([, c]) => c)].join(" ");
}

/** A window's whole frame (bar and body) in its page's px (the model; scaled about its top left). */
export function frameBox(w: WebWin): Box {
  const s = w.scale ?? 1;
  return { x: w.x, y: w.y, w: w.w * s, h: w.h * s };
}

/**
 * A CSS mask that leaves out [cut] (whole windows: the body is the app's layer, and the bar's glass must show what is
 * UNDER home's surface - the wallpaper, a lower app - blurred, never the page's own widget pixels) from an element at [at] in the page (page px; [at].s: the element's
 * own scale, the mask is in its unscaled box): the whole box minus each body. Undefined: nothing to cut.
 */
export function holes(cut: WebWin[], at: { x: number; y: number; s: number }): Record<string, string> | undefined {
  if (!cut.length) return undefined;
  const full = "linear-gradient(black, black)";
  const boxes = cut.map(frameBox).map((b) => ({ x: (b.x - at.x) / at.s, y: (b.y - at.y) / at.s, w: b.w / at.s, h: b.h / at.s }));
  return {
    maskImage: [full, ...boxes.map(() => full)].join(", "),
    maskSize: ["100% 100%", ...boxes.map((b) => `${px(b.w)}px ${px(b.h)}px`)].join(", "),
    maskPosition: ["0 0", ...boxes.map((b) => `${px(b.x)}px ${px(b.y)}px`)].join(", "),
    maskRepeat: "no-repeat",
    maskComposite: ["subtract", ...boxes.map(() => "add")].join(", "),
  };
}

/** The page's own content (widgets, apps, its glass) masked where its windows are: grid.tsx's .page-under. */
export function underWindows(page: number): Record<string, string> | undefined {
  return holes(
    webWins.value.filter((w) => w.page === page && !w.minimised && !w.full && !hiddenTab(w.id) && holed(w)),
    { x: 0, y: 0, s: 1 },
  );
}

/**
 * For the compositor's glass (nativeglass.ts): the windows (bar and body) on screen (viewport CSS px, l t r b) above a
 * surface in [el] (a window's own bar: the windows above that one; page content: every window on its page; anything
 * outside the pages: none). A surface one of them overlaps is blurred on the host's layer under the windows.
 */
export function bodiesOver(el: Element, seen?: Map<Element, [number, Clip][]>): Clip[] {
  const page = el.closest(".page");
  if (!page) return [];
  const own = el.closest<HTMLElement>(".webwindow[data-wwid]");
  const z = own ? Number(own.dataset.z) : -1;
  // RS5: one measure's surfaces share their page's windows ([seen], per measure): each window's rect read once a
  // measure, not once per surface (11-08, the glass stand-in in ww-resize-cost: 118-182 rect reads a resize move).
  let wins = seen?.get(page);
  if (!wins) {
    wins = [...page.querySelectorAll<HTMLElement>(".webwindow[data-wwid]")].map((w) => {
      const b = w.getBoundingClientRect();
      return [Number(w.dataset.z), [b.left, b.top, b.right, b.bottom]];
    });
    seen?.set(page, wins);
  }
  return wins.filter(([wz]) => wz > z).map(([, c]) => c);
}
// To the glass (nativeglass.ts reads it; an import either way would close a module cycle through apps/native.ts).
(globalThis as { __wwCutouts?: typeof bodiesOver }).__wwCutouts = bodiesOver;

// ---- plan 2.3: the layout record (docs/WEB_WINDOWS.md "The host snapshot") ------------------------------------------
// The page owns layout; the host keeps a copy it never reads, so a reloaded page can rebuild it (2.4, 2.7). One record
// per window the host knows (id >= 0) and one per home page with a tiling or a tab group. Written [LAYOUT_QUIET] ms
// after the last change (a drag or resize writes once, at its end - never per frame), and only what changed.

/** Window [id]'s record: its page, frame, the frame to restore to (maximised), its floating frame before a tile, its
 * scale, minimised, its tile (layout + slot index) and its tab group (ids in tab order + the shown tab). */
export interface WindowLayout {
  v: 1;
  page: number;
  frame: { x: number; y: number; w: number; h: number };
  restore?: { x: number; y: number; w: number; h: number };
  untiled?: { x: number; y: number; w: number; h: number };
  scale?: number;
  minimised?: true;
  tile?: { layout: Layout; slot: number };
  tab?: { ids: number[]; active: number };
}
/** Home page [page]'s record: its tiling and the tab groups of its windows. */
export interface PageLayout {
  v: 1;
  tiling?: Tiling;
  tabs: Stack[];
}

export const LAYOUT_QUIET = { ms: 400 };
const sentWin = new Map<number, string>();
const sentPage = new Map<number, string>();
let layoutTimer: ReturnType<typeof setTimeout> | undefined;

/** Window [w]'s record ([ts]/[ss]: the tilings and tab groups now). */
function windowLayout(w: WebWin, ts: Record<number, Tiling>, ss: Stack[]): WindowLayout {
  const r: WindowLayout = { v: 1, page: w.page, frame: { x: w.x, y: w.y, w: w.w, h: w.h } };
  if (w.restore) r.restore = w.restore;
  if (w.untiled) r.untiled = w.untiled;
  if ((w.scale ?? 1) !== 1) r.scale = w.scale;
  if (w.minimised) r.minimised = true;
  return { ...r, ...tileTab(w, ts, ss) };
}

/** Window [w]'s tile (its page's layout + slot index) and tab group, where it has them. */
function tileTab(w: WebWin, ts: Record<number, Tiling>, ss: Stack[]): Pick<WindowLayout, "tile" | "tab"> {
  const t = ts[w.page];
  const slot = t?.ids.indexOf(w.id) ?? -1;
  const s = ss.find((x) => x.ids.includes(w.id));
  return { ...(t && slot >= 0 ? { tile: { layout: t.layout, slot } } : {}), ...(s ? { tab: { ids: s.ids, active: s.active } } : {}) };
}

/** Each page with a tiling or a tab group (a group is on its shown tab's page): page -> JSON. */
function pageLayouts(ts: Record<number, Tiling>, ss: Stack[]): Map<number, string> {
  const pageOf = new Map(webWins.peek().map((w) => [w.id, w.page]));
  const tabsOn = new Map<number, Stack[]>();
  for (const s of ss) {
    const p = pageOf.get(s.active);
    if (p != null) tabsOn.set(p, [...(tabsOn.get(p) ?? []), s]);
  }
  const pages = new Map<number, string>();
  for (const p of new Set([...Object.keys(ts).map(Number), ...tabsOn.keys()])) {
    pages.set(p, JSON.stringify({ v: 1, tiling: ts[p], tabs: tabsOn.get(p) ?? [] } satisfies PageLayout));
  }
  return pages;
}

/** The records as they stand now: window id -> JSON (windows the host knows), page -> JSON. */
export function layoutRecords(): { windows: Map<number, string>; pages: Map<number, string> } {
  const ts = tilings.peek();
  const ss = stacks.peek();
  const known = webWins.peek().filter((w) => w.id >= 0 && !w.pending);
  const windows = new Map(known.map((w) => [w.id, JSON.stringify(windowLayout(w, ts, ss))]));
  return { windows, pages: pageLayouts(ts, ss) };
}

/** [now]'s records that differ from [sent] go to [write] (and into [sent]); [gone] gets each one no longer there. */
function sendChanged(now: Map<number, string>, sent: Map<number, string>, write: (k: number, r: string) => void, gone: (k: number) => void) {
  for (const [k, r] of now) {
    if (sent.get(k) === r) continue;
    sent.set(k, r);
    write(k, r);
  }
  for (const k of [...sent.keys()].filter((k) => !now.has(k))) {
    sent.delete(k);
    gone(k);
  }
}

/** Sends the host every record that changed since the last write, and null for a page's that's gone. */
export function flushLayout() {
  layoutTimer = undefined;
  const ww = powos.webwindows;
  if (!ww?.layout) return;
  const { windows, pages } = layoutRecords();
  const quiet = (p: Promise<boolean> | undefined) => void p?.catch(() => {});
  // A window gone: the host drops its record with it - only forgotten here.
  sendChanged(windows, sentWin, (id, r) => quiet(ww.layout?.(id, r)), () => {});
  sendChanged(pages, sentPage, (p, r) => quiet(ww.pageLayout?.(p, r)), (p) => quiet(ww.pageLayout?.(p, null)));
}

// Subscribes only: the records are built once the changes stop (a drag's frames each just push the timer on).
effect(() => {
  void webWins.value;
  void tilings.value;
  void stacks.value;
  if (layoutTimer !== undefined) clearTimeout(layoutTimer);
  layoutTimer = setTimeout(flushLayout, LAYOUT_QUIET.ms);
});
