/**
 * The lock face as the user set it up (lockedit.tsx; the store's "lock.face", kept on this phone: the shell's store has
 * no account sync - the account's sync is an app's own SpacetimeDB tables, lib/apps/powos-account-sync): the clock's
 * font, weight and colour (theme tokens, so a theme change still reads), the lock's own backdrop over the wallpaper
 * (separate from home's), which glance items show, and the two corner shortcuts.
 *
 * One clock style for every clock face: the lock face, the screen-off display (aod.tsx) and StandBy (standby.tsx) all
 * take clockVars() - the font and weight everywhere, the colour on the lock and the AOD (StandBy keeps its accent: its
 * night red must win). Each page reads the store as it is shown (loadLockFace), so a change on one page is on the
 * others the next time they show.
 *
 * Saving is optimistic (setLockFace): the face shows the change at once, the store write after; a refused write puts the
 * old one back.
 */
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";

export type ClockFont = "sans" | "serif" | "mono" | "condensed";
export type ClockWeight = "thin" | "light" | "regular" | "bold";
export type ClockColor = "foreground" | "accent" | "muted" | "red";
/** The lock's backdrop over the wallpaper: home's tint, darker, the theme's background alone, black. */
export type LockWall = "tint" | "dim" | "plain" | "black";
export type GlanceItem = "alarm" | "event" | "weather" | "media";
/** A corner: a built-in shortcut, "app:<app key>" (any app: unlock, then it opens) or null (none). */
export type LockCorner = "torch" | "camera" | "focus" | "recorder" | `app:${string}` | null;

export interface LockFaceStyle {
  clock: { font: ClockFont; weight: ClockWeight; color: ClockColor };
  wall: LockWall;
  glance: Record<GlanceItem, boolean>;
  /** [left, right]. */
  corners: [LockCorner, LockCorner];
}

export const STORE = "lock.face";

export const DEFAULT_FACE: LockFaceStyle = {
  clock: { font: "sans", weight: "light", color: "foreground" },
  wall: "tint",
  glance: { alarm: true, event: true, weather: true, media: true },
  corners: ["torch", "camera"],
};

export const FONTS: Record<ClockFont, string> = {
  sans: "var(--font-body)",
  serif: '"Noto Serif", "Roboto Serif", Georgia, serif',
  mono: '"Roboto Mono", "DejaVu Sans Mono", ui-monospace, monospace',
  condensed: '"sans-serif-condensed", "Roboto Condensed", "Arial Narrow", var(--font-body)',
};
export const WEIGHTS: Record<ClockWeight, number> = { thin: 100, light: 300, regular: 400, bold: 700 };
export const CLOCK_COLORS: readonly ClockColor[] = ["foreground", "accent", "muted", "red"];
export const WALLS: readonly LockWall[] = ["tint", "dim", "plain", "black"];
export const GLANCE_ITEMS: readonly GlanceItem[] = ["alarm", "event", "weather", "media"];
export const BUILTIN_CORNERS = ["torch", "camera", "focus", "recorder"] as const;

const pick = <T extends string>(v: unknown, from: readonly T[], or: T): T => (from.includes(v as T) ? (v as T) : or);
const corner = (v: unknown, or: LockCorner): LockCorner =>
  v === null ? null : typeof v === "string" && ((BUILTIN_CORNERS as readonly string[]).includes(v) || /^app:.+/.test(v)) ? (v as LockCorner) : or;

/** [raw] (the store's, any age or shape) made whole: every part it lacks or has wrong is the default's. */
export function faceOf(raw: unknown): LockFaceStyle {
  const r = (raw && typeof raw === "object" ? raw : {}) as Partial<Record<keyof LockFaceStyle, unknown>>;
  const c = (r.clock && typeof r.clock === "object" ? r.clock : {}) as Record<string, unknown>;
  const g = (r.glance && typeof r.glance === "object" ? r.glance : {}) as Record<string, unknown>;
  const k = Array.isArray(r.corners) ? r.corners : [];
  const d = DEFAULT_FACE;
  return {
    clock: {
      font: pick(c.font, Object.keys(FONTS) as ClockFont[], d.clock.font),
      weight: pick(c.weight, Object.keys(WEIGHTS) as ClockWeight[], d.clock.weight),
      color: pick(c.color, CLOCK_COLORS, d.clock.color),
    },
    wall: pick(r.wall, WALLS, d.wall),
    glance: Object.fromEntries(GLANCE_ITEMS.map((i) => [i, typeof g[i] === "boolean" ? g[i] : d.glance[i]])) as Record<GlanceItem, boolean>,
    corners: [corner(k[0], d.corners[0]), corner(k[1], d.corners[1])],
  };
}

/** The face as set (the default until the store is read). */
export const lockFace = signal<LockFaceStyle>(DEFAULT_FACE);

/** Read again each time a face shows (another page may have changed it); a store without it: the default. */
export function loadLockFace() {
  powos.store.get(STORE).then(
    (v) => (lockFace.value = faceOf(v)),
    () => {},
  );
}

/** Changes the face: shown at once, kept after; a refused write puts the old face back. */
export function setLockFace(next: LockFaceStyle) {
  const was = lockFace.value;
  lockFace.value = next;
  powos.store.set(STORE, next).catch(() => lockFace.value === next && (lockFace.value = was));
}

/** The clock style as CSS variables (shell.css .lock-time / .aod-time / .standby-time read them); colour optional. */
export function clockVars(f: LockFaceStyle, color = true): Record<string, string> {
  const v: Record<string, string> = { "--clock-font": FONTS[f.clock.font], "--clock-weight": String(WEIGHTS[f.clock.weight]) };
  if (color) v["--clock-color"] = `var(--color-${f.clock.color})`;
  return v;
}
