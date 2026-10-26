/**
 * __NAME__ - a composed widget (status list), made by `powos compose` from: __WORDS__
 *
 * What it shows is ../composition.json (the manifest: which building blocks, which rows): edit that, then
 * `powos compose build <this app's folder>`. It only reads - the blocks are called as a widget (App API refuses
 * anything but a read for that) and nothing here can change or spend; a tap on the header opens the app the
 * composition names. Fills its tile at every size (the widget template's rules, docs/DESIGN-LANGUAGE.md): the type
 * follows the tile and is fitted to the longest name (the font is monospace: fitting is counting), rows share the
 * height in whole rows (more scroll up/down), no lines - soft fills only.
 */
import { useEffect, useRef, useState } from "preact/hooks";
import type { Props } from "../lib/app";
import { useComposition, type Composition, type Row } from "../lib/compose";
import composition from "../composition.json";

const C = composition as unknown as Composition;

/** A control's touches are its own: home's long press / drag of the tile doesn't start on it. */
const own = { onPointerDown: (e: Event) => e.stopPropagation() };

/** em per character of the shell's monospace font, with room to spare (the phone's ~0.575, the preview's 0.5). */
const CH = 0.62;
const MIN = 11;
/** Narrower than this (px of the box's inside) a row has no level bar: its name needs the width. */
const BAR_MIN = 200;

function useSize(ref: { current: Element | null }): [number, number] {
  const [s, setS] = useState<[number, number]>([0, 0]);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setS([el.clientWidth, el.clientHeight]));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  return s;
}

/** The largest font (px) at which [chars] characters plus [ems] of fixed parts fit [px], within [MIN, top]. */
const fit = (px: number, chars: number, ems: number, top: number) => Math.min(top, Math.max(MIN, px / (chars * CH + ems)));
const fits = (px: number, chars: number, ems: number) => px / (chars * CH + ems) >= MIN;

interface Layout {
  font: number;
  pad: number;
  head: { font: number; count: boolean };
  row: { font: number; bar: boolean };
}

/** Sizes from the box: the base type follows the tile; rows and header shrink only as far as their text needs. */
function layout(w: number, h: number, rows: Row[], title: string, count: string, oneRow: boolean): Layout {
  const font = Math.min(22, Math.max(13, Math.min(w, h) * 0.06));
  const pad = (oneRow ? 0.8 : 0.9) * font;
  const iw = Math.max(1, w - 2 * pad);
  const longest = Math.max(1, ...rows.map((r) => r.label.length));
  const value = Math.max(0, ...rows.map((r) => (r.value ? r.value.length * CH + 0.6 : 0)));
  const dot = rows.some((r) => r.on !== undefined) ? 1.15 : 0;
  const levels = rows.some((r) => r.level !== undefined);
  const bar = levels && iw >= BAR_MIN && fits(iw * 0.7, longest, 1.4 + dot + value + 0.6);
  const rowPx = bar ? iw * 0.7 : iw;
  const countEm = count.length * CH + 0.5;
  const withCount = fits(iw, title.length, 1.05 + countEm);
  // Few rows in a tall tile: their type grows with the height they share (as far as the width lets it).
  const listH = h - 2 * (oneRow ? 0.15 : 0.6) * font - (oneRow ? 0 : 1.7 * font);
  const tall = Math.min(30, Math.max(font, listH / (Math.max(1, rows.length) * 2.6)));
  return {
    font,
    pad,
    head: { font: fit(iw, title.length, 1.05 + (withCount ? countEm : 0), font), count: withCount },
    row: { font: fit(rowPx, longest, 1.4 + dot + value + (bar ? 0.6 : 0), tall), bar },
  };
}

