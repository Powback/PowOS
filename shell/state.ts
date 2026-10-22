/**
 * The shell's state, as signals: what changes re-renders only what reads it. Loaded from the host at start and kept
 * current by its events; the user's own (dock pins) goes back through powos.store.
 */
import { computed, effect, signal, type Signal } from "@preact/signals";
import { powos } from "./bridge.ts";
import { closeRemote, remoteOpen } from "./remote.ts";
import { closeGlasses, glassesOpen } from "./glasses/open.ts";
import { agentsView, closeAgents } from "./agents.ts";
import { backScreen, closeScreens } from "./screens.ts";
import { recentsBack, recentsHome } from "./ui/recents.tsx";
import { appView, closeApp, initPowosApps, mergeRecent, noteHostRecent, openApp, powosApps, PREFIX } from "./apps/pages.ts";
import type { App, AppWindow, Chat, Home, HomeItem, WidgetScreen } from "./types.ts";

/** The host's apps (Android's, Linux's); with the installed PowOS apps that have a page (apps/pages.ts), [apps]. */
const hostApps = signal<App[]>([]);
export const apps = computed(() => [...hostApps.value, ...powosApps.value]);
export const byKey = computed(() => new Map(apps.value.map((a) => [a.key, a])));
/** How many recent apps the strip has (six to a width, scrolling sideways); pinned ones are left out (the dock has them). */
const RECENT_FETCH = 24;
const hostRecent = signal<string[]>([]);
/** The recent apps, newest first: the host's, with the PowOS apps opened in the shell. */
export const recent = computed(() => mergeRecent(hostRecent.value, new Set(powosApps.value.map((a) => a.key))));
async function fetchRecent() {
  const keys = await powos.usage.recent(RECENT_FETCH);
  noteHostRecent(keys);
  hostRecent.value = keys;
}
/** Apps pinned to the drawer's dock, in pin order. */
export const dock = signal<string[]>([]);
/** A pinned app being moved along the dock: which, where the finger is, and the slot it would drop into. */
export const dockDrag = signal<{ key: string; x: number; slot: number } | null>(null);
/**
 * An app carried over the dock (ui/dockdrop.ts): the slot it would drop into - the others make room there - or, the
 * dock full, the pinned app it would swap out.
 */
export const dockAim = signal<{ key: string; slot: number; swap: boolean } | null>(null);

/** The home screen: pages of widgets, pinned apps and folders on a grid. */
export const home = signal<Home>({ columns: 6, pages: [1], items: [] });
/** The page on screen, an index into pages (the last, empty one included); -1 is PowOS AI's, left of the first. */
export const page = signal(0);

/** The selected tile (edit mode): it shows resize handles and its actions. */
export const selected = signal<string | null>(null);

/**
 * Something carried by a finger: an item being moved, or an app dragged out of the drawer. x/y is the finger in the
 * grid's coordinates; grab is where on the tile it holds it.
 */
export interface Carry {
  item?: HomeItem;
  app?: string;
  /** Taken up out of the dock: let go anywhere off it, it's unpinned. */
  fromDock?: boolean;
  x: number;
  y: number;
  grab: { x: number; y: number };
}
export const carry = signal<Carry | null>(null);
/**
 * Edit mode (a long press on home's empty space): tiles move with a long press, the home menu's sheet is up, and
 * there's an empty page after the last to fill - swiping to an empty page needs it.
 */
export const editing = signal(false);
/** Pages to show: the ones with items; editing or carrying a tile, an empty one after them. */
export const pages = computed(() => {
  const used = home.value.pages.length ? home.value.pages : [1];
  return carry.value || editing.value ? [...used, Math.max(...used) + 1] : used;
});
/** A widget's screen open over home (its onTap's screen()); Back closes it first. */
export const screen = signal<WidgetScreen>({ key: null });
powos.on("widget.screen", (s: WidgetScreen) => (screen.value = s));
/** The notification panel (notifications.tsx): down or not (a finger dragging it is gesture.ts's notifDrag). */
export const notif = signal(false);
/** What the pulled-down panel shows: the notifications or the control center (the status bar's right half's pull). */
export const panel = signal<"notifications" | "control">("notifications");
/** The open folder's key. */
export const folder = signal<string | null>(null);
/** An app's long-press menu: which app, and where (the pressed cell's box on screen). */
export const menu = signal<{ app: App; at: DOMRect } | null>(null);

