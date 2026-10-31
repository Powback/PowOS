// What needs me on home: the messages waiting for you from Discord, WhatsApp and Gmail - one row per person or
// conversation, newest first, the unread count in the header (a tap on it opens the full page). Usable in place: tap a
// row to reply (the bar's pill), swipe it to mark it read, tap its app icon to open the conversation in that app.
// Rows as fit the tile (min 2x2); a row being answered shows alone with its field.
import { useRef, useState } from "preact/hooks";
import type { Props } from "../lib/act";
import { LINE, Row, useGroups, useSize, type Phase } from "../lib/rows";

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
 * The rows that fit [h] px whole at [font] px: each row is a fixed height (rows.tsx Clamp: a name line, [lines] message
 * lines), so it's counted, not measured - never a row cut in half, never a scroll.
 */
const rowEm = (lines: number) => Math.max(2.1, LINE + lines * LINE * 0.85);

function fitRows(h: number, font: number, lines: number): number {
  const avail = h - font * (1.6 + 1.2 + 0.55);
  const row = rowEm(lines) * font;
  return Math.max(1, Math.floor((avail + 0.55 * font) / (row + 0.55 * font)));
}

export default function Widget({ host, app }: Props) {
  const { phase, groups } = useGroups(host, app);
  const [open, setOpen] = useState<string | null>(null);
  const tile = useRef<HTMLDivElement>(null);
  const size = useSize(tile);
  const lines = size[1] >= 180 ? 2 : 1;
  const answering = open && groups.some((g) => g.id === open);
  // A size to count rows at, then grown (up to what the width takes) so the rows that fit fill the tile.
  const base = Math.max(12, Math.min(22, size[0] / 15, size[1] / 9.5));
  const n = Math.min(Math.max(1, groups.length), fitRows(size[1], base, lines));
  const font = Math.max(base, Math.min(size[0] / 12, 26, (0.9 * size[1]) / (3.35 + n * rowEm(lines) + (n - 1) * 0.55)));
  const shown = answering ? groups.filter((g) => g.id === open) : groups.slice(0, n);
  const count = groups.reduce((n, g) => n + g.count, 0);
  return (
    <div ref={tile} style={{ ...S.tile, fontSize: `${font}px` }}>
      <button style={S.head} onPointerDown={(e) => e.stopPropagation()} onClick={() => host.openApp?.(app)} aria-label="open What needs me">
        <span style={{ fontWeight: 600 }}>Needs me</span>
        {count > 0 && <span style={S.count}>{count}</span>}
      </button>
      {shown.length ? (
        <div style={{ display: "flex", flexDirection: "column", gap: "0.55em", flex: 1, minHeight: 0, overflow: "hidden", justifyContent: answering ? "flex-start" : "space-between" }}>
          {shown.map((g) => (
            <Row key={g.id} g={g} host={host} app={app} open={open === g.id} lines={lines} onToggle={() => setOpen(open === g.id ? null : g.id)} />
          ))}
        </div>
      ) : (
        <Empty phase={phase} onAccess={() => void host.notifications?.access()} />
      )}
    </div>
  );
}

const S = {
  tile: { height: "100%", boxSizing: "border-box", padding: "0.8em 0.9em", display: "flex", flexDirection: "column", gap: "0.55em", color: "var(--color-foreground)" },
  head: { display: "flex", alignItems: "center", gap: "0.5em", padding: 0, border: 0, background: "none", color: "inherit", font: "inherit", textAlign: "left", flex: "none" },
  count: { fontSize: "0.75em", fontWeight: 600, padding: "0 0.55em", borderRadius: "1em", background: "var(--color-red)", color: "var(--color-background)", lineHeight: 1.6 },
  empty: { flex: 1, display: "grid", placeItems: "center", color: "var(--color-muted)", fontSize: "0.9em", textAlign: "center" },
} as const;