export default function Widget({ host, app, base, cells = [4, 2] }: Props) {
  const box = useRef<HTMLDivElement>(null);
  const [w, h] = useSize(box);
  const c = useComposition(host, app, C, box);
  const [detail, setDetail] = useState(false);
  const oneRow = cells[1] < 2;
  const lit = c.rows.filter((r) => r.on).length;
  const count = (c.rows.some((r) => r.on !== undefined) && c.phase === "live" ? `${lit} on` : "") + (C.open ? " ›" : "");
  // A one-row tile is the rows alone; an unreachable block there is its line alone (no room for greyed rows too).
  const showRows = c.phase === "live" || (c.phase === "stale" && !oneRow);
  const L = layout(w || 240, h || 120, c.rows, C.show.title, count, oneRow);
  return (
    <div ref={box} style={{ ...S.box, padding: `${oneRow ? 0.15 * L.font : 0.6 * L.font}px ${L.pad}px`, fontSize: w ? `${L.font}px` : S.box.fontSize }}>
      {(!oneRow || !showRows) && (
        <button type="button" style={{ ...S.head, fontSize: `${L.head.font}px` }} onClick={() => C.open && host.openApp?.(C.open)} {...own}>
          <span style={{ ...S.dot, background: lit && c.phase === "live" ? "var(--color-accent, #fc6)" : "color-mix(in srgb, currentColor 30%, transparent)" }} />
          <span style={S.title}>{C.show.title}</span>
          {L.head.count && count && <span style={S.count}>{count}</span>}
        </button>
      )}
      {c.phase === "loading" && <div style={S.note}>…</div>}
      {showRows && (
        <div class={c.phase === "stale" ? "island-stale" : undefined} style={{ ...S.list, fontSize: `${L.row.font}px` }}>
          {c.rows.length === 0 && <div style={S.note}>{C.show.empty ?? "Nothing to show"}</div>}
          {c.rows.map((r) => (
            <Line key={r.key} r={r} bar={L.row.bar} />
          ))}
        </div>
      )}
      {c.message && (
        // The shell's shared calm line (.island-offline): a tap retries now, a long press shows what really failed.
        <button
          type="button"
          class={showRows ? "island-offline" : "island-offline alone"}
          title={c.detail}
          onClick={() => {
            setDetail(false);
            c.retry();
          }}
          onContextMenu={(e) => {
            e.preventDefault();
            setDetail((d) => !d);
          }}
          {...own}
        >
          {!showRows && <img class="island-offline-icon" src={`${base}icon.svg`} alt="" width={48} height={48} />}
          <span>{detail ? c.detail : c.message}</span>
        </button>
      )}
    </div>
  );
}

/** One row (a whole row of the list: its soft pill inside): a dot lit when on, the name, its level or value. */
function Line({ r, bar }: { r: Row; bar: boolean }) {
  return (
    <div style={S.row}>
      <div style={{ ...S.pill, opacity: r.on === false ? 0.65 : 1 }}>
        {r.on !== undefined && <span style={{ ...S.dot, background: r.on ? "var(--color-accent, #fc6)" : "color-mix(in srgb, currentColor 30%, transparent)" }} />}
        <span style={S.name}>{r.label}</span>
        {bar && r.level !== undefined && (
          <span style={S.track} aria-label={`${Math.round(r.on === false ? 0 : r.level)}%`}>
            <span style={{ ...S.fill, width: `${r.on === false ? 0 : r.level}%` }} />
          </span>
        )}
        {r.value !== undefined && <span style={S.value}>{r.value}</span>}
      </div>
    </div>
  );
}

const S: Record<string, Record<string, string | number>> = {
  // Before it's measured the type follows the tile in CSS: 13 px on a small tile, up to 22 px on the inner screen's.
  box: {
    containerType: "size", display: "flex", flexDirection: "column", gap: "0.3em", height: "100%", boxSizing: "border-box",
    overflow: "hidden", fontSize: "clamp(13px, 6cqmin, 22px)",
  },
  head: { display: "flex", alignItems: "center", gap: "0.5em", font: "inherit", fontWeight: 600, background: "none", border: 0, color: "inherit", padding: 0, flex: "none", minWidth: 0 },
  title: { flex: 1, minWidth: 0, textAlign: "left", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis", opacity: 0.9 },
  count: { flex: "none", opacity: 0.6, fontWeight: 400 },
  dot: { flex: "none", width: "0.55em", height: "0.55em", borderRadius: "50%" },
  note: { flex: 1, display: "flex", alignItems: "center", justifyContent: "center", color: "var(--color-muted, currentColor)" },
  // The rows share what's left of the height, in whole rows (no gap: each row's pill sits inside it) - a few rows
  // stretch to fill it; more than fit scroll up and down, snapped to rows.
  list: { flex: 1, minHeight: 0, display: "flex", flexDirection: "column", overflowY: "auto", scrollSnapType: "y mandatory", touchAction: "pan-y", scrollbarWidth: "none" },
  row: { display: "flex", flex: "1 0 2.2em", boxSizing: "border-box", padding: "0.12em 0", scrollSnapAlign: "start" },
  pill: {
    flex: 1, minWidth: 0, display: "flex", alignItems: "center", gap: "0.6em", padding: "0 0.7em", borderRadius: "0.8em",
    background: "color-mix(in srgb, currentColor 8%, transparent)",
  },
  name: { flex: 1, minWidth: 0, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" },
  track: { flex: "0 0 30%", height: "0.4em", borderRadius: "0.2em", overflow: "hidden", background: "color-mix(in srgb, currentColor 14%, transparent)" },
  fill: { display: "block", height: "100%", borderRadius: "0.2em", background: "var(--color-accent, #fc6)" },
  value: { flex: "none", fontVariantNumeric: "tabular-nums", opacity: 0.85 },
};
