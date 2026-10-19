/**
 * The shell's state, as signals: what changes re-renders only what reads it. Loaded from the host at start and kept
 * current by its events; the user's own (dock pins) goes back through powos.store.
 */
import { computed, signal } from "@preact/signals";
import { powos } from "./bridge.ts";
import type { App, Chat, Home, HomeItem, WidgetScreen } from "./types.ts";

export const apps = signal<App[]>([]);
export const byKey = computed(() => new Map(apps.value.map((a) => [a.key, a])));
/** How many recent apps the strip has (six to a width, scrolling sideways); pinned ones are left out (the dock has them). */
const RECENT_FETCH = 24;
export const recent = signal<string[]>([]);
/** Apps pinned to the drawer's dock, in pin order. */
export const dock = signal<string[]>([]);
/** A pinned app being moved along the dock: which, where the finger is, and the slot it would drop into. */
export const dockDrag = signal<{ key: string; x: number; slot: number } | null>(
  null,
);

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

/** The drawer: open or not (a finger dragging it is gesture.ts's drawerDrag). */
export const drawer = signal(0);
export const query = signal("");

/** PowOS AI's chat, as the host streams it. */
export const chat = signal<Chat>({ busy: false, items: [] });
/** Asked something since the drawer opened: the chat stays up (until the search finds apps again). */
export const chatting = signal(false);

export async function load() {
  const [list, keys, pins, h, c, scr] = await Promise.all([
    powos.apps.list(),
    powos.usage.recent(RECENT_FETCH),
    powos.store.get<string[]>("dock"),
    powos.home.get(),
    powos.ai.chat(),
    powos.widgets.screen(),
  ]);
  screen.value = scr;
  chat.value = c;
  home.value = h;
  apps.value = list;
  recent.value = keys;
  dock.value = Array.isArray(pins) ? pins : [];
}

// The host's list arrives after the page (it loads apps and icons in the background): the recent strip, filtered to
// installed apps, follows it. Back on screen, the strip shows what was opened meanwhile.
powos.on("apps.changed", async () => {
  apps.value = await powos.apps.list();
  recent.value = await powos.usage.recent(RECENT_FETCH);
});
powos.on("ai.changed", (c: Chat) => (chat.value = c));
powos.on("home.changed", async () => (home.value = await powos.home.get()));
document.addEventListener("visibilitychange", async () => {
  if (!document.hidden) recent.value = await powos.usage.recent(RECENT_FETCH);
});

/** Closes the drawer: the search cleared, the keyboard down. */
export function closeDrawer() {
  drawer.value = 0;
  query.value = "";
  chatting.value = false;
  (document.activeElement as HTMLElement | null)?.blur();
  powos.keyboard.hide();
}

/** Back: whatever is on top closes first - a widget's screen, a menu, a folder, a tile's edit, edit mode, the drawer. False when nothing was open. */
export function back(): boolean {
  if (screen.value.key) powos.widgets.closeScreen();
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

/** Home, pressed on home: everything closes, and the first page shows - as a stock launcher does. */
export function goHome() {
  if (screen.value.key) powos.widgets.closeScreen();
  notif.value = false;
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

export async function launch(key: string) {
  menu.value = null;
  await powos.apps.launch(key);
  closeDrawer();
  recent.value = await powos.usage.recent(RECENT_FETCH);
}

/** Asks PowOS AI: the field clears for the next question, the chat shows the turn streaming in. */
export function ask(text: string) {
  const t = text.trim();
  if (!t) return;
  chatting.value = true;
  query.value = "";
  powos.ai.send(t);
}

export function setDocked(key: string, on: boolean) {
  setDock(
    on
      ? [...dock.value.filter((k) => k !== key), key]
      : dock.value.filter((k) => k !== key),
  );
}

/** The dock's apps, in this order. */
export function setDock(keys: string[]) {
  dock.value = keys;
  powos.store.set("dock", keys);
}
