// What needs me on home: the messages waiting for you from Discord, WhatsApp and Gmail - one row per person or
// conversation, newest first, the unread count in the header (a tap on it opens the full page). Usable in place: tap a
// row to reply (the bar's pill), swipe it to mark it read, tap its app icon to open the conversation in that app.
// Rows as fit the tile (min 2x2), at the fixed type scale; a row being answered shows alone with its field.
import { useRef, useState } from "preact/hooks";
import type { Props } from "../lib/act";
import { ICON_EM, LINE, Row, useGroups, useSize, type Narrow, type Phase } from "../lib/rows";

const NOTE: Record<Exclude<Phase, "ok">, string> = {
  old: "Update PowOS to use this widget",
  loading: "…",
  "no-access": "Allow notification access",
};

function Empty({ phase, onAccess }: { phase: Phase; onAccess(): void }) {
  if (phase === "ok") return <div style={S.empty}>Nothing needs you</div>;
  return (
    <button style={{ ...S.empty, border: 0, background: "none", color: "inherit", font: "inherit" }} onPointerDown={(e) => e.stopPropagation()} onClick={onAccess}>
      {NOTE[phase]}
    </button>
  );
}

/**
 * The type is the fixed scale (docs/DESIGN-LANGUAGE.md §4, theme.css --text-*), the Agents/Lights widgets' sizes at
 * every tile size: a bigger tile shows more rows, never bigger letters (the user, 2026-11-01: the 4x3 tile drew "Needs
 * me" and its one row at 26px, so only one of three fit). Rows are a fixed height (rows.tsx: a name line, [lines]
 * message lines, all at --text-body), so they're counted, not measured - never a row cut in half, never a scroll.
 */
const PAD_Y = 8;
const GAP = 6;
const HEAD = 18;

/** A theme size token in px ([el]'s computed custom property), [dflt] before layout or on an older theme. */
function token(el: HTMLElement | null, name: string, dflt: number): number {
  const v = el ? parseFloat(getComputedStyle(el).getPropertyValue(name)) : NaN;
  return v > 0 ? v : dflt;
}

// SLACK: a line with an emoji (another font's taller glyph) is a pixel or two taller than its line-height.
const SLACK = 3;
const rowPx = (body: number, lines: number) => Math.max(ICON_EM * body, LINE * body * (1 + lines)) + SLACK;

/** What a row keeps at [w] px wide: icons + text + time from 220px, without the time from 150px, the text alone below. */
const narrowAt = (w: number): Narrow => (w >= 220 ? "no" : w >= 150 ? "time" : "text");

const avail = (h: number) => h - 2 * PAD_Y - HEAD - GAP;

function fitRows(h: number, body: number, lines: number): number {
  return Math.max(1, Math.floor((avail(h) + GAP) / (rowPx(body, lines) + GAP)));
}

/** Two message lines per row while a two-line row fits whole and shows every row one-line rows would; else one. */
function linesFor(h: number, body: number, want: number): number {
  const two = rowPx(body, 2) <= avail(h) && Math.min(want, fitRows(h, body, 2)) >= Math.min(want, fitRows(h, body, 1));
  return two ? 2 : 1;
}

export default function Widget({ host, app }: Props) {
  const { phase, groups } = useGroups(host, app);
  const [open, setOpen] = useState<string | null>(null);
  const tile = useRef<HTMLDivElement>(null);
  const size = useSize(tile);
  const body = token(tile.current, "--text-body", 14);
  const answering = open && groups.some((g) => g.id === open);
  const want = Math.max(1, groups.length);
  const lines = linesFor(size[1], body, want);
  const fit = fitRows(size[1], body, lines);
  const n = Math.min(want, fit);
  // A full tile spreads what's left over (less than a row) between its rows; one with fewer rows than fit keeps them
  // at the top - the letters never grow either way.
  const spread = !answering && n === fit && n > 1;
  const shown = answering ? groups.filter((g) => g.id === open) : groups.slice(0, n);
  const count = groups.reduce((n, g) => n + g.count, 0);
  return (
    <div ref={tile} style={{ ...S.tile, paddingInline: narrowAt(size[0]) === "text" ? "10px" : "12px" }} data-rows={shown.length} data-lines={lines}>
      <button style={S.head} onPointerDown={(e) => e.stopPropagation()} onClick={() => host.openApp?.(app)} aria-label="open What needs me">
        <span class="nm-title" style={S.title}>Needs me</span>
        {count > 0 && <span style={S.count}>{count}</span>}
      </button>
      {shown.length ? (
        <div style={{ display: "flex", flexDirection: "column", gap: `${GAP}px`, flex: 1, minHeight: 0, overflow: "hidden", justifyContent: spread ? "space-between" : "flex-start" }}>
          {shown.map((g) => (
            <Row key={g.id} g={g} host={host} app={app} open={open === g.id} lines={lines} narrow={narrowAt(size[0])} onToggle={() => setOpen(open === g.id ? null : g.id)} />
          ))}
        </div>
      ) : (
        <Empty phase={phase} onAccess={() => void host.notifications?.access()} />
      )}
    </div>
  );
}

const S = {
  tile: { height: "100%", boxSizing: "border-box", padding: `${PAD_Y}px 12px`, display: "flex", flexDirection: "column", gap: `${GAP}px`, color: "var(--color-foreground)", fontFamily: "var(--font-body)", fontSize: "var(--text-body)" },
  head: { display: "flex", alignItems: "center", gap: "5px", whiteSpace: "nowrap", height: `${HEAD}px`, padding: 0, border: 0, background: "none", color: "inherit", font: "inherit", textAlign: "left", flex: "none" },
  title: { fontWeight: 600, minWidth: 0, overflow: "hidden", textOverflow: "ellipsis" },
  count: { flex: "none", fontSize: "var(--text-small)", fontWeight: 600, padding: "0 5px", borderRadius: "999px", background: "var(--color-red)", color: "var(--color-background)", lineHeight: "16px" },
  empty: { flex: 1, display: "grid", placeItems: "center", color: "var(--color-muted)", fontSize: "var(--text-body)", textAlign: "center" },
} as const;
