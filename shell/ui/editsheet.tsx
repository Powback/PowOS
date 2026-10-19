/**
 * Edit mode's sheet (the Compose launcher's home menu): new widgets and apps with the coding agent, the widget and AUR
 * stores, settings, and the themes - a strip of swatches, each in its own colors, the picked one framed; a tap
 * recolors everything at once. Up while editing (state.ts editing), under the home pages, which make room for it.
 */
import { useEffect, useRef } from "preact/hooks";
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import { carry, editing } from "../state.ts";
import { AppWidgetPicker, picker } from "./appwidget.tsx";
import { placeNew } from "./grid.tsx";
import type { AppWidgetProvider, ThemeChoice } from "../types.ts";

const themes = signal<ThemeChoice[]>([]);
const picked = signal<string | null>(null);
const agent = signal<string | null>(null);
/** What adding an Android widget came to, when it didn't simply land on home. */
const note = signal<string | null>(null);

powos.on("appwidgets.failed", () => (note.value = "the widget wasn't added"));

/** An Android widget picked: it goes in the first free spot at its size (Android may ask the user first). */
async function addAppWidget(p: AppWidgetProvider) {
  picker.value = false;
  note.value = null;
  const spot = placeNew(p.sizeDp[0], p.sizeDp[1]);
  const r = await powos.appWidgets.add(p.provider, spot.page, spot.cell, spot.width, spot.height).catch(() => "failed");
  if (r === "failed") note.value = `couldn't add ${p.label}`;
}

powos.on("theme.changed", (t: { name: string }) => (picked.value = t.name));

/** The swatch colors a theme shows: its accents in a row, as ThemeSwatch (Setup.kt). */
const ACCENTS = ["accent", "red", "yellow", "green", "magenta"];

function Swatch({ theme }: { theme: ThemeChoice }) {
  const c = theme.colors;
  const on = theme.name === picked.value;
  return (
    <button
      type="button"
      class={`swatch ${on ? "on" : ""}`}
      style={{ background: c.background, color: c.foreground }}
      onClick={() => {
        picked.value = theme.name;
        powos.theme.pick(theme.name);
      }}
    >
      <span class="swatch-name">{theme.title.toLowerCase()}</span>
      <span class="swatch-bars">
        {ACCENTS.map((k) => (
          <i style={{ background: c[k] ?? "gray" }} />
        ))}
      </span>
    </button>
  );
}

export function EditSheet() {
  const strip = useRef<HTMLDivElement>(null);
  const open = editing.value;
  useEffect(() => {
    if (!open) return;
    // Fresh each time it opens: themes download and get added, the agent can change.
    powos.theme.list().then((l) => (themes.value = l));
    powos.theme.get().then((t) => (picked.value = t.name));
    powos.agents.default().then((a) => (agent.value = a));
  }, [open]);
  // The picked theme in view, as the Compose strip starts at it.
  useEffect(() => {
    strip.current?.querySelector<HTMLElement>(".swatch.on")?.scrollIntoView({ inline: "center", block: "nearest" });
  }, [open, themes.value.length]);
  // Out of the way while a tile is carried: the whole page is somewhere to drop it.
  if (!open || carry.value) return null;
  // The picker in its place while it's open (over home, its own scrolling list).
  if (picker.value) return <AppWidgetPicker onPick={addAppWidget} />;
  const who = (agent.value ?? "an agent").toLowerCase();
  const item = (label: string, run: () => void) => (
    <button type="button" class="sheet-item" onClick={run}>
      {label}
    </button>
  );
  const current = themes.value.find((t) => t.name === picked.value);
  return (
    <div class="edit-sheet tile" onPointerDown={(e) => e.stopPropagation()} onTouchStart={(e) => e.stopPropagation()}>
      <div class="sheet-head">
        <span class="muted">edit home</span>
        <button type="button" class="sheet-done" onClick={() => (editing.value = false)}>
          done
        </button>
      </div>
      <div class="sheet-items">
        {item(`new widget with ${who}`, () => powos.agents.newWidget())}
        {item(`new app with ${who}`, () => powos.agents.newApp())}
        {item("android widget", () => (picker.value = true))}
        {item("widget store", () => powos.screens.open("store"))}
        {item("AUR app store", () => powos.screens.open("aur"))}
        {item("settings", () => powos.screens.open("settings"))}
      </div>
      {note.value && <div class="muted">{note.value}</div>}
      <div class="sheet-row">
        <span class="muted">theme</span>
        <span class="muted">{current?.title.toLowerCase()}</span>
      </div>
      <div class="swatches" ref={strip}>
        {themes.value.map((t) => (
          <Swatch key={t.name} theme={t} />
        ))}
        <button type="button" class="swatch browse" onClick={() => powos.screens.open("themes")}>
          <span class="swatch-name">browse…</span>
        </button>
      </div>
    </div>
  );
}
