/**
 * Edit mode's bar (the Compose launcher's home menu, slimmed): "+ widget" opens one picker of everything that can go on
 * home; "theme" a strip of swatches, each in its own colors, the picked one framed - a tap recolors everything at once;
 * done. Up while editing (state.ts editing), at the foot of the screen under the home pages.
 */
import { useEffect, useRef } from "preact/hooks";
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import { carry, editing, home, page, pages } from "../state.ts";
import { openScreen } from "../screens.ts";
import { AppWidgetPicker, picker } from "./appwidget.tsx";
import { geometry, placeNew, placeNewCells } from "./grid.tsx";
import { hasRecentsWidget, recentsSpot } from "./recentwidget.tsx";
import { startNewApp } from "./appbuild.tsx";
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

/** The theme popover (the bar's "theme"): open or not. */
const themesOpen = signal(false);

/**
 * What the "+ widget" picker offers besides Android's widgets (ui/appwidget.tsx AppWidgetPicker heads its list with
 * these, and PowOS apps' widgets): the shell's own widgets, the stores, and new ones made with the coding agent.
 */
function ShellAdds({ done }: { done: () => void }) {
  const who = (agent.value ?? "an agent").toLowerCase();
  const chip = (label: string, run: () => void) => (
    <button
      type="button"
      class="sheet-item"
      onClick={() => {
        done();
        run();
      }}
    >
      {label}
    </button>
  );
  return (
    <div class="sheet-items">
      {chip(`new widget with ${who}`, () => powos.agents.newWidget())}
      {/* PowOS AI builds a PowOS app in its own chat thread (ui/appbuild.tsx); another agent, in a terminal. */}
      {chip(`new app with ${who}`, () => (agent.value === "PowOS AI" ? startNewApp() : powos.agents.newApp()))}
      {!home.value.items.some((i) => i.key === "panel:agents") &&
        chip("agents", () => {
          // The Agents widget: about 4×2 cells, in the first free spot.
          const cell = innerWidth / home.value.columns;
          const spot = placeNew(4 * cell - 8, 2 * cell - 8);
          powos.home.addPanel("agents", spot.page, spot.cell);
        })}
      {!hasRecentsWidget() &&
        chip("recent apps", () => {
          // A row, full width: the lowest free row of the page on screen, else the first free spot.
          const n = pages.value[page.value] ?? 1;
          const spot = recentsSpot(n, geometry.value.rows || 6) ?? placeNewCells(home.value.columns, 1);
          powos.home.addPanel("recents", spot.page, spot.cell);
        })}
      {chip("widget store", () => openScreen("store"))}
      {chip("AUR app store", () => openScreen("aur"))}
    </div>
  );
}

/**
 * Edit mode's bar: one slim strip at the foot of the screen, where the search bar and the dock were - "+ widget"
 * (one picker: the shell's widgets, PowOS apps', Android's, the stores, new ones with the agent), the theme (a small
 * popover of swatches, with the settings), done. The pages stay in view and in reach above it.
 */
export function EditSheet() {
  const strip = useRef<HTMLDivElement>(null);
  const open = editing.value;
  useEffect(() => {
    if (!open) return;
    // Fresh each time it opens: themes download and get added, the agent can change.
    themesOpen.value = false;
    powos.theme.list().then((l) => (themes.value = l));
    powos.theme.get().then((t) => (picked.value = t.name));
    powos.agents.default().then((a) => (agent.value = a));
  }, [open]);
  // The picked theme in view, as the Compose strip starts at it.
  useEffect(() => {
    strip.current?.querySelector<HTMLElement>(".swatch.on")?.scrollIntoView({ inline: "center", block: "nearest" });
  }, [themesOpen.value, themes.value.length]);
  // Out of the way while a tile is carried: the whole page is somewhere to drop it.
  if (!open || carry.value) return null;
  // The picker in its place while it's open (over home, its own scrolling list).
  if (picker.value) return <AppWidgetPicker onPick={addAppWidget} head={(close) => <ShellAdds done={close} />} />;
  const current = themes.value.find((t) => t.name === picked.value);
  const stop = (e: Event) => e.stopPropagation();
  return (
    <>
      {themesOpen.value && (
        <div class="theme-pop tile" onPointerDown={stop} onTouchStart={stop}>
          <div class="sheet-row">
            <span class="muted">theme · {current?.title.toLowerCase()}</span>
            <button type="button" class="sheet-done" onClick={() => ((themesOpen.value = false), openScreen("settings"))}>
              settings
            </button>
          </div>
          <div class="swatches" ref={strip}>
            {themes.value.map((t) => (
              <Swatch key={t.name} theme={t} />
            ))}
            <button type="button" class="swatch browse" onClick={() => openScreen("themes")}>
              <span class="swatch-name">browse…</span>
            </button>
          </div>
        </div>
      )}
      <div class="edit-sheet tile" onPointerDown={stop} onTouchStart={stop}>
        <button type="button" class="edit-act" onClick={() => ((themesOpen.value = false), (note.value = null), (picker.value = true))}>
          + widget
        </button>
        <button type="button" class={`edit-act ${themesOpen.value ? "on" : ""}`} onClick={() => (themesOpen.value = !themesOpen.value)}>
          theme
        </button>
        <span class="edit-note muted">{note.value ?? ""}</span>
        <button type="button" class="edit-act done" onClick={() => (editing.value = false)}>
          done
        </button>
      </div>
    </>
  );
}
