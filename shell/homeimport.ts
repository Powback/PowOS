/**
 * Home + dock from another of the user's PowOS devices (the user, 2026-11-09, on the razr fold: "I only have the
 * recents, I don't have my original dock, the ones that are usually pinned"). One import action, no live sync:
 *   - every device's shell keeps its own layout as data/layout-export.json (state.ts exportLayout: home's pinned apps,
 *     folders, the shell's panels, the dock's pins), which its device agent hands a paired device ("layout" action:
 *     lib/devices/powos-deviced, devices/DeviceAgentCore.kt);
 *   - the Devices app on this one fetches it ("Import home and dock" on a paired device's card) and [importLayout]
 *     applies it here: apps mapped by package name (an Android app's activity or profile may differ per device;
 *     PowOS / Linux apps by their own key), the ones not installed here skipped and counted, nothing removed.
 * [plan] is pure (shell/test/homeimport.test.ts); [importLayout] is its application through powos.home / store.
 */
import type { App, Cell, Home, HomeItem } from "./types.ts";

/** What a device exports: its home and dock, as its own shell sees them. */
export interface LayoutExport {
  v: 1;
  at: number;
  dock: string[];
  home: Pick<Home, "pages" | "items">;
}

export interface ImportPlan {
  /** This device's dock after the import: the other's pins mapped here, then this one's own not among them. */
  dock: string[];
  /** Apps to pin to home, each where it was there (page, cell). */
  apps: { app: string; page: number; cell: Cell | null }[];
  /** Folders: their apps (mapped) pinned and grouped, where the folder was. */
  folders: { apps: string[]; page: number; cell: Cell | null }[];
  /** The shell's own panels (search, agents ...) placed as there, when this home has none of that name. */
  panels: { name: string; page: number; cell: Cell }[];
  /** Labels/keys of apps not installed here. */
  skipped: string[];
}

const pkgOf = (key: string) => (key.startsWith("a:") ? key.slice(2).split("/")[0] : null);

/** The key of [key]'s app on this device: the same key, else (Android) the same package - the main profile first. */
export function mapKey(key: string, apps: App[]): string | null {
  if (apps.some((a) => a.key === key)) return key;
  const pkg = pkgOf(key);
  if (!pkg) return null;
  const same = apps.filter((a) => pkgOf(a.key) === pkg);
  return (same.find((a) => !a.work && !a.clone) ?? same[0])?.key ?? null;
}

type Mapper = (key: string, label?: string) => string | null;

/** The other's dock mapped here, then this device's own pins not among them. */
function planDock(src: string[], own: string[], map: Mapper): string[] {
  const dock: string[] = [];
  for (const m of [...src.map((k) => map(k)), ...own]) if (m && !dock.includes(m)) dock.push(m);
  return dock;
}

/** The apps already on this home: app items, and the ones inside folders. */
function appsOn(items: HomeItem[]): Set<string> {
  const on = new Set<string>();
  for (const it of items) {
    if (it.kind === "app" && it.app) on.add(it.app);
    for (const a of it.apps ?? []) on.add(a.app);
  }
  return on;
}

/** A folder's apps mapped here and not on home yet: a folder of 2+, one app alone, or nothing. */
function planFolder(it: HomeItem, map: Mapper, onHome: Set<string>, out: ImportPlan) {
  const ms = (it.apps ?? []).map((a) => map(a.app, a.label)).filter((m): m is string => !!m && !onHome.has(m));
  ms.forEach((m) => onHome.add(m));
  if (ms.length > 1) out.folders.push({ apps: ms, page: it.page, cell: it.cell });
  else if (ms.length === 1) out.apps.push({ app: ms[0], page: it.page, cell: it.cell });
}

interface PlanCtx { map: Mapper; onHome: Set<string>; panelsHere: Set<string | undefined>; out: ImportPlan }

function planItem(it: HomeItem, { map, onHome, panelsHere, out }: PlanCtx) {
  if (it.kind === "folder") return planFolder(it, map, onHome, out);
  if (it.kind === "panel") {
    if (it.name && it.cell && !panelsHere.has(it.name)) out.panels.push({ name: it.name, page: it.page, cell: it.cell });
    return;
  }
  if (it.kind !== "app" || !it.app) return;
  const m = map(it.app, it.label);
  if (!m || onHome.has(m)) return;
  onHome.add(m);
  out.apps.push({ app: m, page: it.page, cell: it.cell });
}

export function plan(src: LayoutExport, apps: App[], here: { dock: string[]; home: Pick<Home, "items"> }): ImportPlan {
  const skipped: string[] = [];
  const map: Mapper = (key, label) => {
    const k = mapKey(key, apps);
    if (!k) skipped.push(label || key);
    return k;
  };
  const out: ImportPlan = { dock: planDock(src.dock ?? [], here.dock, map), apps: [], folders: [], panels: [], skipped };
  const ctx: PlanCtx = { map, out, onHome: appsOn(here.home.items), panelsHere: new Set(here.home.items.filter((i) => i.kind === "panel").map((i) => i.name)) };
  for (const it of (src.home?.items ?? []) as HomeItem[]) planItem(it, ctx);
  return out;
}

/** The host calls [importLayout] needs (bridge.ts powos.home / store / apps). */
export interface ImportHost {
  apps(): Promise<App[]>;
  dock(): Promise<string[]>;
  home(): Promise<Home>;
  setDock(keys: string[]): Promise<void>;
  add(app: string, page: number, cell?: Cell): Promise<string>;
  group(key: string, target: string): Promise<string | null>;
  addPanel(name: string, page: number, cell: Cell): Promise<string>;
}

const cellOf = (c: Cell | null) => (c ? { ...c, w: 1, h: 1 } : undefined);

/** A folder: its first app where the folder was, the others grouped onto it. False: nothing placed. */
async function placeFolder(f: ImportPlan["folders"][number], host: ImportHost): Promise<boolean> {
  const first = await host.add(f.apps[0], f.page, cellOf(f.cell)).catch(() => null);
  if (!first) return false;
  let target: string = first;
  for (const app of f.apps.slice(1)) {
    const k = await host.add(app, f.page).catch(() => null);
    if (k) target = (await host.group(k, target).catch(() => null)) ?? target;
  }
  return true;
}

const isLayout = (src: LayoutExport) => !!src && src.v === 1 && Array.isArray(src.dock) && !!src.home;

/** Applies [src] here; resolves with what it did (for the Devices app's line). One failed item never stops the rest. */
export async function importLayout(src: LayoutExport, host: ImportHost) {
  if (!isLayout(src)) throw new Error("not a PowOS layout");
  const p = plan(src, await host.apps(), { dock: await host.dock(), home: await host.home() });
  await host.setDock(p.dock);
  let placed = 0;
  for (const a of p.apps) placed += await host.add(a.app, a.page, cellOf(a.cell)).then(() => 1, () => 0);
  for (const f of p.folders) placed += (await placeFolder(f, host)) ? 1 : 0;
  for (const pn of p.panels) await host.addPanel(pn.name, pn.page, pn.cell).catch(() => undefined);
  return { dock: p.dock.length, home: placed, skipped: p.skipped };
}
