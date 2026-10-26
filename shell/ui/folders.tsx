/**
 * Home's folders: made from picked apps (edit mode, homeselect.ts), opened as a frosted popover of their apps.
 *
 * - The folder itself is the host's (ShellHome.kt Shortcuts / hosts/layout.ts): its apps, its cell, kept with the home
 *   layout; a folder left with one app goes away there (tidy), that app in its place.
 * - Its name is the shell's: store "home.folders" (folder key -> name), shown under the tile, edited in the popover.
 * - In the popover: tap an app to open it; hold one and drag it out to put it on home where it's let go (out of the
 *   folder: powos.home.add, the host takes it out).
 */
import { signal } from "@preact/signals";
import { useRef } from "preact/hooks";
import { byKey, folder, home, launch } from "../state.ts";
import { powos } from "../bridge.ts";
import { AppIcon } from "./apps.tsx";
import type { HomeItem } from "../types.ts";

const STORE = "home.folders";
const HOLD_MS = 420;
const SLOP = 10;

export const folderNames = signal<Record<string, string>>({});
let loaded = false;

/** Reads the folders' names once. */
export function loadFolderNames() {
  if (loaded) return;
  loaded = true;
  powos.store
    .get<Record<string, string>>(STORE)
    .then((v) => v && typeof v === "object" && (folderNames.value = { ...v, ...folderNames.value }))
    .catch(() => {});
}

export const folderName = (key: string) => folderNames.value[key] || "Folder";

export function nameFolder(key: string, name: string) {
  const next = { ...folderNames.value };
  const t = name.trim().slice(0, 40);
  if (t) next[key] = t;
  else delete next[key];
  folderNames.value = next;
  powos.store.set(STORE, next).catch(() => {});
}

/** Picked tiles that can make a folder: 2+ apps, or apps and one folder to put them in. */
export function folderable(items: HomeItem[]) {
  const apps = items.filter((i) => i.kind === "app");
  const folders = items.filter((i) => i.kind === "folder");
  return folders.length <= 1 && apps.length + folders.length >= 2 && apps.length >= 1;
}

/**
 * Puts the picked apps in one folder: the picked folder, else a new one where the first of them (reading order) is.
 * Returns the folder's key.
 */
export async function groupIntoFolder(items: HomeItem[]): Promise<string | null> {
  const order = [...items].sort((a, b) => a.cell!.y - b.cell!.y || a.cell!.x - b.cell!.x);
  const into = order.find((i) => i.kind === "folder") ?? order.find((i) => i.kind === "app");
  if (!into) return null;
  let target = into.key;
  for (const a of order.filter((i) => i.kind === "app" && i.key !== into.key)) target = (await powos.home.group(a.key, target)) ?? target;
  navigator.vibrate?.(10);
  return target;
}

/** A folder's tile: a face of its own (page glass, grid.tsx textured) with its first four apps' icons, small. */
export function FolderFace({ item }: { item: HomeItem }) {
  return (
    <div class="folder-face tile" aria-label={folderName(item.key)}>
      {item.apps!.slice(0, 4).map((a) => {
        const app = byKey.value.get(a.app);
        return app ? <img key={a.key} src={app.icon} alt="" draggable={false} /> : <span key={a.key}>{a.label[0]}</span>;
      })}
    </div>
  );
}

export type DragOut = (app: string, from: string | undefined, e: PointerEvent, grab: { x: number; y: number }) => void;

/**
 * An app in a folder or the app library: a tap opens it (then [onLeave]), a hold lifts it out to put on home (onHold;
 * [onLift] first - a popover closes). Lifted, the finger is the carry's: no scroll of the list it was in.
 */
export function AppPress({ a, from, onHold, onLeave, onLift, small }: { a: { key: string; label: string; app: string }; from?: string; onHold: DragOut; onLeave?: () => void; onLift?: () => void; small?: boolean }) {
  const press = useRef<{ x: number; y: number; timer: number; long: boolean } | null>(null);
  const app = byKey.value.get(a.app);
  const cancel = () => {
    if (press.current) clearTimeout(press.current.timer);
    press.current = null;
  };
  return (
    <div
      class="app"
      data-key={a.key}
      onPointerDown={(e) => {
        if (e.button) return;
        e.stopPropagation();
        const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
        const p = { x: e.clientX, y: e.clientY, timer: 0, long: false };
        p.timer = window.setTimeout(() => {
          p.long = true;
          navigator.vibrate?.(10);
          onLift?.();
          onHold(a.app, from, e, { x: e.clientX - r.left, y: e.clientY - r.top });
        }, HOLD_MS);
        press.current = p;
      }}
      onPointerMove={(e) => press.current && !press.current.long && Math.hypot(e.clientX - press.current.x, e.clientY - press.current.y) > SLOP && cancel()}
      onPointerUp={(e) => {
        const p = press.current;
        cancel();
        if (!p || p.long) return;
        e.stopPropagation();
        onLeave?.();
        launch(a.app);
      }}
      onTouchMove={(e) => press.current?.long && e.cancelable && e.preventDefault()}
      onClick={(e) => e.stopPropagation()}
      onPointerCancel={cancel}
    >
      <div class="tile-app">
        {app ? <AppIcon src={app.icon} label={a.label} /> : <div class="app-icon initials">{a.label[0]}</div>}
        {!small && <div class="app-label">{a.label}</div>}
      </div>
    </div>
  );
}

/** The folder on screen open or still shrinking back (ui/folderview.tsx): its tile is hidden meanwhile - it IS the sheet. */
export const morphing = signal<string | null>(null);
