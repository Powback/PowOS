/**
 * Edit mode's bar (the Compose launcher's home menu, slimmed): "+ widget" opens one picker of everything that can go on
 * home; "+ app" the drawer's list, a tap puts that app on the page in view; "theme" a strip of swatches, each in its own
 * colors, the picked one framed - a tap recolors everything at once; done. Up while editing (state.ts editing), at the foot of the screen under the home pages.
 */
import { useEffect, useRef, useState } from "preact/hooks";
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import { carry, editing, home, page, pages, searchPlacement } from "../state.ts";
import { openScreen } from "../screens.ts";
import { AppWidgetPicker, picker } from "./appwidget.tsx";
import { geometry, placeNew, placeNewCells } from "./grid.tsx";
import { hasRecentsWidget, recentsSpot } from "./recentwidget.tsx";
import { footAim, footBelow, SEARCH_KEY, hasSearchWidget, putBackInBar } from "./searchwidget.tsx";
import { startNewApp } from "./appbuild.tsx";
import { AppList, findApps } from "./drawer.tsx";
import { Pill, type MicTarget } from "./bar.tsx";
import { dropKeyboard } from "./keyboard.ts";
import type { App, AppWidgetProvider, ThemeChoice } from "../types.ts";

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
        try {
          localStorage.setItem(POP_KEY, String(Date.now()));
        } catch {
          // Only the fallback above needs it.
        }
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
 * A theme picked moments ago, and the page loaded anew since (an older app relaunched home on every pick - the system
 * palette's overlay): edit mode and the popover as they were, so trying several themes goes on where it was.
 */
const POP_KEY = "powos.themePop";
let reopen = false;
try {
  // Home's page only (every page loads this module).
  if (!new URLSearchParams(location.search).get("mode")) {
    const at = Number(localStorage.getItem(POP_KEY));
    localStorage.removeItem(POP_KEY);
    if (at && Date.now() - at < 15000) {
      reopen = true;
      editing.value = true;
    }
  }
} catch {
  // No local storage: nothing to restore.
}

/** A tile carried that isn't the search widget (the sheet gives way for it). */
const carriedAway = () => !!carry.value && carry.value.item?.key !== SEARCH_KEY;

/**
 * What the "+ widget" picker offers besides Android's widgets (ui/appwidget.tsx AppWidgetPicker heads its list with
 * these, and PowOS apps' widgets): the shell's own widgets, the stores, and new ones made with the coding agent.
 */
/**
 * The picker's head: PowOS's own widgets as cards like every app's (a "PowOS" group - the search bar, the agents, the
 * recent apps), found by the picker's search too ("search" found nothing when they were plain lines hidden while
 * typing), then the makers and the stores. [q]: the picker's search, lowercased.
 */
function ShellAdds({ done, q }: { done: () => void; q: string }) {
  const who = (agent.value ?? "an agent").toLowerCase();
  const run = (f: () => void) => () => {
    done();
    f();
  };
  const fullRow = () => {
    const n = pages.value[page.value] ?? 1;
    return recentsSpot(n, geometry.value.rows || 6) ?? placeNewCells(home.value.columns, 1);
  };
  const widgets: { key: string; label: string; desc: string; preview: any; add: () => void }[] = [];
  if (!hasSearchWidget()) {
    widgets.push({
      key: "search",
      label: "search bar",
      desc: "the search pill as a widget: move it anywhere on home",
      preview: <span class="aw-pill-preview">search</span>,
      // A full-width row (the pill is as wide as its cells): the lowest free row of the page on screen.
      add: () => {
        const spot = fullRow();
        powos.home.addPanel("search", spot.page, spot.cell).catch(() => (note.value = "the search widget needs the app updated"));
      },
    });
    widgets.push({
      key: "search-foot",
      label: footBelow.value ? "search above the dock" : "search under the dock",
      desc: footBelow.value ? "the pill back over the dock" : "the pill in home's foot, below the dock",
      preview: <span class={`aw-foot-preview ${footBelow.value ? "" : "below"}`}><i /><span class="aw-pill-preview">search</span></span>,
      add: () => (footBelow.value = footBelow.value ? "" : "1"),
    });
  } else
    widgets.push({
      key: "search",
      label: "search bar",
      desc: "on home now: put it back in the bar",
      preview: <span class="aw-pill-preview">search</span>,
      add: () => void putBackInBar(),
    });
  if (!home.value.items.some((i) => i.key === "panel:agents"))
    widgets.push({
      key: "agents",
      label: "agents",
      desc: "your coding agents: what each is on, asks to allow",
      preview: <span class="aw-glyph">◐ ● ○</span>,
      // The Agents widget: about 4x2 cells, in the first free spot.
      add: () => {
        const cell = innerWidth / home.value.columns;
        const spot = placeNew(4 * cell - 8, 2 * cell - 8);
        powos.home.addPanel("agents", spot.page, spot.cell);
      },
    });
  if (!hasRecentsWidget())
    widgets.push({
      key: "recents",
      label: "recent apps",
      desc: "the apps you opened lately",
      preview: <span class="aw-glyph">▢ ▢ ▢</span>,
      add: () => {
        const spot = fullRow();
        powos.home.addPanel("recents", spot.page, spot.cell);
      },
    });
  const found = widgets.filter((w) => !q || `${w.label} ${w.desc} powos`.includes(q));
  const chip = (label: string, f: () => void) => (
    <button type="button" class="sheet-item" onClick={run(f)}>
      {label}
    </button>
  );
  return (
    <>
      {found.length > 0 && (
        <div class="aw-app">
          <div class="aw-app-head">
            <span class="aw-app-blank" />
            <span>PowOS</span>
          </div>
          <div class="aw-row">
            {found.map((w) => (
              <button type="button" class="aw-provider" key={w.key} onClick={run(w.add)}>
                <span class="aw-preview">{w.preview}</span>
                <span class="aw-label">{w.label}</span>
                <span class="aw-desc muted">{w.desc}</span>
              </button>
            ))}
          </div>
        </div>
      )}
      {!q && (
        <div class="sheet-items">
          {chip(`new widget with ${who}`, () => powos.agents.newWidget())}
          {/* PowOS AI builds a PowOS app in its own chat thread (ui/appbuild.tsx); another agent, in a terminal. */}
          {chip(`new app with ${who}`, () => (agent.value === "PowOS AI" ? startNewApp() : powos.agents.newApp()))}
          {chip("widget store", () => openScreen("store"))}
          {chip("AUR app store", () => openScreen("aur"))}
        </div>
      )}
    </>
  );
}

/** The "+ app" picker: open or not. */
const appPicker = signal(false);

/** On home already: on a page or in a folder (adding it again would move it there). */
const onHome = (app: App) => home.value.items.some((i) => i.app === app.key || i.apps?.some((a) => a.app === app.key));

/**
 * "+ app": the drawer's list and its search (drawer.tsx AppList, bar.tsx Pill: the drawer's own, not a copy). A tap puts
 * that app on the page in view at its first free cell (grid.tsx placeNew: wide home's page too, hosts/wide.ts), and the
 * picker stays open for the next; one at a time, each placed on the layout the last one left.
 */
function AppPicker() {
  const [q, setQ] = useState("");
  const [said, setSaid] = useState("tap apps to add them to this page");
  const queue = useRef(Promise.resolve());
  const mic: MicTarget = { typed: () => q, heard: (full) => setQ(full) };
  const close = () => (dropKeyboard(), (appPicker.value = false));
  const stop = (e: Event) => e.stopPropagation();
  const place = (app: App) =>
    (queue.current = queue.current.then(async () => {
      if (onHome(app)) return setSaid(`${app.label.toLowerCase()} is on home already`);
      const spot = placeNewCells(1, 1);
      await powos.home.add(app.key, spot.page, spot.cell);
      home.value = await powos.home.get();
      navigator.vibrate?.(5);
      setSaid(`added ${app.label.toLowerCase()}`);
    }).catch(() => setSaid(`${app.label.toLowerCase()} wasn't added`)));
  return (
    <div class="aw-scrim" onClick={close} onPointerDown={stop} onTouchStart={stop}>
      <div class="aw-picker app-picker tile sheet" onClick={stop}>
        <div class="sheet-head">
          <span class="muted">{said}</span>
          <button type="button" class="sheet-done" onClick={close}>
            done
          </button>
        </div>
        <div class="drawer shown">
          <AppList found={q.trim() ? findApps(q) : null} onTap={place} />
        </div>
        <Pill target={mic} value={q} onInput={setQ} placeholder="search apps" autocomplete="off" autoCapitalize="off" spellcheck={false} />
      </div>
    </div>
  );
}

/**
 * Edit mode's bar: one slim strip at the foot of the screen, where the search bar and the dock were - "+ widget"
 * (one picker: the shell's widgets, PowOS apps', Android's, the stores, new ones with the agent), the theme (a small
 * popover of swatches, with the settings), done. The pages stay in view and in reach above it.
 */
/**
 * Home's search for this mode (folded / unfolded: state.ts searchPlacement): the pill over the dock, or the dock's
 * centre button that expands into it (docksearch.tsx). Switched at once, nothing reloaded.
 */
function SearchPlace() {
  const place = searchPlacement.value;
  if (!place) return null;
  const pick = (v: string) => () => (place.value = v);
  return (
    <div class="sheet-row search-place">
      <span class="muted">search</span>
      <span class="search-place-pick" role="radiogroup" aria-label="search">
        <button type="button" role="radio" aria-checked={place.value !== "dock"} class={`edit-act ${place.value !== "dock" ? "on" : ""}`} onClick={pick("bar")}>
          bar
        </button>
        <button type="button" role="radio" aria-checked={place.value === "dock"} class={`edit-act ${place.value === "dock" ? "on" : ""}`} onClick={pick("dock")}>
          dock button
        </button>
      </span>
    </div>
  );
}

export function EditSheet() {
  const strip = useRef<HTMLDivElement>(null);
  const open = editing.value;
  useEffect(() => {
    if (!open) return;
    // Fresh each time it opens: themes download and get added, the agent can change.
    themesOpen.value = reopen;
    reopen = false;
    appPicker.value = false;
    powos.theme.list().then((l) => (themes.value = l));
    powos.theme.get().then((t) => (picked.value = t.name));
    powos.agents.default().then((a) => (agent.value = a));
  }, [open]);
  // The picked theme in view, as the Compose strip starts at it.
  useEffect(() => {
    strip.current?.querySelector<HTMLElement>(".swatch.on")?.scrollIntoView({ inline: "center", block: "nearest" });
  }, [themesOpen.value, themes.value.length]);
  // Out of the way while a tile is carried: the whole page is somewhere to drop it. Not for the search widget: the
  // sheet holds the bar's slot, where it's put back (searchwidget.tsx footAimAt).
  if (!open || carriedAway()) return null;
  // The picker in its place while it's open (over home, its own scrolling list).
  if (picker.value) return <AppWidgetPicker onPick={addAppWidget} head={(close, q) => <ShellAdds done={close} q={q} />} />;
  if (appPicker.value) return <AppPicker />;
  const current = themes.value.find((t) => t.name === picked.value);
  const stop = (e: Event) => e.stopPropagation();
  return (
    <>
      {themesOpen.value && (
        <div class="theme-pop tile sheet pop" onPointerDown={stop} onTouchStart={stop}>
          <div class="sheet-row">
            <span class="muted">theme · {current?.title.toLowerCase()}</span>
            <button type="button" class="sheet-done" onClick={() => ((themesOpen.value = false), openScreen("settings"))}>
              settings
            </button>
          </div>
          <SearchPlace />
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
      <div class={`edit-sheet tile ${footAim.value === "bar" ? "drop-here" : ""}`} onPointerDown={stop} onTouchStart={stop}>
        <button type="button" class="edit-act" onClick={() => ((themesOpen.value = false), (note.value = null), (picker.value = true))}>
          + widget
        </button>
        <button type="button" class="edit-act" onClick={() => ((themesOpen.value = false), (note.value = null), (appPicker.value = true))}>
          + app
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
