/**
 * PowOS apps as apps of the launcher (docs/POWOS-APPS-FEASIBILITY.md section 6.1): an installed app with a page
 * (powos-app.json "page") is in the drawer, search and the recent apps as "p:<id>", and opens full screen in this page
 * (ui/appscreen.tsx) - its page module rendered with the host, as a widget is, so it shares the shell's one Preact, one
 * SpacetimeDB SDK and one socket per database instead of a WebView of its own (~0.4 MB instead of ~20).
 *
 * Hot reload: a file of an app's installed UI changing (files.changed "_app/<id>/...", hot.ts - `powos app ui` / `dev`
 * writes only the files that changed) imports its page and widgets again in place, the shell page itself not
 * reloaded: home, the open app and its connection stay; the component's own state starts again.
 */
import { computed, signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import type { RegistryApp } from "./registry.ts";
import type { App } from "../types.ts";

// No import of stdb.ts or registry.ts here: state.ts imports this, and they import state.ts (apps/onscreen.ts).

export const PREFIX = "p:";

/** The registry's apps for the shell's own lists (the drawer, search, recents): registry.ts watchRegistry keeps it. */
export const installedApps = signal<RegistryApp[]>([]);

/** What the shell reads of an app's manifest (powos-app.json, kept whole in the registry). */
export interface AppManifest {
  /**
   * Its full-screen page (an app with one is an app in the launcher): an ES module in its UI dir, as a widget. It sits on
   * the frost (shell.css); `background: "own"` for a page that paints its own ground (a canvas): no frost under it.
   */
  page?: { entry: string; background?: "own" };
  /** Its icon, a file in its UI dir. */
  icon?: string;
  surfaces?: { launcher?: boolean };
  /** Its screen for the smart glasses (glasses/api.ts): an ES module in its UI dir, picked on the phone's glasses screen. */
  glasses?: { entry: string };
}

const parsed = new Map<string, AppManifest>();
export function manifestOf(app: RegistryApp): AppManifest {
  let m = parsed.get(app.manifest);
  if (!m) {
    try {
      m = JSON.parse(app.manifest) as AppManifest;
    } catch {
      m = {};
    }
    parsed.set(app.manifest, m);
  }
  return m;
}

/** How many times each app's installed UI changed since the page loaded: part of its modules' URLs. */
export const appRev = signal<Record<string, number>>({});
const settle = new Map<string, number>();

/** A file of [id]'s installed UI changed: its modules are imported again once the changes stop (a sync is several files). */
export function appChanged(id: string) {
  clearTimeout(settle.get(id));
  settle.set(
    id,
    window.setTimeout(() => {
      settle.delete(id);
      appRev.value = { ...appRev.value, [id]: (appRev.value[id] ?? 0) + 1 };
    }, 120),
  );
}

/**
 * A module that didn't load (a 404 mid-install, a syntax error being fixed) is tried again after these waits (ms),
 * the last one repeating - and at once when the app changes (a new URL). A failed import is cached by its URL, so
 * each try asks for a new one ([retryUrl]). Never a dead tile.
 */
const RETRY_MS = [1000, 3000, 10000, 30000];
export const retryDelay = (n: number) => RETRY_MS[Math.min(n, RETRY_MS.length - 1)];
export const retryUrl = (url: string, n: number) => (n ? `${url}&t=${n}` : url);

/** A module of [id]'s UI (its page, a widget): a new URL for every version and every change, so it's imported anew. */
export const moduleUrl = (id: string, entry: string, version: string) =>
  `./_app/${id}/${entry}?v=${encodeURIComponent(version)}&r=${appRev.value[id] ?? 0}`;

/** The installed apps that have a page, as launcher apps. */
export const powosApps = computed<App[]>(() =>
  installedApps.value.flatMap((a) => {
    const m = manifestOf(a);
    if (!m.page?.entry || m.surfaces?.launcher === false) return [];
    return [{ key: PREFIX + a.id, label: a.name, icon: m.icon ? moduleUrl(a.id, m.icon, a.version) : initial(a.name), kind: "powos" as const }];
  }),
);

/** No icon in its manifest: its initial on a tile. */
function initial(name: string) {
  const letter = (name.trim()[0] ?? "?").toUpperCase().replace(/[<&]/g, "");
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 96 96"><rect width="96" height="96" rx="24" fill="#567"/><text x="48" y="64" font-family="sans-serif" font-size="48" fill="#fff" text-anchor="middle">${letter}</text></svg>`;
  return `data:image/svg+xml,${encodeURIComponent(svg)}`;
}

/** The app open full screen: which, and the box it was opened from; closing while it goes. */
export const appView = signal<{ id: string; from: DOMRect | null; closing?: boolean } | null>(null);

export function openApp(id: string, from: DOMRect | null = null) {
  appView.value = { id, from };
  noteOpened(PREFIX + id);
}

export function closeApp() {
  const v = appView.value;
  if (v && !v.closing) {
    // Its look as it goes, taken before anything moves: the picture on its switcher card.
    const el = document.querySelector<HTMLElement>(`.app-screen[data-app="${v.id}"]`);
    const shot = el && shotOf(el);
    if (shot) appShots.set(PREFIX + v.id, shot);
    appView.value = { ...v, closing: true };
  }
  (document.activeElement as HTMLElement | null)?.blur();
  powos.keyboard.hide();
}

/**
 * The PowOS apps opened lately, and when the host's newest recent app was first seen in front. HACK: the host's
 * recents (usage.recent, Android's usage stats) come without times, so a PowOS app is placed by when the host's
 * front app changed: opened since, before it; earlier, just after it. Real fix: usage.recent with each app's last
 * time (ShellBridge.kt), and PowOS apps' opens recorded there too, so one list is ordered by time.
 */
interface Opened {
  list: { key: string; at: number }[];
  front: { key: string; at: number } | null;
}
const STORE = "powos-apps-recent";
export const opened = signal<Opened>({ list: [], front: null });

function save() {
  powos.store.set(STORE, opened.value);
}

function noteOpened(key: string) {
  const list = [{ key, at: Date.now() }, ...opened.value.list.filter((o) => o.key !== key)].slice(0, 12);
  opened.value = { ...opened.value, list };
  save();
}

/** The host's recent apps came: its front app noted when it's a new one. */
export function noteHostRecent(keys: string[]) {
  const front = keys[0];
  if (!front || opened.value.front?.key === front) return;
  opened.value = { ...opened.value, front: { key: front, at: Date.now() } };
  save();
}

/** The host's recents (newest first) with the PowOS apps opened here (those still installed). */
export function mergeRecent(hostKeys: string[], installed: Set<string>): string[] {
  const o = opened.value;
  const frontAt = o.front && o.front.key === hostKeys[0] ? o.front.at : 0;
  const mine = o.list.filter((x) => installed.has(x.key));
  const newer = mine.filter((x) => x.at > frontAt).map((x) => x.key);
  const older = mine.filter((x) => x.at <= frontAt).map((x) => x.key);
  return [...new Set([...newer, ...hostKeys.slice(0, 1), ...older, ...hostKeys.slice(1)])];
}

/** Home's: the PowOS apps' recents read (the registry is watched by ui/appscreen.tsx, mounted with home). */
export async function initPowosApps() {
  const v = await powos.store.get<Opened>(STORE).catch(() => null);
  if (v && Array.isArray(v.list)) opened.value = { list: v.list, front: v.front ?? null };
}

/**
 * PowOS apps in the switcher, as cards beside Android's tasks (ui/recents.tsx): one per app opened here lately, with a
 * negative task id (Android's are positive), its last look as the card's picture ([appShots], taken as its page
 * closes), its icon and name. A tap opens it full screen again; a swipe up or clear all forgets it.
 */
const taskIds = new Map<string, number>();
const taskKeys = new Map<number, string>();
function taskId(key: string) {
  let id = taskIds.get(key);
  if (id == null) {
    id = -(taskIds.size + 1);
    taskIds.set(key, id);
    taskKeys.set(id, key);
  }
  return id;
}
/** A PowOS app's card id -> its app id (null: an Android task). */
export const taskApp = (id: number) => (id < 0 ? (taskKeys.get(id)?.slice(PREFIX.length) ?? null) : null);

/** Each app's page as it last looked (an SVG of its DOM), by launcher key: its switcher card's picture. */
export const appShots = new Map<string, string>();

/** [el] (an open app's page) as a picture: its DOM in an SVG foreignObject, the theme's custom properties with it. */
export function shotOf(el: HTMLElement): string | null {
  try {
    const w = innerWidth;
    const h = innerHeight;
    const root = getComputedStyle(document.documentElement);
    let vars = "";
    for (let i = 0; i < root.length; i++) {
      const p = root[i];
      if (p.startsWith("--")) vars += `${p}:${root.getPropertyValue(p)};`;
    }
    const clone = el.cloneNode(true) as HTMLElement;
    clone.style.transform = "none";
    clone.style.opacity = "1";
    clone.style.position = "absolute";
    const body = getComputedStyle(document.body);
    const xhtml = new XMLSerializer().serializeToString(clone);
    const style = `${vars}width:${w}px;height:${h}px;position:relative;overflow:hidden;font-family:${body.fontFamily};font-size:${body.fontSize}`.replace(/"/g, "'");
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}"><foreignObject width="100%" height="100%"><div xmlns="http://www.w3.org/1999/xhtml" style="${style}">${xhtml}</div></foreignObject></svg>`;
    return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
  } catch (e) {
    console.error("[powos-app] snapshot failed", e);
    return null;
  }
}

/** No picture of it yet: its icon and name on the theme's background. */
function cardFace(label: string, icon: string) {
  const w = innerWidth;
  const h = innerHeight;
  const bg = getComputedStyle(document.documentElement).getPropertyValue("--color-background").trim() || "#222";
  const fg = getComputedStyle(document.documentElement).getPropertyValue("--color-foreground").trim() || "#ddd";
  const esc = (s: string) => s.replace(/[<&"]/g, "");
  const href = icon.startsWith("data:") ? icon : new URL(icon, location.href).href;
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="${w}" height="${h}"><rect width="100%" height="100%" fill="${esc(bg)}"/><image href="${esc(href)}" x="${w / 2 - 48}" y="${h / 2 - 96}" width="96" height="96"/><text x="${w / 2}" y="${h / 2 + 40}" fill="${esc(fg)}" font-family="sans-serif" font-size="22" text-anchor="middle">${esc(label)}</text></svg>`;
  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
}

/** Forgets [key] from the recents (a swipe up on its card, clear all). */
export function forgetOpened(key: string) {
  opened.value = { ...opened.value, list: opened.value.list.filter((o) => o.key !== key) };
  appShots.delete(key);
  save();
}

/**
 * Android's task list with the PowOS apps' cards in it. The task the switcher was opened over stays first (a swiped-up
 * window lands on the first card); then, as in [mergeRecent], PowOS apps opened since Android's front app changed,
 * that app, the older PowOS apps, the rest. An app open full screen now (the overview button over it) comes first.
 */
export function mergeTasks<T extends { id: number; label: string; key: string | null; icon: string | null; snapshot: string }>(
  host: T[],
  over: number | null,
): T[] {
  const apps = new Map(powosApps.value.map((a) => [a.key, a]));
  const mine = opened.value.list.filter((o) => apps.has(o.key));
  if (!mine.length) return host;
  const frontAt = opened.value.front?.at ?? 0;
  const card = (o: { key: string }) => {
    const a = apps.get(o.key)!;
    return { id: taskId(o.key), label: a.label, key: o.key, icon: a.icon, snapshot: appShots.get(o.key) ?? cardFace(a.label, a.icon) } as T;
  };
  const showing = appView.value && !appView.value.closing ? PREFIX + appView.value.id : null;
  const newer = mine.filter((o) => o.key === showing || o.at > frontAt).map(card);
  const older = mine.filter((o) => !(o.key === showing || o.at > frontAt)).map(card);
  const i = over == null ? -1 : host.findIndex((t) => t.id === over);
  const first = i >= 0 ? [host[i]] : [];
  const rest = i >= 0 ? [...host.slice(0, i), ...host.slice(i + 1)] : host;
  return first.length ? [...first, ...newer, ...older, ...rest] : [...newer, ...rest.slice(0, 1), ...older, ...rest.slice(1)];
}
