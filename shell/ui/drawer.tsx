/**
 * The drawer: every app A to Z in one grid, no headings or breaks between letters, with an A-Z bar to tap or slide along
 * (as PowOS's start menu; its "#", for names that don't start with a letter, only when there are any), and under it, by
 * the search pill (thumb reach), a fixed row of the apps opened lately. Typing in the bar narrows it to matches, best first. It's the top of the launcher panel, which grows out of
 * the recent apps bar (home.tsx); always mounted, so it follows the finger without rebuilding.
 */
import { useEffect, useRef, useState } from "preact/hooks";
import { computed } from "@preact/signals";
import { AppCell, AppIcon } from "./apps.tsx";
import { ChatView } from "./chat.tsx";
import { drawerOpen, pageDecision, sampleVx } from "./gesture.ts";
import { apps, byKey, chatting, query, recent, stored } from "../state.ts";
import { library } from "./library.tsx";
import { pendingApp } from "./appbuild.tsx";
import { PendingDetailSheet, PendingIconBadge } from "./pending.tsx";
import type { App } from "../types.ts";

import { searchResults, searchPending, openSearchResult } from "../search.ts";

const ALPHABET = ["#", ..."ABCDEFGHIJKLMNOPQRSTUVWXYZ"];
const collator = new Intl.Collator(undefined, { sensitivity: "base", numeric: true });

/** "Ö" is under O; names that don't start with a letter under "#". */
function heading(label: string) {
  const first = label.trim().normalize("NFD")[0]?.toUpperCase() ?? "";
  return first >= "A" && first <= "Z" ? first : "#";
}

/** Every app A to Z, and where each letter's first app is in that list. */
const sorted = computed(() => {
  const list = [...apps.value].sort((a, b) => collator.compare(a.label, b.label));
  const first = new Map<string, number>();
  list.forEach((app, i) => {
    const h = heading(app.label);
    if (!first.has(h)) first.set(h, i);
  });
  return { list, first };
});

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
  if (drawerRecents.value !== "on") return null;
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
  const { list, first } = sorted.value;
  const start = first.get(letter) ?? list.length;
  const end = Math.min(...[...first.values(), list.length].filter((i) => i > start));
  lit = [...grid.children].slice(start, end);
  for (const el of lit) el.setAttribute("data-lit", "");
}