/**
 * An "at work" tmux session open over home (session.tsx): which, the card it grew from (it shrinks back into it), and
 * whether it's on its way out. Back closes it first.
 */
export const sessionView = signal<{
  name: string;
  task?: string;
  from: DOMRect | null;
  card: HTMLElement | null;
  closing?: boolean;
} | null>(null);

/** Opens [name] (a tmux session's, as PowOS lists them) from [card]. */
export function openSession(name: string, card: HTMLElement | null, task?: string) {
  if (!/^[A-Za-z0-9_.:-]+$/.test(name)) return;
  sessionView.value = { name, task, card, from: card?.getBoundingClientRect() ?? null };
}

export function closeSession() {
  const s = sessionView.value;
  if (s && !s.closing) sessionView.value = { ...s, closing: true };
  (document.activeElement as HTMLElement | null)?.blur();
  powos.keyboard.hide();
}

/**
 * A signal kept in the page's storage: what's typed survives the page reloading - an update, a hot reload, the app
 * restarted. (localStorage lives in the app's data, which an update keeps.) Unreadable storage: it just isn't kept.
 */
export function stored(key: string, initial = ""): Signal<string> {
  let first = initial;
  try {
    first = localStorage.getItem(`powos.${key}`) ?? initial;
  } catch {}
  const s = signal(first);
  effect(() => {
    const v = s.value;
    try {
      if (v) localStorage.setItem(`powos.${key}`, v);
      else localStorage.removeItem(`powos.${key}`);
    } catch {}
  });
  return s;
}

/** The drawer: open or not (a finger dragging it is gesture.ts's drawerDrag). */
export const drawer = signal(0);
/**
 * What the pull-up panel (the drawer's frame) holds: the apps, or PowOS AI's (its history, the board - powai.tsx
 * AiContent). Set by what opens it; it stays while it closes, so nothing swaps under a closing panel.
 */
export const pullKind = signal<"apps" | "ai">("apps");
/**
 * The pull-up corners, an experiment beside everything else (docs/DESIGN-LANGUAGE.md): on, a swipe up from home's
 * left half brings up PowOS AI's panel, from the right half the drawer; off ("off"), up anywhere is the drawer, as
 * before. PowOS AI's page to the left of home stays either way.
 */
export const pullPanels = stored("pullPanels", "on");
/**
 * The same corners over any app (ui/pull.tsx in the edge gestures' overlay window): read by the host from the shell's
 * store (files/shell-data/pullOverApps.json), so it's written there too. Off: no corner is claimed over apps.
 */
export const pullOverApps = stored("pullOverApps", "on");
/**
 * Settings -> style -> home: "on" keeps the notifications and the control center apart (two panels, a sideways swipe
 * between them, the status bar's right half pulls the control center); off, the default, they're one panel - the
 * controls on top, the notifications under them - and a pull anywhere along the top brings it.
 */
export const separatePanels = stored("separatePanels", "off");
/**
 * The control center's layout (control.tsx): "v3" - one row of the most-used toggles, every control in one labelled
 * grid on a further pull (the default, approved 2026-10-22) - or "classic", the eight category tiles before it
 * (settings -> style -> home).
 */
