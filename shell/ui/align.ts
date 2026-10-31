/**
 * The theme's alignment, per surface (Settings > style > alignment; the user, 2026-10-31 15:42-15:43: "make this bar
 * bottom aligned ... in unfolded mode. Same with the control center and the notifications ... maybe this should be
 * like a setting in the theme: bottom aligned, middle aligned, top aligned"). Three surfaces - the launcher (its app
 * grid and A-Z bar), the notifications, the control center - each with its own choice folded and unfolded:
 * - "top": as before (the grid from the top, the A-Z bar centred; the cards under their header; folded the control
 *   center's card on top, unfolded its body centred under its header - 10-29's "centered vertically").
 * - "middle": the content centred in the surface.
 * - "bottom": the content stacks from the surface's foot up - the grid's last row and the A-Z bar's end just over the
 *   search bar, the newest notification nearest the thumb, the control center's tiles low - and scrolls up for more.
 * Unset, unfolded is bottom and folded top (a coded default: stored() never writes it, so a later default can change).
 * Shown as html[data-align-<surface>] - CSS only (shell.css "Alignment"), applied live; the other pages (the shade, the
 * launcher over an app) follow a pick on home through the storage event, no reload.
 */
import { computed, effect, signal } from "@preact/signals";
import { dockMode, stored } from "../state.ts";

export type Align = "top" | "middle" | "bottom";
export const ALIGNS: Align[] = ["top", "middle", "bottom"];
export type AlignSurface = "launcher" | "shade" | "control";
export type AlignMode = "folded" | "unfolded";

/**
 * Unfolded for the shade (wider than the cover's 404, as hosts/wide.ts's 700): two columns side by side - the
 * notifications left, the control center right, each its own scroll. Folded it stays the one stacked list.
 */
export const wideShade = signal(innerWidth >= 700);
addEventListener("resize", () => (wideShade.value = innerWidth >= 700));

const DEFAULT: Record<AlignMode, Align> = { folded: "top", unfolded: "bottom" };
const key = (s: AlignSurface, m: AlignMode) => `align.${s}.${m}`;
const own = Object.fromEntries(
  (["launcher", "shade", "control"] as AlignSurface[]).flatMap((s) => (["folded", "unfolded"] as AlignMode[]).map((m) => [key(s, m), stored(key(s, m), "")])),
);
// A pick on another page (Settings is home's): this page's copy at once.
addEventListener("storage", (e) => {
  const k = e.key?.replace(/^powos\./, "");
  if (k && own[k]) own[k].value = e.newValue ?? "";
});

const valid = (v: string, m: AlignMode): Align => ((ALIGNS as string[]).includes(v) ? (v as Align) : DEFAULT[m]);
/** [s]'s choice for [m], the default while unset (what the settings show and set). */
export const alignChoice = (s: AlignSurface, m: AlignMode) => ({
  get value(): Align {
    return valid(own[key(s, m)].value, m);
  },
  set value(v: Align) {
    own[key(s, m)].value = v;
  },
});
/** The mode a surface is in now: the launcher follows home's (dockMode), the shade its own two-column width. */
const modeOf = (s: AlignSurface): AlignMode => ((s === "launcher" ? dockMode.value !== "mobile" : wideShade.value) ? "unfolded" : "folded");
/** A check's choice for this page only, never stored (as state.ts dockTry). */
export const alignTry = signal<Partial<Record<AlignSurface, Align>>>({});
export const alignOf = (s: AlignSurface) => alignTry.value[s] ?? alignChoice(s, modeOf(s)).value;
const shown = computed(() => (["launcher", "shade", "control"] as AlignSurface[]).map((s) => [s, alignOf(s)] as const));
effect(() => {
  for (const [s, a] of shown.value) document.documentElement.dataset[`align${s[0].toUpperCase()}${s.slice(1)}`] = a;
});