/** Tap a letter or slide along the bar: the list jumps there at once, every letter the finger crosses. */
function LetterBar({ onPick }: { onPick: (letter: string | null) => void }) {
  // "#" only when some name doesn't start with a letter: a "#" with nothing under it would do nothing.
  const letters = sorted.value.first.has("#") ? ALPHABET : ALPHABET.slice(1);
  const [current, setCurrent] = useState<string | null>(null);
  const bar = useRef<HTMLDivElement>(null);
  const pick = (y: number) => {
    const r = bar.current!.getBoundingClientRect();
    const i = Math.max(0, Math.min(letters.length - 1, Math.floor(((y - r.top) / r.height) * letters.length)));
    if (letters[i] === current) return;
    setCurrent(letters[i]);
    navigator.vibrate?.(5);
    onPick(letters[i]);
  };
  return (
    <div
      class="letter-bar"
      ref={bar}
      style={{ "--letters": letters.length }}
      onPointerDown={(e) => {
        (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
        e.stopPropagation();
        pick(e.clientY);
      }}
      onPointerMove={(e) => e.buttons && pick(e.clientY)}
      onPointerUp={() => (setCurrent(null), onPick(null))}
      onPointerCancel={() => (setCurrent(null), onPick(null))}
    >
      {letters.map((l) => (
        <span class={l === current ? "on" : ""}>{l}</span>
      ))}
      {current && <div class="letter-bubble">{current}</div>}
    </div>
  );
}

/**
 * The drawer's list: every app A to Z with its A-Z bar, or [found] (what's typed matched), best by the pill. The drawer's
 * and the edit bar's "+ app" picker's (ui/editsheet.tsx AppPicker: [onTap] places the app instead of opening it).
 */
export function AppList({ found, onTap }: { found: App[] | null; onTap?: (app: App) => void }) {
  const list = useRef<HTMLDivElement>(null);
  const jump = (letter: string | null) => {
    // Its first app, else the next letter's, else the last letter's. At once: a smooth scroll restarted for every
    // letter a sliding finger crosses lagged behind it.
    const { first } = sorted.value;
    const i = letter == null ? -1 : ALPHABET.indexOf(letter);
    const l = i < 0 ? null : (ALPHABET.slice(i).find((x) => first.has(x)) ?? ALPHABET.findLast((x) => first.has(x)));
    highlight(list.current?.querySelector(".az"), l ?? null);
    const el = l != null ? list.current?.querySelector<HTMLElement>(`.az > :nth-child(${first.get(l)! + 1})`) : null;
    if (el) list.current!.scrollTop += el.getBoundingClientRect().top - list.current!.getBoundingClientRect().top;
  };
  const cell = (app: App) => <AppCell key={app.key} app={app} draggable={!onTap} onTap={onTap && (() => onTap(app))} />;
  return (
    <>
      {/* Searching: by the bar, bottom-up - the best match nearest to it (shell.css .results). */}
      <div class={`drawer-list ${found ? "results" : ""}`} ref={list}>
        {/* A new app being built (ui/appbuild.tsx pendingApp): shown at once, gone the moment it's ready - by then the
            real app is already in [apps] (installedApps -> powosApps -> apps, state.ts), so there's no separate
            "new app" tile to remove, only this one to stop drawing. */}
        {!found && pendingApp.value && pendingApp.value.status !== "done" && <PendingAppCell />}
        <div class={found ? "grid" : "grid az"}>{(found ?? sorted.value.list).map(cell)}</div>
      </div>
      {!found && <LetterBar onPick={jump} />}
    </>
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

/**
 * The drawer's 2nd page: the folders home shows - the user's own, then the app library's (library.tsx, home's last
 * page) - each with its apps (tap to open). It read only the user's own and said "No folders yet" next to a page full
 * of the library's (the user, 2026-10-28).
 */
function FolderView() {
  const folders = library.value.filter((f) => f.apps.length);
  return (
    <div class="drawer-list drawer-folders">
      {!folders.length && <div class="muted folder-empty">No folders yet</div>}
      {folders.map((f) => (
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
function Pages() {
  const track = useRef<HTMLDivElement>(null);
  const [view, setView] = useState(0);
  const s = useRef({ x0: 0, y0: 0, lock: "" as "" | "x" | "y", samples: [] as [number, number][], base: 0 });
  const put = (px: number, ms: number) => {
    const el = track.current;
    if (!el) return;
    el.style.transition = ms ? `transform ${ms}ms cubic-bezier(0.1, 0.8, 0.2, 1)` : "none";
    el.style.transform = `translate3d(${px}px, 0, 0)`;
  };
  const width = () => track.current?.clientWidth || innerWidth;
  useEffect(() => put(-view * width(), 0), []);
  const start = (e: TouchEvent) => {
    const t = e.touches[0];
    const st = s.current;
    st.x0 = t.clientX;
    st.y0 = t.clientY;
    st.lock = (e.target as Element).closest?.(".letter-bar") ? "y" : "";
    st.samples = [[t.clientX, performance.now()]];
  };
  const move = (e: TouchEvent) => {
    const t = e.touches[0];
    const st = s.current;
    const dx = t.clientX - st.x0;
    if (!st.lock && Math.hypot(dx, t.clientY - st.y0) >= 10) st.lock = Math.abs(dx) > Math.abs(t.clientY - st.y0) ? "x" : "y";
    if (st.lock !== "x") return;
    st.samples.push([t.clientX, performance.now()]);
    if (st.samples.length > 12) st.samples.shift();
    const off = (view === 0 && dx > 0) || (view === 1 && dx < 0) ? dx / 3 : dx;
    put(-view * width() + off, 0);
  };
  const end = (e: TouchEvent) => {
    const st = s.current;
    if (st.lock !== "x") return;
    st.lock = "";
    const dx = (e.changedTouches[0]?.clientX ?? st.x0) - st.x0;
    const { dir } = pageDecision(dx, dx, sampleVx(st.samples), width());
    const to = Math.max(0, Math.min(1, view + dir));
    setView(to);
    put(-to * width(), 220);
  };
  return (
    <div class="drawer-pages" data-view={view} onTouchStart={start} onTouchMove={move} onTouchEnd={end} onTouchCancel={end}>
      <div class="drawer-track" ref={track}>
        <div class="drawer-page"><AppList found={null} /></div>
        <div class="drawer-page"><FolderView /></div>
      </div>
    </div>
  );
}

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
  const live = { searching, asking: liveAsking, results: searchResults.value, pending: searchPending.value };
  const { searching: shownSearch, asking, results, pending } = useHeldWhileClosing(open, live);
  return (
    // The launcher panel's lower part (home.tsx): it comes in (shell.css, by --p) as the recent bar grows into the panel.
    <div class={`drawer ${open ? "shown" : ""}`} aria-hidden={!open}>
      {asking ? <ChatView /> : shownSearch ? <div class="drawer-list results"><div class="launcher-search-results">
        {results.map((result) => <button type="button" class="scr-row" key={result.id} data-search-result={result.id} onClick={() => openSearchResult(result)}><SearchIcon icon={result.icon} label={result.label} /><span class="scr-row-text">{result.label}<span class="scr-sub muted">{result.source}</span></span></button>)}
        {pending && <div class="scr-note muted" role="status">Searching…</div>}
      </div></div> : <Pages />}
      {!shownSearch && !asking && <RecentRow />}
    </div>
  );
}

function SearchIcon({ icon, label }: { icon?: string; label: string }) {
  return icon ? <AppIcon src={icon} label={label} /> : <span class="scr-ico" aria-hidden="true">{label.trim().slice(0, 1).toUpperCase()}</span>;
}
