/**
 * An app carried out of the dock (the taskbar) and let go off it opens it beside what's on screen (the user, 2026-10-31
 * 03:00: "I should be able to tap and hold an app and drag it out of the taskbar to open it in split view or in a
 * floating window", after OxygenOS's taskbar). While it's held off the dock a translucent ghost shows where it goes:
 *
 * - a half of the screen (left / right; top / bottom on a screen taller than wide): split screen, the app on that half
 *   and the app in front on the other (powos.tasks.split, task ids; the app launched first when it has no task yet).
 *   No app in front: it opens full screen.
 * - the middle third: a window - unfolded a PowOS web window (openWebWindow), folded Android's floating window
 *   (powos.tasks.float).
 *
 * Let go back over the dock it's the dock's again (dockdrop.ts dropOnDock: reorder, or back where it was). On home with
 * no app in front ([overApps]) none of this after a hold: let go on home's grid it's unpinned and placed there, as before.
 * Lifted out with no hold (Carry.lifted: a move away from the dock, gesture.ts chromeWay "out") it's a window's drag
 * everywhere, home too.
 */
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import { byKey, launch, page, pages, pullPage, type Carry } from "../state.ts";
import { PREFIX } from "../apps/pages.ts";
import { wideHome } from "../hosts/wide.ts";
import { aimDock, carriedApp } from "./dockdrop.ts";
import { openWebWindow, webWins } from "./webwindows.tsx";
import type { RecentTask } from "../types.ts";

export type OutZone = "first" | "second" | "window";
interface OutAim { key: string; zone: OutZone; rect: { x: number; y: number; w: number; h: number } }

/** The drop a carried dock app would make where it is now ([DockOutGhost] draws it); null over the dock or not one. */
export const outAim = signal<OutAim | null>(null);

/** How long a launched app may take to show up as a task before the split gives up on it. */
export const TASK_WAIT = { ms: 6000 };

/** Where [c], held at [x], [y], would go off the dock: a half or the middle of the screen, or null. */
export function aimOut(c: Carry, x: number, y: number): OutAim | null {
  const key = carriedApp(c);
  if (!c.fromDock || !key || !(c.lifted || overApps()) || aimDock(c, x, y)) return null;
  const w = window.innerWidth, h = window.innerHeight;
  const at = w >= h ? x / w : y / h;
  const zone: OutZone = at < 1 / 3 ? "first" : at > 2 / 3 ? "second" : "window";
  return { key, zone, rect: zoneRect(zone, w, h) };
}

/**
 * The dock is a taskbar over apps: the pull-up overlay over an app, or unfolded home with a window open on this page.
 * Else (home's grid under the finger) a dock app let go off the dock is unpinned onto home, as always (grid.tsx letGo).
 */
export function overApps() {
  if (pullPage) return true;
  const here = pages.value[page.value];
  return wideHome.value && webWins.value.some((w) => w.page === here && !w.minimised);
}

/** The screen ([w] x [h]) [zone] takes: its half (left / right across, top / bottom on a tall screen) or a window's. */
function zoneRect(zone: OutZone, w: number, h: number) {
  if (zone === "window") return { x: w * 0.2, y: h * 0.2, w: w * 0.6, h: h * 0.6 };
  const second = zone === "second";
  return w >= h ? { x: second ? w / 2 : 0, y: 0, w: w / 2, h } : { x: 0, y: second ? h / 2 : 0, w, h: h / 2 };
}

/** Follows the finger off the dock: the ghost moves between the halves and the middle, a tick for each new one. */
export function hoverOut(c: Carry, x: number, y: number) {
  const a = aimOut(c, x, y);
  if (a?.zone !== outAim.value?.zone) {
    if (a) navigator.vibrate?.(5);
    outAim.value = a;
  }
}

/** [c] let go at [x], [y]: true when it was a dock app let go off the dock (it opens there - split or window). */
export function dropOut(c: Carry, x: number, y: number): boolean {
  const a = aimOut(c, x, y);
  outAim.value = null;
  if (!a) return false;
  navigator.vibrate?.(10);
  // A PowOS app is a page of home's own (no task to split or float): it opens as a tap opens it.
  if (a.key.startsWith(PREFIX)) void launch(a.key);
  else void (a.zone === "window" ? openWindowed(a.key) : openSplit(a.key, a.zone));
  return true;
}

/** A real app's task (Android's split and floating windows take those): not PowOS home's own, not a PowOS app's page. */
const realTask = (t: RecentTask) => t.id >= 0 && !!t.key && !t.key.startsWith("com.powos.app");

/** The app in front: over an app (the pull-up overlay, pull.tsx) the top task; on home, none. */
async function frontTask(other: string): Promise<RecentTask | null> {
  if (!pullPage) return null;
  const tasks = await powos.tasks.list().catch(() => []);
  const top = tasks.find(realTask);
  return top && top.key !== other ? top : null;
}

/** [key]'s task: its own if it has one, else it's launched and its task waited for (null: none came in time). */
async function taskOf(key: string): Promise<number | null> {
  const find = async () => (await powos.tasks.list().catch(() => [])).find((t) => realTask(t) && t.key === key)?.id;
  const had = await find();
  if (had != null) return had;
  await powos.apps.launch(key);
  for (const until = Date.now() + TASK_WAIT.ms; Date.now() < until; ) {
    await new Promise((ok) => setTimeout(ok, 150));
    const id = await find();
    if (id != null) return id;
  }
  return null;
}

/** [key] on the [zone] half, the app in front on the other; none in front (or no task for it): full screen. */
async function openSplit(key: string, zone: "first" | "second") {
  const front = await frontTask(key);
  if (!front) return powos.apps.launch(key);
  const id = await taskOf(key);
  if (id == null) return console.info(`[dockout] ${key} showed no task in ${TASK_WAIT.ms} ms: no split`);
  await (zone === "first" ? powos.tasks.split(id, front.id) : powos.tasks.split(front.id, id));
}

/** [key] as a window: unfolded a web window on this page (where they're on), else Android's floating window. */
async function openWindowed(key: string) {
  const label = byKey.value.get(key)?.label ?? key;
  if (wideHome.value && (await openWebWindow(key, label, pages.value[page.value] ?? 1))) return;
  const id = await taskOf(key);
  if (id != null) await powos.tasks.float(id);
}

/** The ghost of where the carried dock app goes ([outAim]): the tiles' drop look (webwindows.tsx DropPreview). */
export function DockOutGhost() {
  const a = outAim.value;
  if (!a) return null;
  const r = a.rect;
  const style = { position: "fixed", left: `${r.x}px`, top: `${r.y}px`, width: `${r.w}px`, height: `${r.h}px`, zIndex: 999 };
  return (
    <div class={`ww-drop dock-out ${a.zone}`} data-zone={a.zone} style={style}>
      <span class="ww-drop-label">{a.zone === "window" ? "Window" : "Split screen"}</span>
    </div>
  );
}
