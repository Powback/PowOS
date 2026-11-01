/**
 * Quick launchers: a row of one-tap app buttons under the control center's toggles (the iPhone's flashlight / timer /
 * calculator / camera row). Same chip look as a toggle (.cc3-*). Which ones, and their order, are the user's, edited in
 * the control center's own edit mode (ccEditing, useReorder): drag to reorder, tap the minus to take one off, tap a chip
 * of the "add" row to put it on. Launch is the dock's call (powos.apps.launch). A launcher whose app isn't installed is
 * not offered; with none resolved (a mode with no apps list) the row is not drawn. Any other app joins from its long-press
 * menu ("add to quick launch", apps.tsx AppMenu → toggleLauncher): stored by its app key, it rides the same row, order
 * and edit mode as a catalog launcher. A quick-page item ("qp:<ACTION>", ui/quickpage.tsx QUICK_PAGES, added from the
 * edit mode's "quick pages" row) opens that ONE settings page as a quick page springing out of its chip.
 */
import { signal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import { powos } from "../bridge.ts";
import type { App } from "../types.ts";
import { ccEditing } from "./ccexpand.ts";
import { followNotif } from "./gesture.ts";
import { Icon } from "./icons.tsx";
import { openQuickPage, QUICK_ID, QUICK_PAGES, quickAction, rectOf } from "./quickpage.tsx";
import { useReorder } from "./reorder.ts";

interface Launcher {
  id: string;
  label: string;
  /** App keys it opens, best first: Android "a:<package/..." (OnePlus, then Google / AOSP), PowOS Linux "l:...". */
  match: RegExp[];
  /** An app added from its menu: exactly this app key (the id), no catalog match. */
  key?: string;
  /** A quick-page item: the settings ACTION it opens (quickpage.open), the Settings app's icon. */
  action?: string;
}

/** The catalog; the first five are the default row. Order here is the default order. */
const CATALOG: Launcher[] = [
  { id: "clock", label: "clock", match: [/^a:com\.oneplus\.deskclock/, /^a:com\.google\.android\.deskclock/, /^a:com\.android\.deskclock/, /^l:org\.kde\.kclock/] },
  { id: "calculator", label: "calculator", match: [/^a:com\.oneplus\.calculator/, /^a:com\.google\.android\.calculator/, /^a:com\.android\.calculator2/, /^l:org\.kde\.kcalc/] },
  { id: "camera", label: "camera", match: [/^a:com\.oplus\.camera/, /^a:com\.google\.android\.GoogleCamera/, /^a:com\.android\.camera/, /^l:org\.kde\.kamoso/] },
  { id: "notes", label: "notes", match: [/^a:com\.oneplus\.note/, /^a:com\.google\.android\.keep/, /^l:org\.kde\.knotes/] },
  { id: "recorder", label: "recorder", match: [/^a:com\.oneplus\.soundrecorder/, /^a:com\.google\.android\.apps\.recorder/, /^l:org\.kde\.krecorder/] },
  { id: "screenrec", label: "screen rec", match: [/^a:com\.oplus\.screenrecorder/, /^l:org\.kde\.spectacle/] },
];
const DEFAULT = CATALOG.slice(0, 5).map((l) => l.id);

/** The user's chosen ids in order (store "controls.launchers"); null until read, then DEFAULT if never edited. */
const chosen = signal<string[] | null>(null);
/** The apps list, read with the row (the shade is its own page: home's list isn't here); the media cards' icons too. */
export const apps = signal<App[]>([]);
/** The launcher just tapped: its chip shows at once (optimistic), until the app is in front. */
const pressed = signal<string | null>(null);

let loading: Promise<unknown> | null = null;
/** Reads the stored row and the apps list; the promise lets the app menu's toggle wait for it (never edit DEFAULT). */
export const loadLaunchers = () => {
  loading = Promise.all([
    powos.store.get<string[]>("controls.launchers").then((l) => (chosen.value = Array.isArray(l) ? l : DEFAULT)).catch(() => (chosen.value ??= DEFAULT)),
    powos.apps.list().then((a) => (apps.value = a), () => {}),
  ]);
};

/*
 * The shade is its own page: an app added from home's menu reaches it through the store, so each pull reads the row
 * again (once, at its first frame) - the panel never shows a list from before the edit.
 */
let pulled = false;
powos.on("shade.drag", () => {
  if (!pulled) loadLaunchers();
  pulled = true;
});
powos.on("shade.settle", ({ open }: { open: boolean }) => {
  if (open && !pulled) loadLaunchers();
  pulled = open;
});

/** A stored id: a catalog launcher, or an app key added from the app menu (keys carry a "x:" kind prefix, ids don't). */
function launcherOf(id: string): Launcher | undefined {
  const action = quickAction(id);
  if (action) return { id, label: (QUICK_PAGES.find((q) => q.action === action)?.label ?? action.split(".").pop() ?? action).toLowerCase(), match: [], action };
  const c = CATALOG.find((l) => l.id === id);
  if (c || !id.includes(":")) return c;
  const a = apps.value.find((x) => x.key === id);
  return { id, label: (a?.label ?? id).toLowerCase(), match: [], key: id };
}

/** The app a stored id opens, if installed. */
const appOf = (id: string) => {
  const l = launcherOf(id);
  return l && resolve(l);
};

/** The Settings app's icon for a quick-page item (none listed: a blank chip, still the page's item). */
function settingsApp(l: Launcher): App {
  const s = apps.value.find((x) => x.key.startsWith("a:com.android.settings/"));
  return { key: l.id, label: l.label, icon: s?.icon ?? "", kind: "android" };
}

function resolve(l: Launcher): App | undefined {
  if (l.action) return settingsApp(l);
  if (l.key) return apps.value.find((x) => x.key === l.key);
  for (const re of l.match) {
    const a = apps.value.find((x) => re.test(x.key));
    if (a) return a;
  }
}

function save(ids: string[]) {
  chosen.value = ids;
  powos.store.set("controls.launchers", ids);
}

/** Whether this app is in the row (by its own key, or as the app a catalog launcher resolves to). */
export function inLaunchers(key: string): boolean {
  if (chosen.value === null) loadLaunchers();
  return (chosen.value ?? DEFAULT).some((id) => appOf(id)?.key === key);
}

/**
 * The app menu's "add to / remove from quick launch": the row's own add (to the end) and remove, so its edit mode shows
 * the same list. An app a catalog launcher opens goes on as that launcher (it leaves the "add" row), else by its key.
 */
export async function toggleLauncher(key: string) {
  if (chosen.value === null || !loading) loadLaunchers();
  await loading;
  const ids = chosen.value ?? DEFAULT;
  const hit = (id: string) => appOf(id)?.key === key;
  if (ids.some(hit)) return save(ids.filter((id) => !hit(id)));
  const cat = CATALOG.find((l) => resolve(l)?.key === key);
  save([...ids, cat?.id ?? key]);
}

function open(l: Launcher, a: App, shut: () => void, el: Element) {
  pressed.value = l.id;
  setTimeout(() => pressed.value === l.id && (pressed.value = null), 600);
  // A quick page springs out of its chip (its rect taken before the panel goes); an older host: the page's app.
  if (l.action) {
    const at = rectOf(el);
    shut();
    if (!openQuickPage({ action: l.action, label: QUICK_PAGES.find((q) => q.action === l.action)?.label ?? l.label }, at)) void powos.apps.launch("a:com.android.settings");
    return;
  }
  // The panel goes first (the app comes up behind it), as every tile that leaves the panel.
  shut();
  powos.apps.launch(a.key).catch((e) => console.warn("launcher: ", l.id, e));
}

function Chip({ l, a, shut, remove }: { l: Launcher; a: App; shut: () => void; remove?: () => void }) {
  const editing = ccEditing.value;
  return (
    <div class="cc3-cell" data-key={l.id}>
      <button
        type="button"
        class={`cc3-t cc3-launch ${pressed.value === l.id ? "on" : ""}`}
        aria-label={editing ? `${l.label}: remove` : `open ${l.label}`}
        // In edit mode the row's reorder (useReorder) eats a tap on an item as a select; the remove is this chip's own
        // edit action, so it's let through (the user, 11-02: "Pressing X to remove anything from the quick launch
        // doesn't work").
        data-edit-ok={editing || undefined}
        onClick={(e) => (editing ? remove?.() : open(l, a, shut, e.currentTarget))}
      >
        <span class="cc3-chip">
          {a.icon ? <img src={a.icon} alt="" draggable={false} /> : <Icon name="tuneVariant" />}
          {editing && <span class="cc3-badge"><Icon name="close" /></span>}
        </span>
        <span class="cc3-word">{l.label}</span>
      </button>
    </div>
  );
}

export function Launchers({ hooks, shut }: { hooks: Parameters<typeof useReorder>[3]; shut: () => void }) {
  useEffect(() => void loadLaunchers(), []);
  const ids = chosen.value ?? DEFAULT;
  const shown = ids.map(launcherOf).filter((l): l is Launcher => !!l && !!resolve(l));
  const r = useReorder(shown.map((l) => l.id), save, ccEditing, { ...hooks, onlyEditing: true });
  const spare = CATALOG.filter((l) => !ids.includes(l.id) && resolve(l));
  const editing = ccEditing.value;
  const pages = editing ? QUICK_PAGES.filter((q) => !ids.includes(QUICK_ID + q.action)) : [];
  if (!shown.length && !(editing && (spare.length || pages.length))) return null;
  return (
    <div class="cc3-launchers cascade" data-q ref={followNotif} style={{ "--i": 4 }}>
      <div class="cc3-grid" {...r.handlers}>
        {r.order.map((id) => {
          const l = launcherOf(id)!;
          return <Chip key={id} l={l} a={resolve(l)!} shut={shut} remove={() => save(ids.filter((x) => x !== id))} />;
        })}
      </div>
      {editing && spare.length > 0 && (
        <div class="cc3-grid cc3-spare">
          {spare.map((l) => (
            <div class="cc3-cell" key={l.id}>
              <button type="button" class="cc3-t" aria-label={`add ${l.label}`} onClick={() => save([...ids, l.id])}>
                <span class="cc3-chip">
                  <img src={resolve(l)!.icon} alt="" draggable={false} />
                  <span class="cc3-badge add"><Icon name="plus" /></span>
                </span>
                <span class="cc3-word">{l.label}</span>
              </button>
            </div>
          ))}
        </div>
      )}
      {pages.length > 0 && <QuickPagePicker pages={pages} add={(action) => save([...ids, QUICK_ID + action])} />}
    </div>
  );
}

/** Edit mode's "add quick page" row: the common settings pages (QUICK_PAGES) not on the row yet; a tap adds one. */
function QuickPagePicker({ pages, add }: { pages: { action: string; label: string }[]; add: (action: string) => void }) {
  const icon = apps.value.find((x) => x.key.startsWith("a:com.android.settings/"))?.icon;
  return (
    <div class="cc3-grid cc3-spare cc3-quickpages" aria-label="add quick page">
      {pages.map((q) => (
        <div class="cc3-cell" key={q.action}>
          <button type="button" class="cc3-t" aria-label={`add quick page ${q.label}`} onClick={() => add(q.action)}>
            <span class="cc3-chip">
              {icon ? <img src={icon} alt="" draggable={false} /> : <Icon name="tuneVariant" />}
              <span class="cc3-badge add"><Icon name="plus" /></span>
            </span>
            <span class="cc3-word">{q.label.toLowerCase()}</span>
          </button>
        </div>
      ))}
    </div>
  );
}
