/**
 * The drawer: opened, the launcher's sections (ui/launcherview.ts) - Recent, Suggested, Quick launch - with an A-Z bar to
 * tap or slide along (its "#", for names that don't start with a letter, only when there are any): a letter shows every
 * app under it, A to Z, and stays after the finger lifts until its chip is tapped or the launcher opens again; "All", at
 * the bar's top and foot, shows every app under its letter's heading the same way. Typing in
 * the bar narrows it to matches, best first. It's the top of the launcher panel, which grows out of the recent apps bar
 * (home.tsx); always mounted, so it follows the finger without rebuilding.
 */
import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";
import { computed, effect, signal } from "@preact/signals";
import { memo } from "./memo.ts";
import { alignOf } from "./align.ts";
import { AppCell, AppIcon, dragHome, usePress } from "./apps.tsx";
import { ChatView } from "./chat.tsx";
import { drawerOpen, eventTime, pageDecision, sampleVx } from "./gesture.ts";
import { PageDots, paintDots } from "./pagedots.tsx";
import { apps, byKey, chatting, closeDrawer, launch, menu, powFolder, query, recent, stored } from "../state.ts";
import { library } from "./library.tsx";
import { pendingApp } from "./appbuild.tsx";
import { PendingDetailSheet, PendingIconBadge } from "./pending.tsx";
import type { App, FilePlace } from "../types.ts";
import { powos } from "../bridge.ts";
import { Icon, type IconName } from "./icons.tsx";
import { ALL, ALPHABET, appsOfLetter, launcherApps, launcherView, nextLetter, POW, POW_FOLDER, powGroups, resolveLetter, sortApps, type Group, type LetterEvent, type Sorted } from "./launcherview.ts";

import { searchResults, searchSections, searchPending, openSearchResult, type SearchResult } from "../search.ts";
import { springFast } from "./spring.ts";
import { arrive } from "./notifmotion.ts";
import { tick } from "./haptics.ts";
import { usePresence } from "./reveal.tsx";

const collator = new Intl.Collator(undefined, { sensitivity: "base", numeric: true });

/**
 * The launcher's apps A to Z, and where each letter's first app is in that list: the .pow web apps as one Pow folder
 * (launcherview.ts launcherApps). [plain]: every app loose, for the plain A-Z lists (the "+ app" picker, the desktop
 * panel), which place or open apps one by one.
 */
const sorted = computed(() => sortApps(launcherApps(apps.value, powFolder.value), collator.compare));
const plain = computed(() => sortApps(apps.value, collator.compare));
/** The Pow folder's apps by category, as the launcher shows it open (launcherview.ts powGroups). */
const powView = computed(() => powGroups(apps.value, collator.compare));

/** Matches for what's typed: names starting with it first, then words starting with it, then anywhere in them. */
export const matches = computed(() => findApps(query.value));

/** [matches] for any text: the drawer's search, and the edit bar's "+ app" picker's (ui/editsheet.tsx). */
export function findApps(typed: string) {
  const q = typed.trim().toLowerCase();
  if (!q) return [];
  const rank = (label: string) => {
    const l = label.toLowerCase();
    if (l.startsWith(q)) return 0;
    if (l.split(/\s+/).some((w) => w.startsWith(q))) return 1;
    return l.includes(q) ? 2 : -1;
  };
  return apps.value
    .map((app) => [rank(app.label), app] as const)
    .filter(([r]) => r >= 0)
    .sort((a, b) => a[0] - b[0] || collator.compare(a[1].label, b[1].label))
    .map(([, app]) => app);
}

/**
 * The apps opened lately, newest first (the switcher's and the dock's source): one row - as many as fit across, the
 * rest cut off (shell.css .drawer-recents), so folded and unfolded each get a full row.
 */
/**
 * The drawer's recent row, off by default (Settings > style > home): the grid has the room, and the recent apps are on
 * the dock's second page already. "on" shows it.
 */
export const drawerRecents = stored("drawer.recents", "");

