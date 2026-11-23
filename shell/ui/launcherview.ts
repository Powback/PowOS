/**
 * What the launcher's app pages show (ui/drawer.tsx AppList; the user, 11-23: "It should show the recent apps by default
 * and then if you use the sorter thing it shifts to show all apps filtered to the letter you are using", then "maybe it
 * should be recent, suggested, and then ... other quick launch options like ... file locations"). Pure: no signals, no
 * DOM, so node --test checks it (shell/test/launcherview.test.ts).
 *
 * - Opened: sections - Recent (the recent apps, newest first), Suggested (the most used apps Recent doesn't show; none
 *   without usage data: hidden, never filler), and the quick launch places (drawer.tsx QuickLaunch).
 * - A-Z bar touched: every app under that letter (the letter itself, else the next letter with apps), and it stays on
 *   that letter after the finger lifts, until the letter's chip is tapped or the launcher opens again.
 * - "All" at both ends of the A-Z bar (the user, 11-23: "the launcher sorter should have an option to show all on the top
 *   and bottom of the sorter"): every app A to Z under its letter's heading, kept after the lift under an "All" chip like a
 *   letter's; sliding on from it onto a letter shows that letter, live.
 * - Search (anything typed) overrides both: the drawer shows its results (drawer.tsx Drawer).
 * - No recent and no suggested apps (a fresh phone): all apps A to Z, as before, never an empty page.
 */

export const ALPHABET = ["#", ..."ABCDEFGHIJKLMNOPQRSTUVWXYZ"];
/** The A-Z bar's entry at its top and its foot: every app (launcherView "all", picked). */
export const ALL = "All";
/** Recent: two rows folded (4 across), and Suggested one row - compact, so the sections fit above the pill. */
export const RECENT_MAX = 8;
export const SUGGESTED_MAX = 4;

type Named = { key: string; label: string };

/** "Ö" is under O; names that don't start with a letter under "#". */
export function heading(label: string) {
  const first = label.trim().normalize("NFD")[0]?.toUpperCase() ?? "";
  return first >= "A" && first <= "Z" ? first : "#";
}

/** Apps A to Z, and where each letter's first app is in that list. */
export interface Sorted<T> {
  list: T[];
  first: Map<string, number>;
}

export function sortApps<T extends Named>(apps: readonly T[], compare: (a: string, b: string) => number): Sorted<T> {
  const list = [...apps].sort((a, b) => compare(a.label, b.label));
  const first = new Map<string, number>();
  list.forEach((app, i) => {
    const h = heading(app.label);
    if (!first.has(h)) first.set(h, i);
  });
  return { list, first };
}

/** [letter]'s apps' letter: its own, else the next letter's, else the last letter's (null: no apps at all). */
export function resolveLetter(first: Map<string, number>, letter: string | null) {
  const i = letter == null ? -1 : ALPHABET.indexOf(letter);
  return i < 0 ? null : (ALPHABET.slice(i).find((x) => first.has(x)) ?? ALPHABET.findLast((x) => first.has(x)) ?? null);
}

/** The apps under [letter] (already resolved), A to Z. */
export function appsOfLetter<T>({ list, first }: Sorted<T>, letter: string | null): T[] {
  if (letter == null || !first.has(letter)) return [];
  const start = first.get(letter)!;
  return list.slice(start, Math.min(...[...first.values(), list.length].filter((i) => i > start)));
}

/** What moves the launcher's letter: it opened, a finger on the bar at a letter, the finger lifted, the chip tapped. */
export type LetterEvent = { type: "open" } | { type: "scrub"; letter: string } | { type: "release" } | { type: "clear" };

/** The letter shown after [e] (null: the sections). A letter with no apps resolves as the bar's jump always did. */
export function nextLetter(first: Map<string, number>, shown: string | null, e: LetterEvent): string | null {
  switch (e.type) {
    case "scrub":
      return e.letter === ALL ? ALL : (resolveLetter(first, e.letter) ?? shown);
    case "release":
      return shown;
    default:
      return null;
  }
}

export type LauncherView<T> =
  | { kind: "search" }
  | { kind: "letter"; letter: string; apps: T[] }
  | { kind: "sections"; recent: T[]; suggested: T[] }
  | { kind: "all"; apps: T[]; groups: Group<T>[]; picked: boolean };

/** One letter's heading and its apps, A to Z. */
export interface Group<T> {
  letter: string;
  apps: T[];
}

/** Every app under its letter's heading, the letters in the bar's order. */
export function groupApps<T>(sorted: Sorted<T>): Group<T>[] {
  return ALPHABET.filter((l) => sorted.first.has(l)).map((letter) => ({ letter, apps: appsOfLetter(sorted, letter) }));
}

/** The launcher's pages' content for its state: [recent] and [frequent] are keys, newest / most used first. */
export function launcherView<T extends Named>(s: {
  searching: boolean;
  letter: string | null;
  sorted: Sorted<T>;
  byKey: ReadonlyMap<string, T>;
  recent: readonly string[];
  frequent: readonly string[];
}): LauncherView<T> {
  if (s.searching) return { kind: "search" };
  const all = (picked: boolean) => ({ kind: "all" as const, apps: s.sorted.list, groups: groupApps(s.sorted), picked });
  if (s.letter === ALL) return all(true);
  const apps = s.letter == null ? [] : appsOfLetter(s.sorted, s.letter);
  if (s.letter != null && apps.length) return { kind: "letter", letter: s.letter, apps };
  const known = (keys: readonly string[]) => [...new Set(keys)].map((k) => s.byKey.get(k)).filter((a): a is T => a != null);
  const recent = known(s.recent).slice(0, RECENT_MAX);
  const shown = new Set(recent.map((a) => a.key));
  const suggested = known(s.frequent)
    .filter((a) => !shown.has(a.key))
    .slice(0, SUGGESTED_MAX);
  if (!recent.length && !suggested.length) return all(false);
  return { kind: "sections", recent, suggested };
}
