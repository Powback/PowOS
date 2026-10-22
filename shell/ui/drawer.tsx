/**
 * The drawer: every app A to Z in one grid, no headings or breaks between letters, with an A-Z bar to tap or slide along
 * (as PowOS's start menu; its "#", for names that don't start with a letter, only when there are any), and under it, by
 * the search pill (thumb reach), a fixed row of the apps opened lately. Typing in the bar narrows it to matches, best first. It's the top of the launcher panel, which grows out of
 * the recent apps bar (home.tsx); always mounted, so it follows the finger without rebuilding.
 */
import { useRef, useState } from "preact/hooks";
import { computed } from "@preact/signals";
import { AppCell } from "./apps.tsx";
import { ChatView } from "./chat.tsx";
import { drawerOpen } from "./gesture.ts";
import { apps, byKey, chatting, query, recent, stored } from "../state.ts";
import type { App } from "../types.ts";

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
        <div class={found ? "grid" : "grid az"}>{(found ?? sorted.value.list).map(cell)}</div>
      </div>
      {!found && <LetterBar onPick={jump} />}
    </>
  );
}

export function Drawer() {
  const searching = query.value.trim() !== "";
  // No app by that name: it's a question for PowOS AI. Asked, the chat stays until the search finds apps again.
  const asking = searching ? matches.value.length === 0 : chatting.value;
  const open = drawerOpen.value;
  return (
    // The launcher panel's lower part (home.tsx): it comes in (shell.css, by --p) as the recent bar grows into the panel.
    <div class={`drawer ${open ? "shown" : ""}`} aria-hidden={!open}>
      {asking ? <ChatView /> : <AppList found={searching ? matches.value : null} />}
      {!searching && !asking && <RecentRow />}
    </div>
  );
}
