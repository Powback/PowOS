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
  /** Its full-screen page (an app with one is an app in the launcher): an ES module in its UI dir, as a widget. */
  page?: { entry: string };
  /** Its icon, a file in its UI dir. */
  icon?: string;
  surfaces?: { launcher?: boolean };
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
  if (v && !v.closing) appView.value = { ...v, closing: true };
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