function RecentRow() {
  // The launcher's own Recent section shows them already, but for while a letter is shown.
  if (drawerRecents.value !== "on" || launcherLetter.value == null) return null;
  const shown = recent.value
    .map((k) => byKey.value.get(k))
    .filter((a) => a != null)
    .slice(0, 8);
  if (!shown.length) return null;
  return (
    <div class="grid drawer-recents">
      {shown.map((app) => (
        <AppCell key={app.key} app={app} draggable />
      ))}
    </div>
  );
}

/**
 * While the finger is on the A-Z bar: the cells of the letter it's on stay bright and lift, the rest dim (shell.css
 * .az[data-scrub]). Data attributes, not classes: no glass re-measure (nativeglass observes style/class), and Preact
 * leaves attributes it doesn't own alone. Set per letter change only, never per pointermove; null = released.
 */
let lit: Element[] = [];
function highlight(grid: Element | null | undefined, letter: string | null) {
  for (const el of lit) el.removeAttribute("data-lit");
  lit = [];
  if (!grid || letter == null) return grid?.removeAttribute("data-scrub");
  grid.setAttribute("data-scrub", "");
  const { list, first } = plain.value;
  const start = first.get(letter) ?? list.length;
  const end = Math.min(...[...first.values(), list.length].filter((i) => i > start));
  lit = [...grid.children].slice(start, end);
  for (const el of lit) el.setAttribute("data-lit", "");
}

/** [letter]'s apps' letter in list [s]: its own, else the next letter's, else the last letter's (null: no apps at all). */
const resolve = (letter: string | null, s: Sorted<App> = sorted.value) => resolveLetter(s.first, letter);

/** The apps under [letter] (after [resolve]) in list [s], A to Z. */
const appsOf = (letter: string | null, s: Sorted<App> = sorted.value) => appsOfLetter(s, letter);

/** The launcher's letter (ui/launcherview.ts): null shows its sections; set by the A-Z bar, kept after the lift. */
export const launcherLetter = signal<string | null>(null);
// Peeked, not read: called from an effect (useOpensAtStart) it would subscribe that effect to the app list, and any
// change to it (an icon in, the .pow sync) reset the launcher to its sections under the user's finger.
const letterEvent = (e: LetterEvent) => void (launcherLetter.value = nextLetter(sorted.peek().first, launcherLetter.peek(), e));

/** The apps used most (the host's decayed launch counts): Suggested. Empty (no data, an older APK): hidden. */
const frequent = signal<string[]>([]);
/** The quick launch folders the host can open (FilePlaces.kt). None (another host, an older APK): hidden. */
const places = signal<FilePlace[]>([]);
/** Each open asks again; what's on screen stays until the answer (no blank in between). */
function refreshSections() {
  powos.usage.frequent?.(16).then((v) => void (frequent.value = Array.isArray(v) ? v : [])).catch(() => {});
  powos.files?.places().then((v) => void (places.value = Array.isArray(v) ? v : [])).catch(() => {});
}

/**
 * Experimental (Settings > style > experimental; the user, 11-03: "show the list results when using the alphabet so
 * we can see the full app titles with the results centered on the screen"): while the finger is on the A-Z bar, the
 * letter's apps as a centred list of rows - icon and the whole name, wrapped, never cut. Off by default: off, the bar
 * is as before.
 */
export const azList = stored("drawer.azList", "");

/**
 * The letter's apps, centred over the drawer (not by the bar). [row]: the one at the finger's height once it slid off
 * the bar into the list, lit. A new letter fades its rows in (keyed); it fades in and out itself (usePresence, §6).
 */