// Its own key: the experiment's "ccV3" was written "off" into every page's storage while it was off by default.
export const ccV3 = stored("ccLayout", "v3");
// The plain value: store.set writes a string as a JSON string ("on" / "off"), what CornerPull.kt reads.
effect(() => void powos.store.set("pullOverApps", pullOverApps.value).catch(() => {}));
/**
 * Which engine dictates (settings -> voice): "gpu" - Whisper on the GPU server (stt.pow), on-device when it can't be
 * reached - or "ondevice" (Android's own). Read by the app from the shell's store (files/shell-data/speech.json,
 * GpuSpeech.kt SpeechEngines), so it's written there too.
 */
export const speechEngine = stored("speechEngine", "gpu");
// The object itself: a string is stored quoted (ShellBridge store.set), and the app reads {"engine": ...}.
effect(() => void powos.store.set("speech", { engine: speechEngine.value }).catch(() => {}));
/** Opens the pull-up panel with [kind] in it (the pet's long press, a bubble's "more": "ai"). */
export function openPanel(kind: "apps" | "ai") {
  pullKind.value = kind;
  drawer.value = 1;
}
export const query = signal("");

/** PowOS AI's chat, as the host streams it. */
export const chat = signal<Chat>({ busy: false, items: [] });
/** Asked something since the drawer opened: the chat stays up (until the search finds apps again). */
export const chatting = signal(false);

/**
 * The apps as last listed, for a page that loads before the host has its list (after an update or a restart it lists
 * Android's apps in a moment, PowOS's once the session answers): home's pinned apps keep their icons (files the host
 * still has, ShellIcons) instead of turning into initials meanwhile. A kind (android, linux) the host has none of yet
 * comes from here - only early on, so apps that really are gone (Linux removed) go once the host has settled.
 */
const APPS_KEPT = "powos.apps";
const KEPT_FOR_MS = 20000;
function withKept(list: App[]): App[] {
  let kept: App[] = [];
  try {
    if (performance.now() < KEPT_FOR_MS) kept = JSON.parse(localStorage.getItem(APPS_KEPT) ?? "[]");
  } catch {}
  const kinds = new Set(list.map((a) => a.kind));
  const missing = kept.filter((a) => !kinds.has(a.kind));
  try {
    if (!missing.length) localStorage.setItem(APPS_KEPT, JSON.stringify(list));
  } catch {}
  return missing.length ? [...list, ...missing] : list;
}

export async function load() {
  const [list, keys, , pins, h, c, scr] = await Promise.all([
    powos.apps.list(),
    powos.usage.recent(RECENT_FETCH),
    initPowosApps(),
    powos.store.get<string[]>("dock"),
    powos.home.get(),
    powos.ai.chat(),
    powos.widgets.screen(),
  ]);
  screen.value = scr;
  chat.value = c;
  home.value = h;
  hostApps.value = withKept(list);
  noteHostRecent(keys);
  hostRecent.value = keys;
  dock.value = Array.isArray(pins) ? pins : [];
}

// The host's list arrives after the page (it loads apps and icons in the background): the recent strip, filtered to
// installed apps, follows it. Back on screen, the strip shows what was opened meanwhile.
powos.on("apps.changed", async () => {
  hostApps.value = withKept(await powos.apps.list());
  await fetchRecent();
});
/** The floating app windows (unfolded home), top-most first: the dock marks and keeps them (ui/home.tsx). */
export const windows = signal<AppWindow[]>([]);
// Only where the host has them: the desktop's "windows.changed" carries its taskbar's DesktopWindow[].
if (powos.floating) powos.on("windows.changed", (w: AppWindow[]) => (windows.value = w));
void powos.floating?.list().then(
  (w) => (windows.value = w),
  () => undefined,
);
powos.on("ai.changed", (c: Chat) => (chat.value = c));
powos.on("home.changed", async () => (home.value = await powos.home.get()));
document.addEventListener("visibilitychange", async () => {
  if (!document.hidden) await fetchRecent();
});

/** Closes the pull-up panel (the drawer or PowOS AI's). */
export const closePanel = () => closeDrawer();

