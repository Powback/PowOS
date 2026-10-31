/**
 * PI1 (the user, 2026-10-31 01:34-01:35: "Certain pages are active on that page. I should see it more clearly on the
 * docking. and like the recent bar ... maybe the other icons should be faded out a little bit"): each app's mark in
 * the dock and its recent apps, by where its windows are against the home page on screen.
 *   "here" - a window showing on the page on screen (not minimised): a wide bright pill, the icon at full opacity;
 *   "away" - running, but only on another page, minimised, or as a task with no window here: a small dim dot.
 *   none   - not running: nothing.
 * With any app "here", every other dock icon fades a little (shell.css .dock.page-focus); with none, nothing fades.
 * Both kinds of window count: Android/Linux floating windows (state.ts windows, their pages ui/desktops.ts placed) and
 * web windows (ui/webwindows.tsx webWins, read only). Folded no window lists: running apps get the dot, nothing fades.
 */
import { computed } from "@preact/signals";
import { windows } from "../state.ts";
import { appOf, pageId, placed } from "./desktops.ts";
import { running } from "./running.ts";
import { webWins } from "./webwindows.tsx";

export type PageMark = "here" | "away";

// The last value, kept while equal: a window's move or resize changes webWins every frame, the marks only when an
// app comes to or leaves the page (the dock's cells re-render on a new Map otherwise - render scan 10-30).
let last = new Map<string, PageMark>();

/** App key -> its mark; an app not in it isn't running. */
export const pageMarks = computed(() => {
  const cur = pageId();
  const out = new Map<string, PageMark>();
  const mark = (key: string | undefined, here: boolean) => {
    if (!key) return;
    if (here) out.set(key, "here");
    else if (!out.has(key)) out.set(key, "away");
  };
  for (const w of windows.value) mark(appOf(w), !w.minimised && !w.away && (placed.value[w.id] ?? cur) === cur);
  for (const w of webWins.value) mark(w.key, !w.minimised && w.page === cur);
  for (const key of Object.keys(running.value)) mark(key, false);
  if (out.size === last.size && [...out].every(([k, v]) => last.get(k) === v)) return last;
  return (last = out);
});

/** Some app has a window on the page on screen: the dock's other icons fade. */
export const pageFocus = computed(() => [...pageMarks.value.values()].includes("here"));

/** The class an app cell takes for its mark ("" when it has none). */
export const markClass = (key: string) => {
  const m = pageMarks.value.get(key);
  return m ? `mark-${m}` : "";
};