function AzOverlay({ letter, row, rows, list }: { letter: string | null; row: number; rows: { current: HTMLDivElement | null }; list: Sorted<App> }) {
  const { on, leaving } = usePresence(letter != null);
  const last = useRef(letter);
  if (letter != null) last.current = letter;
  if (!on || last.current == null) return null;
  const l = last.current;
  return (
    <div class={`az-list${leaving ? " leaving" : ""}`} aria-hidden="true">
      <div class="az-list-card tile sheet">
        <div class="az-list-rows" key={l} ref={rows}>
          {appsOf(l, list).map((app, i) => (
            <div key={app.key} class={`az-list-row${i === row ? " on" : ""}`} data-key={app.key}>
              <AppIcon src={app.icon} label={app.label} app={app.key} />
              <span class="az-list-name">{app.label}</span>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

/**
 * The A-Z list's row under the finger. [at]: off the bar ([off]) while the list shows ([active]), lights the row at
 * height [y] (a tick on each new one) and takes the move (true); on the bar it lets go of the row (false: the bar's).
 */
function useRowPick(active: boolean) {
  const [row, setRow] = useState(-1);
  const ref = useRef<HTMLDivElement>(null);
  const at = (off: boolean, y: number) => {
    if (!active || !off) {
      if (row !== -1) setRow(-1);
      return false;
    }
    const i = [...(ref.current?.children ?? [])].findIndex((el) => {
      const b = el.getBoundingClientRect();
      return y >= b.top && y < b.bottom;
    });
    if (i !== row) {
      setRow(i);
      if (i >= 0) tick();
    }
    return true;
  };
  return { row, ref, at, clear: () => setRow(-1) };
}

/**
 * Tap a letter or slide along the bar: the list jumps there at once, every letter the finger crosses. With [azList]
 * on, the letter's apps show centred (AzOverlay); sliding left off the bar lights the row at the finger's height, and
 * lifting there opens that app ([onOpen]); lifting anywhere else leaves the grid at the letter, as before.
 */
function LetterBar({ onPick, onOpen, ends = false }: { onPick: (letter: string | null) => void; onOpen: (app: App) => void; ends?: boolean }) {
  // The launcher's list ([ends]) or the plain A-Z.
  const list = ends ? sorted.value : plain.value;
  // "#" only when some name doesn't start with a letter: a "#" with nothing under it would do nothing.
  const az = list.first.has("#") ? ALPHABET : ALPHABET.slice(1);
  // [ends] (the launcher): "All" above the first letter and below Z, in reach from either end of the bar.
  const letters = ends ? [ALL, ...az, ALL] : az;
  const [current, setCurrent] = useState<string | null>(null);
  const bar = useRef<HTMLDivElement>(null);
  const listOn = azList.value === "on";
  const pick = (y: number) => {
    const r = bar.current!.getBoundingClientRect();
    const i = Math.max(0, Math.min(letters.length - 1, Math.floor(((y - r.top) / r.height) * letters.length)));
    if (letters[i] === current) return;
    setCurrent(letters[i]);
    tick();
    onPick(letters[i]);
  };
  const rows = useRowPick(listOn && current != null && current !== ALL);
  const move = (x: number, y: number) => {
    // Off the bar (left of it) with the list showing: the letter holds, the finger picks a row by its height.
    if (!rows.at(x < bar.current!.getBoundingClientRect().left, y)) pick(y);
  };
  const end = (open: boolean) => {
    const app = open && rows.row >= 0 ? appsOf(resolve(current, list), list)[rows.row] : null;
    setCurrent(null);
    rows.clear();
    onPick(null);
    if (app) onOpen(app);
  };
  return (
    <>
      <div
        class="letter-bar"
        ref={bar}
        style={{ "--letters": letters.length }}
        onPointerDown={(e) => {
          (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
          e.stopPropagation();
          pick(e.clientY);
        }}
        onPointerMove={(e) => e.buttons && move(e.clientX, e.clientY)}
        onPointerUp={() => end(true)}
        onPointerCancel={() => end(false)}
      >
        {letters.map((l) => (
          <span class={`${l === current ? "on" : ""}${l === ALL ? " all" : ""}`}>{l}</span>
        ))}
        {current && <div class={`letter-bubble${current === ALL ? " all" : ""}`}>{current}</div>}
      </div>
      {listOn && <AzOverlay letter={resolve(current, list)} row={rows.row} rows={rows.ref} list={list} />}
    </>
  );
}

/** A lift on a row of the A-Z list: the app, opened as a tap on its cell does (AppCell). */
const openApp = (app: App) => void launch(app.key);

/**
 * The drawer's list: every app A to Z with its A-Z bar, or [found] (what's typed matched), best by the pill. The drawer's
 * and the edit bar's "+ app" picker's (ui/editsheet.tsx AppPicker: [onTap] places the app instead of opening it).
 */
export function AppList({ found, onTap, sections = false }: { found: App[] | null; onTap?: (app: App) => void; sections?: boolean }) {
  const list = useRef<HTMLDivElement>(null);
  // The launcher (sections): the bar picks what shows - the letter's apps, from the top - and the lift keeps it.
  const show = (letter: string | null) => {
    letterEvent(letter == null ? { type: "release" } : { type: "scrub", letter });
    if (list.current) list.current.scrollTop = 0;
  };
  const jump = (letter: string | null) => {
    // Its first app, else the next letter's, else the last letter's. At once: a smooth scroll restarted for every
    // letter a sliding finger crosses lagged behind it.
    const { first } = plain.value;
    const l = resolve(letter, plain.value);
    highlight(list.current?.querySelector(".az"), l);
    const el = l != null ? list.current?.querySelector<HTMLElement>(`.az > :nth-child(${first.get(l)! + 1})`) : null;
    if (el) list.current!.scrollTop += el.getBoundingClientRect().top - list.current!.getBoundingClientRect().top;
  };
  useOpensAtStart(list, found, sections);
  // The Pow folder's cell (the launcher's only) opens it in place.
  const cell = (app: App) => <AppCell key={app.key} app={app} draggable={!onTap} onTap={app.key === POW_FOLDER ? openPow : onTap} />;
  return (
    <>
      {/* Searching: by the bar, bottom-up - the best match nearest to it (shell.css .results). */}
      <div class={`drawer-list ${found ? "results" : ""}`} ref={list}>
        <ListBody found={found} sections={sections} cell={cell} />
      </div>
      {!found && <LetterBar onPick={sections ? show : jump} onOpen={onTap ?? openApp} ends={sections} />}
    </>
  );
}

/**
 * Every open starts at the list's start - the first section in view - whatever the alignment (ui/align.ts). Bottom
 * alignment places a grid shorter than the panel at its foot (shell.css "Alignment"), near the thumb; it never means
 * scrolled to the last app - opening at Z every time was the bug (the user, 11-01: "Why is the launcher always
 * scrolled to bottom when I open it?"). Search results keep their own bottom-up start (Results below). The launcher
 * ([sections]) also goes back to its sections and asks for fresh suggestions and places on each open.
 * Watched, not read in render: a read re-rendered the list (and its every cell's comparison) on each drag's start - the
 * drawer shows (drawerOpen) at the first touchmove (device 11-02 18:13: that move 107 ms of script).
 */
function useOpensAtStart(list: { current: HTMLDivElement | null }, found: App[] | null, sections: boolean) {
  const showsAll = useRef(!found);
  showsAll.current = !found;
  useEffect(
    () =>
      effect(() => {
        if (!drawerOpen.value) return;
        if (sections) {
          letterEvent({ type: "open" });
          refreshSections();
        }
        if (showsAll.current && list.current) list.current.scrollTop = 0;
      }),
    [],
  );
  useLayoutEffect(() => {
    if (drawerOpen.peek() && !found && list.current) list.current.scrollTop = 0;
  }, [!found]);
}

/** The list's content: [found], the launcher's sections, or every app A to Z - after a new app being built, if any. */
function ListBody({ found, sections, cell }: { found: App[] | null; sections: boolean; cell: (app: App) => preact.JSX.Element }) {
  if (found) return <div class="grid">{found.map(cell)}</div>;
  return (
    <>
      {/* A new app being built (ui/appbuild.tsx pendingApp): shown at once, gone the moment it's ready - by then the
          real app is already in [apps] (installedApps -> powosApps -> apps, state.ts), so there's no separate
          "new app" tile to remove, only this one to stop drawing. */}
      {pendingApp.value && pendingApp.value.status !== "done" && <PendingAppCell />}
      {sections ? <Sections cell={cell} /> : <div class="grid az">{plain.value.list.map(cell)}</div>}
    </>
  );
}

/** The Pow folder's cell tapped: its apps in the launcher, under a "Pow" chip as a letter's, from the top. */
function openPow() {
  launcherLetter.value = POW;
  tick();
  const list = document.querySelector(".drawer-page .drawer-list");
  if (list) list.scrollTop = 0;
}

/** The chip over a letter's (or All's) apps: a tap goes back to the sections. */
function LetterChip({ label }: { label: string }) {
  return (
    <button type="button" class="launcher-chip" aria-label="Back to recent apps" onClick={() => letterEvent({ type: "clear" })}>
      <span class="launcher-chip-letter">{label}</span>
      <Icon name="close" size={14} />
    </button>
  );
}

/**
 * The launcher's content (ui/launcherview.ts launcherView): the letter's apps under its chip (tap: back to the
 * sections), or Recent / Suggested / Quick launch - each hidden when empty - or every app under its letter's heading
 * (All picked on the bar, under its chip; or neither recent nor suggested apps). The grids keep `.grid.az`: the A-Z
 * jump, the align and geometry checks find them.
 */
function Sections({ cell }: { cell: (app: App) => preact.JSX.Element }) {
  const v = launcherView({ searching: false, letter: launcherLetter.value, sorted: sorted.value, byKey: byKey.value, recent: recent.value, frequent: frequent.value, pow: powView.value });
  if (v.kind === "folder") return <PowSection groups={v.groups} cell={cell} />;
  if (v.kind === "letter") {
    return (
      <section class="launcher-section" data-view="letter" data-letter={v.letter}>
        <LetterChip label={v.letter} />
        <div class="grid az" key={v.letter}>{v.apps.map(cell)}</div>
      </section>
    );
  }
  if (v.kind === "all") {
    return (
      <div class="launcher-sections" data-view="all" data-letter={v.picked ? ALL : undefined}>
        {v.picked && <LetterChip label={ALL} />}
        {v.groups.map((g) => (
          <section class="launcher-section" key={g.letter} data-group={g.letter}>
            <h3 class="heading">{g.letter}</h3>
            <div class="grid az">{g.apps.map(cell)}</div>
          </section>
        ))}
      </div>
    );
  }
  if (v.kind !== "sections") return null;
  return (
    <div class="launcher-sections" data-view="sections">
      <section class="launcher-section" data-section="recent">
        <h3 class="heading">Recent</h3>
        <div class="grid az">{v.recent.map(cell)}</div>
      </section>
      {v.suggested.length > 0 && (
        <section class="launcher-section" data-section="suggested">
          <h3 class="heading">Suggested</h3>
          <div class="grid">{v.suggested.map(cell)}</div>
        </section>
      )}
      <QuickLaunch />
    </div>
  );
}

/**
 * The Pow folder open in the launcher: its apps under their categories (the user-facing ones first, "infrastructure"
 * last; one category alone: no heading), each with its kind mark (apps.tsx WebMark), under the "Pow" chip.
 */
function PowSection({ groups, cell }: { groups: Group<App>[]; cell: (app: App) => preact.JSX.Element }) {
  const headed = groups.length > 1;
  return (
    <div class="launcher-sections" data-view="folder" data-folder={POW_FOLDER}>
      <LetterChip label={POW} />
      {groups.map((g) => (
        <section class="launcher-section" key={g.letter} data-group={g.letter}>
          {headed && <h3 class="heading">{g.letter}</h3>}
          <div class="grid az">{g.apps.map(cell)}</div>
        </section>
      ))}
    </div>
  );
}

/** Each place's icon (ui/icons.tsx); a place it doesn't know: a folder. */
const PLACE_ICONS: Record<string, IconName> = {
  downloads: "trayArrowDown",
  documents: "fileDocumentOutline",
  camera: "cameraOutline",
  pictures: "imageOutline",
  music: "musicNote",
  linux: "penguin",
};

/**
 * Quick launch: the phone's folders (Downloads, Documents, Camera, Pictures, Music) in its Files app and the Linux home
 * folder in PowOS's - only those the host says open here (FilePlaces.kt). A tap closes the launcher as an app's does; one
 * that didn't open after all leaves the list.
 */
function QuickLaunch() {
  if (!places.value.length) return null;
  const open = (p: FilePlace) => {
    closeDrawer(true);
    powos.files?.open(p.id).then((ok) => void (ok || (places.value = places.value.filter((x) => x.id !== p.id)))).catch(() => {});
  };
  return (
    <section class="launcher-section" data-section="places">
      <h3 class="heading">Quick launch</h3>
      <div class="grid">
        {places.value.map((p) => (
          <div class="app place" key={p.id} data-place={p.id} role="button" onClick={() => open(p)}>
            <div class="app-icon place-icon" aria-hidden="true">
              <Icon name={PLACE_ICONS[p.id] ?? "folderOutline"} size={26} />
            </div>
            <div class="app-label">{p.label}</div>
          </div>
        ))}
      </div>
    </section>
  );
}

/** The drawer's placeholder for an app PowOS AI is building: a generic icon with a progress ring, tap for the being-built view. */
function PendingAppCell() {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  const state = pendingApp.value;
  if (!state) return null;
  return (
    <div class="app pending-app" ref={ref} onClick={() => setOpen(true)}>
      <PendingIconBadge state={state}>
        <div class="app-icon initials" aria-hidden="true">
          +
        </div>
      </PendingIconBadge>
      <div class="app-label">{state.status === "failed" ? "couldn't build" : "building…"}</div>
      {open && <PendingDetailSheet anchor={ref.current} state={state} onClose={() => setOpen(false)} />}
    </div>
  );
}

/** The folders home shows - the user's own, then the app library's (library.tsx, home's last page) - with apps in them. */
const shownFolders = computed(() => library.value.filter((f) => f.apps.length));

/**
 * The drawer's 2nd page: [shownFolders], each with its apps (tap to open). It read only the user's own and said "No
 * folders yet" next to a page full of the library's (the user, 2026-10-28). With none there is no 2nd page at all
 * (Pages), never a "No folders yet" line (DESIGN-LANGUAGE.md §1: empty states hide).
 */
function FolderView() {
  return (
    <div class="drawer-list drawer-folders">
      {shownFolders.value.map((f) => (
        <section key={f.key}>
          <h3 class="heading">{f.name}</h3>
          <div class="grid">
            {f.apps.map((a) => {
              const app = byKey.value.get(a.app);
              return app ? <AppCell key={a.key} app={app} draggable /> : null;
            })}
          </div>
        </section>
      ))}
    </div>
  );
}

/**
 * All apps | folders as two pages that swipe sideways under the finger, deciding like the home pager (gesture.ts
 * pageDecision: 30% or a flick, release velocity over the last 50 ms). Transform only (translate3d). Home's own gesture
 * drops sideways moves while the drawer is open, so these touch events are the drawer's alone.
 */
const Pages = memo(function Pages() {
  const track = useRef<HTMLDivElement>(null);
  const dots = useRef<HTMLDivElement>(null);
  const [view, setView] = useState(0);
  // The folders page only when it has folders (FolderView): one page alone, no dots and no sideways swipe.
  const last = shownFolders.value.length ? 1 : 0;
  const s = useRef({ x0: 0, y0: 0, lock: "" as "" | "x" | "y", samples: [] as [number, number][], base: 0 });
  const put = (px: number, ms: number) => {
    const el = track.current;
    if (!el) return;
    el.style.transition = ms ? `transform ${ms}ms ${springFast.easing}` : "none";
    el.style.transform = `translate3d(${px}px, 0, 0)`;
    // The dots under the finger too: where the track is, in pages (ms 0 = a finger on it).
    paintDots(dots.current, Math.max(0, Math.min(1, -px / width())), !ms);
  };
  const width = () => (track.current ? track.current.clientWidth + (parseFloat(getComputedStyle(track.current).columnGap) || 0) : 0) || innerWidth;
  useEffect(() => put(-view * width(), 0), []);
  // The folders went while their page was shown: back to the apps, on the spring.
  useEffect(() => void (view > last && (setView(last), put(-last * width(), springFast.ms))), [last]);
  const start = (e: TouchEvent) => {
    const t = e.touches[0];
    const st = s.current;
    st.x0 = t.clientX;
    st.y0 = t.clientY;
    st.lock = (e.target as Element).closest?.(".letter-bar") ? "y" : "";
    st.samples = [[t.clientX, eventTime(e)]];
  };
  const move = (e: TouchEvent) => {
    const t = e.touches[0];
    const st = s.current;
    const dx = t.clientX - st.x0;
    if (!st.lock && Math.hypot(dx, t.clientY - st.y0) >= 10) st.lock = Math.abs(dx) > Math.abs(t.clientY - st.y0) ? "x" : "y";
    if (st.lock !== "x") return;
    st.samples.push([t.clientX, eventTime(e)]);
    if (st.samples.length > 12) st.samples.shift();
    const off = (view === 0 && dx > 0) || (view === last && dx < 0) ? dx / 3 : dx;
    put(-view * width() + off, 0);
  };
  const end = (e: TouchEvent) => {
    const st = s.current;
    if (st.lock !== "x") return;
    st.lock = "";
    const dx = (e.changedTouches[0]?.clientX ?? st.x0) - st.x0;
    const { dir } = pageDecision(dx, dx, sampleVx(st.samples, eventTime(e)), width());
    const to = Math.max(0, Math.min(last, view + dir));
    setView(to);
    put(-to * width(), springFast.ms);
  };
  return (
    <>
      <div class="drawer-pages" data-view={view} onTouchStart={start} onTouchMove={move} onTouchEnd={end} onTouchCancel={end}>
        <div class="drawer-track" ref={track}>
          <div class="drawer-page"><AppList found={null} sections /></div>
          {last > 0 && <div class="drawer-page"><FolderView /></div>}
        </div>
      </div>
      {/* Beside the pages, not in them: their clip-path cut the dots off at the pages' foot. */}
      {last > 0 && <PageDots count={2} dotsRef={dots} />}
    </>
  );
});

/** How long a closing drawer keeps what it showed: the close's fade (shell.css [data-p] and gesture.ts SETTLE_MS, 180 ms) and a frame. */
const CLOSE_HOLD_MS = 200;

/** [live] while open; once it closes, what it last showed while open, for CLOSE_HOLD_MS - then [live] again. */
function useHeldWhileClosing<T>(open: boolean, live: T): T {
  const last = useRef(live);
  const holding = useRef(false);
  const wasOpen = useRef(open);
  const [, tick] = useState(0);
  holding.current = !open && (holding.current || wasOpen.current);
  wasOpen.current = open;
  if (open) last.current = live;
  const held = holding.current;
  useEffect(() => {
    if (!held) return;
    const t = setTimeout(() => {
      holding.current = false;
      tick((n) => n + 1);
    }, CLOSE_HOLD_MS);
    return () => clearTimeout(t);
  }, [held]);
  return held ? last.current : live;
}

export function Drawer() {
  const searching = query.value.trim() !== "";
  // No app by that name: it's a question for PowOS AI. In a chat, typing is the next message: the chat stays (the user,
  // 2026-10-28: it flipped to search results while typing a follow-up) until the launcher closes.
  const liveAsking = chatting.value || (searching && searchResults.value.length === 0 && !searchPending.value);
  const open = drawerOpen.value;
  // Closing clears the search and ends the chat (state.ts closeDrawer) at once: the panel swapped to the app pages
  // under its fade, and the cards it showed vanished instead of fading out as they faded in (the user, 2026-10-28).
  // What was on screen stays for the close's fade (--p, 180 ms), then the drawer goes back to its pages.
  const live = { searching, asking: liveAsking, sections: searchSections.value, pending: searchPending.value };
  const { searching: shownSearch, asking, sections, pending } = useHeldWhileClosing(open, live);
  return (
    // The launcher panel's lower part (home.tsx): it comes in (shell.css, by --p) as the recent bar grows into the panel.
    <div class={`drawer ${open ? "shown" : ""}`} aria-hidden={!open}>
      {asking ? <ChatView /> : shownSearch ? <SearchResults sections={sections} pending={pending} /> : <Pages />}
      {!shownSearch && !asking && <RecentRow />}
    </div>
  );
}

/**
 * The launcher's search results. Bottom-aligned (ui/align.ts, the bar at the foot) they read bottom-up, the best match
 * nearest the bar (the manager, E2E 194): the apps' tiles just over it, the settings and actions cards above them, the
 * best group lowest - and the list opens scrolled to its foot. Top or middle: the apps first, as before.
 */
function SearchResults({ sections, pending }: { sections: typeof searchSections.value; pending: boolean }) {
  const list = useRef<HTMLDivElement>(null);
  const seen = useRef(new WeakSet<Element>());
  const bottomUp = alignOf("launcher") === "bottom";
  useLayoutEffect(() => {
    if (bottomUp && list.current) list.current.scrollTop = list.current.scrollHeight;
  }, [bottomUp, sections]);
  // What each keystroke brings in fades and slides in on the spring, nearest the bar first (notifmotion.ts arrive);
  // rows already there stay put. Never in one frame (DESIGN-LANGUAGE.md §6).
  useLayoutEffect(() => {
    const all = [...(list.current?.querySelectorAll(ARRIVALS) ?? [])];
    const fresh = all.filter((el) => !seen.current.has(el) && !el.parentElement?.closest(".search-group:not([data-seen])"));
    for (const el of all) seen.current.add(el);
    arrive(bottomUp ? fresh.reverse() : fresh);
    for (const g of list.current?.querySelectorAll(".search-group") ?? []) g.setAttribute("data-seen", "");
  });
  const appTiles = sections.apps.map((result) => <AppResultRow key={result.id} result={result} />);
  // Settings and app actions: a list under the app each comes from, each name whole (the user, 2026-10-30: "I should
  // be able to see the whole line like hey this app has these controls").
  const groups = (bottomUp ? [...sections.groups].reverse() : sections.groups).map((group) => <section class="search-group" key={group.id} data-search-group={group.id}>
    <div class="search-group-head"><SearchIcon icon={group.icon} label={group.label} /><span class="search-group-name">{group.label}</span></div>
    {group.items.map((result) => <SearchRow key={result.id} result={result} />)}
  </section>);
  const note = pending && <div class="scr-note muted" role="status">Searching…</div>;
  return (
    <div class="drawer-list results" ref={list} data-order={bottomUp ? "bottom-up" : "top-down"}><div class="launcher-search-results">
      {bottomUp ? <>{note}{groups}{appTiles}</> : <>{appTiles}{groups}{note}</>}
    </div></div>
  );
}

/**
 * An app among the search results: a tap opens it; held, its menu; held and moved, the launcher's one drag (apps.tsx
 * dragHome - onto home, or over an app into a window, as every launcher tile). Rows that aren't an installed app: a tap.
 */
function AppResultRow({ result }: { result: SearchResult }) {
  const app = result.id.startsWith("app:") ? byKey.value.get(result.id.slice(4)) : undefined;
  // The click opens it (a tap, Enter, a check's .click()); not the click that ends a hold - that one was the menu's.
  const held = useRef(false);
  const press = usePress(
    () => {},
    (el) => {
      held.current = true;
      if (app) menu.value = { app, at: el.getBoundingClientRect() };
    },
    app ? (e) => dragHome(app.key, e) : null,
  );
  const down = press.onPointerDown;
  const open = () => (held.current ? void (held.current = false) : openSearchResult(result));
  return (
    <button type="button" class="scr-row" data-search-result={result.id} data-key={app?.key} {...press} onPointerDown={(e) => ((held.current = false), down(e))} onClick={open}>
      <SearchIcon icon={result.icon} label={result.label} />
      <span class="scr-row-text">{result.label}<span class="scr-sub muted">{result.source}</span></span>
    </button>
  );
}

/** The search results' pieces that arrive: an app's row, a group (with its rows), a group's new row, the note. */
const ARRIVALS = ".scr-row, .search-group, .search-group-row, .scr-note";

function SearchRow({ result }: { result: SearchResult }) {
  return (
    <button type="button" class="search-group-row" data-search-result={result.id} onClick={() => openSearchResult(result)}>
      <span class="search-group-label">{result.label}</span>
      {result.detail && <span class="search-group-detail">{result.detail}</span>}
    </button>
  );
}

function SearchIcon({ icon, label }: { icon?: string; label: string }) {
  return icon ? <AppIcon src={icon} label={label} /> : <span class="scr-ico" aria-hidden="true">{label.trim().slice(0, 1).toUpperCase()}</span>;
}