/** Closes the drawer: the search cleared, the keyboard down. */
export function closeDrawer() {
  drawer.value = 0;
  query.value = "";
  chatting.value = false;
  (document.activeElement as HTMLElement | null)?.blur();
  powos.keyboard.hide();
}

/** Open over everything (a presentation full screen: ui/rich.tsx): Back closes it before anything else. */
export const topBack = signal<(() => void) | null>(null);

/** Back: whatever is on top closes first - a widget's screen, a menu, a folder, a tile's edit, edit mode, the drawer. False when nothing was open. */
export function back(): boolean {
  if (topBack.value) {
    topBack.value();
    return true;
  }
  // The switcher up: Back goes back to the app it was opened over (or closes it, over home).
  if (recentsBack()) return true;
  // A session open, or still shrinking back into its card: Back is its (a second Back meanwhile - the keyboard's and
  // the terminal's - mustn't go on to leave PowOS AI's page).
  if (sessionView.value) closeSession();
  // A PowOS app open full screen: back to where it was opened from.
  else if (appView.value) closeApp();
  else if (remoteOpen.value) closeRemote();
  else if (glassesOpen.value) closeGlasses();
  // Settings and its screens: the top one (or what's open inside it).
  else if (backScreen()) return true;
  else if (agentsView.value) closeAgents();
  else if (screen.value.key) powos.widgets.closeScreen();
  else if (notif.value) notif.value = false;
  else if (menu.value) menu.value = null;
  else if (folder.value) folder.value = null;
  else if (selected.value) selected.value = null;
  else if (editing.value) editing.value = false;
  // PowOS AI's page: back to home.
  else if (page.value === -1) page.value = 0;
  else if (drawer.value > 0) closeDrawer();
  else return false;
  return true;
}

/** Home, pressed on home: everything closes, and the first page shows - as a stock launcher does (a full-screen terminal only closes). */
export function goHome() {
  recentsHome();
  // A terminal open full screen (an at work session, a widget's screen): Home puts it away and stays where it was
  // opened from - PowOS AI's page, the widget's page - as swiping up out of an app goes back to the screen it came from.
  if (sessionView.value || screen.value.key || appView.value) {
    if (appView.value) closeApp();
    if (sessionView.value) closeSession();
    if (screen.value.key) powos.widgets.closeScreen();
    return;
  }
  notif.value = false;
  closeRemote();
  closeScreens();
  closeAgents();
  menu.value = null;
  folder.value = null;
  selected.value = null;
  carry.value = null;
  editing.value = false;
  closeDrawer();
  page.value = 0;
}

powos.on("system.back", () => back());
powos.on("system.home", () => goHome());
// An edge gesture's "app drawer" (EdgeGestures.kt): home with its pull-up panel up.
powos.on("home.panel", ({ kind }: { kind: "apps" | "ai" }) => openPanel(kind === "ai" ? "ai" : "apps"));

export async function launch(key: string) {
  menu.value = null;
  // A PowOS app: its page, full screen in this one (ui/appscreen.tsx).
  if (key.startsWith(PREFIX)) {
    openApp(key.slice(PREFIX.length));
    closeDrawer();
    return;
  }
  await powos.apps.launch(key);
  closeDrawer();
  await fetchRecent();
}

/** Asks PowOS AI: the field clears for the next question, the chat shows the turn streaming in. */
export function ask(text: string) {
  const t = text.trim();
  if (!t) return;
  chatting.value = true;
  query.value = "";
  // false: not into the app switcher - doing that briefly started the chat activity over home (a ~1 s black screen).
  powos.ai.send(t, false);
}

export function setDocked(key: string, on: boolean) {
  setDock(on ? [...dock.value.filter((k) => k !== key), key] : dock.value.filter((k) => k !== key));
}

/** The dock's apps, in this order. */
export function setDock(keys: string[]) {
  dock.value = keys;
  powos.store.set("dock", keys);
}
