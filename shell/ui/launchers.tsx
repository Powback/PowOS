/**
 * Quick launchers: a row of one-tap app buttons under the control center's toggles (the iPhone's flashlight / timer /
 * calculator / camera row). Same chip look as a toggle (.cc3-*). Which ones, and their order, are the user's, edited in
 * the control center's own edit mode (ccEditing, useReorder): drag to reorder, tap the minus to take one off, tap a chip
 * of the "add" row to put it on. Launch is the dock's call (powos.apps.launch). A launcher whose app isn't installed is
 * not offered; with none resolved (a mode with no apps list) the row is not drawn.
 */
import { signal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import { powos } from "../bridge.ts";
import type { App } from "../types.ts";
import { ccEditing } from "./ccexpand.ts";
import { Icon } from "./icons.tsx";
import { useReorder } from "./reorder.ts";

interface Launcher {
  id: string;
  label: string;
  /** App keys it opens, best first: Android "a:<package/..." (OnePlus, then Google / AOSP), PowOS Linux "l:...". */
  match: RegExp[];
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
const apps = signal<App[]>([]);
/** The launcher just tapped: its chip shows at once (optimistic), until the app is in front. */
const pressed = signal<string | null>(null);

export const loadLaunchers = () => {
  powos.store.get<string[]>("controls.launchers").then((l) => (chosen.value = Array.isArray(l) ? l : DEFAULT)).catch(() => (chosen.value ??= DEFAULT));
  powos.apps.list().then((a) => (apps.value = a), () => {});
};

function resolve(l: Launcher): App | undefined {
  for (const re of l.match) {
    const a = apps.value.find((x) => re.test(x.key));
    if (a) return a;
  }
}

function save(ids: string[]) {
  chosen.value = ids;
  powos.store.set("controls.launchers", ids);
}

function open(l: Launcher, a: App, shut: () => void) {
  pressed.value = l.id;
  setTimeout(() => pressed.value === l.id && (pressed.value = null), 600);
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
        onClick={() => (editing ? remove?.() : open(l, a, shut))}
      >
        <span class="cc3-chip">
          <img src={a.icon} alt="" draggable={false} />
          {editing && <span class="cc3-badge"><Icon name="close" /></span>}
        </span>
        <span class="cc3-word">{l.label}</span>
      </button>
    </div>
  );
}

export function Launchers({ hooks, shut }: { hooks: Parameters<typeof useReorder>[3]; shut: () => void }) {
  useEffect(loadLaunchers, []);
  const ids = chosen.value ?? DEFAULT;
  const shown = ids.map((id) => CATALOG.find((l) => l.id === id)).filter((l): l is Launcher => !!l && !!resolve(l));
  const r = useReorder(shown.map((l) => l.id), save, ccEditing, { ...hooks, onlyEditing: true });
  const spare = CATALOG.filter((l) => !ids.includes(l.id) && resolve(l));
  const editing = ccEditing.value;
  if (!shown.length && !(editing && spare.length)) return null;
  return (
    <div class="cc3-launchers cascade" style={{ "--i": 4 }}>
      <div class="cc3-grid" {...r.handlers}>
        {r.order.map((id) => {
          const l = CATALOG.find((x) => x.id === id)!;
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
    </div>
  );
}
