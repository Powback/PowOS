/**
 * Progress on home: how far PowOS is from being the user's everyday phone. A big "Daily driver NN%" (checklist items
 * that work / all items), a bar per area (works / partly / broken / not tried), the top blockers (P0s on the board and
 * broken items, one plain line each), and "N being worked on · N need you". Live on both subscriptions (lib/progress).
 * The header opens the page; a blocker opens the page on its task.
 *
 * Fills its tile at every size (2x2 to 4x4): the box is a size container and the type is in cqmin, so a big tile is
 * big content. 2x2: the number, one bar of the whole checklist, the first blocker. Taller: area bars, more blockers.
 */
import { setFocus, STATE_COLOR, STATE_ORDER, useProgress, type AreaBar, type Blocker, type ItemState } from "../lib/progress";
import type { Props } from "../lib/app";
import { Fit } from "../lib/fit";

/** A control's touches are its own: home's long press / drag of the tile doesn't start on it. */
const own = { onPointerDown: (e: Event) => e.stopPropagation() };

function Bar({ counts, style }: { counts: Record<ItemState, number>; style?: Record<string, string | number> }) {
  const total = STATE_ORDER.reduce((s, k) => s + counts[k], 0) || 1;
  return (
    <div style={{ ...S.bar, ...style }}>
      {STATE_ORDER.map((k) =>
        counts[k] ? <div key={k} style={{ flex: `${counts[k] / total} 0 0`, background: STATE_COLOR[k] }} /> : null,
      )}
    </div>
  );
}

function AreaRow({ a }: { a: AreaBar }) {
  return (
    <div style={S.areaRow}>
      <span style={S.areaName}>{a.area}</span>
      <Bar counts={a.counts} style={{ flex: 1.3 }} />
      <span style={S.areaPct}>{a.pct}%</span>
    </div>
  );
}

function BlockerRow({ b, open }: { b: Blocker; open: (b: Blocker) => void }) {
  return (
    <button type="button" style={S.blocker} onClick={() => open(b)} {...own}>
      <span style={{ ...S.mark, background: b.kind === "p0" ? "var(--color-red, #e0605a)" : STATE_COLOR.partly }} />
      <span style={S.line}>{b.text}</span>
    </button>
  );
}

const NONE: Record<ItemState, number> = { works: 0, partly: 0, broken: 0, untested: 1 };

/** The whole checklist's counts: every area's added up. */
function totals(areas: AreaBar[]) {
  return areas.reduce(
    (c, a) => (STATE_ORDER.forEach((k) => (c[k] += a.counts[k])), c),
    { works: 0, partly: 0, broken: 0, untested: 0 } as Record<ItemState, number>,
  );
}

function countLines(p: ReturnType<typeof useProgress>, wide: boolean) {
  return [wide ? `${p.on} being worked on` : `${p.on} on it`, `${p.you} need${p.you === 1 ? "s" : ""} you`, `${p.hacks.length} hacks`];
}

const heroSide = (works: number, items: number) => (items ? `${works} of ${items} work` : "no checklist yet");

function Hero({ size, pct, side, open }: { size: number; pct: number | null; side: string; open: () => void }) {
  return (
    <button type="button" style={{ ...S.hero, height: `${size * 1.2}em` }} onClick={open} {...own}>
      <span style={{ ...S.pct, fontSize: `${size}em` }}>
        {pct ?? "–"}
        <small style={S.pctSign}>%</small>
      </span>
      <span style={S.heroSide}>{side}</span>
    </button>
  );
}

function Blockers({ blockers, open }: { blockers: Blocker[]; open: (b: Blocker) => void }) {
  return (
    <Fit style={{ flex: "1 1 0" }}>
      {blockers.length ? (
        blockers.slice(0, 3).map((b) => <BlockerRow key={b.key} b={b} open={open} />)
      ) : (
        <span style={{ ...S.line, opacity: 0.6 }}>no blockers</span>
      )}
    </Fit>
  );
}

function Foot({ counts }: { counts: string[] }) {
  return (
    <div style={S.foot}>
      {counts.map((c, i) => (
        <span key={i} style={S.count}>
          {i ? "· " : ""}
          {c}
        </span>
      ))}
    </div>
  );
}

export default function Widget({ host, app: id, cells }: Props) {
  const p = useProgress(host);
  const [cols, rows] = cells ?? [2, 2];
  const big = rows >= 3;
  const all = totals(p.areas);
  const openPage = () => host.openApp?.(id);
  const openBlocker = (b: Blocker) => {
    setFocus(b.task);
    openPage();
  };
  const pct = p.status === "connected" ? p.pct : null;
  // What's left over when the tile can't hold it all goes, whole: a Fit wraps it out of sight (never a cut line).
  return (
    <div style={{ ...S.box, gap: big ? "0.45em" : "0.3em" }}>
      <button type="button" style={S.head} onClick={openPage} {...own}>
        Daily driver
      </button>
      <Hero size={big || cols >= 3 ? 3.2 : 3} pct={pct} side={heroSide(all.works, p.items.length)} open={openPage} />
      <Bar counts={p.items.length ? all : NONE} />
      {big && p.areas.length > 0 && (
        <Fit style={{ flex: rows >= 4 ? "1.4 1 0" : "1 1 0" }}>
          {p.areas.map((a) => (
            <AreaRow key={a.area} a={a} />
          ))}
        </Fit>
      )}
      <Blockers blockers={p.blockers} open={openBlocker} />
      <Foot counts={countLines(p, cols >= 3)} />
    </div>
  );
}

const S: Record<string, Record<string, string | number>> = {
  box: {
    containerType: "size", display: "flex", flexDirection: "column", justifyContent: "space-between", height: "100%", padding: "0.6em 0.75em",
    boxSizing: "border-box", overflow: "hidden", fontSize: "clamp(9px, 6.4cqmin, 22px)", lineHeight: 1.2,
  },
  head: { display: "block", font: "inherit", fontWeight: 600, opacity: 0.8, background: "none", border: 0, color: "inherit", padding: 0, textAlign: "left", flex: "none", whiteSpace: "nowrap", fontSize: "min(1em, 11cqw)" },
  // The number, and beside it the count when there's room: else that goes to a second line, out of sight.
  hero: { display: "flex", flexWrap: "wrap", alignItems: "baseline", columnGap: "0.5em", font: "inherit", background: "none", border: 0, color: "inherit", padding: 0, flex: "none", minWidth: 0, overflow: "hidden", textAlign: "left" },
  pct: { fontWeight: 700, lineHeight: 1.2, fontVariantNumeric: "tabular-nums", letterSpacing: "-0.02em", whiteSpace: "nowrap" },
  pctSign: { fontSize: "0.45em", fontWeight: 600, opacity: 0.7 },
  heroSide: { opacity: 0.7, whiteSpace: "nowrap" },
  bar: { display: "flex", height: "0.5em", borderRadius: "0.25em", overflow: "hidden", gap: "2px", background: "color-mix(in srgb, currentColor 10%, transparent)", flex: "none" },
  areaRow: { display: "flex", alignItems: "center", gap: "0.5em", fontSize: "0.85em", width: "100%", flex: "none" },
  areaName: { flex: "1 1 0", minWidth: 0, opacity: 0.85, overflowWrap: "anywhere" },
  areaPct: { flex: "none", textAlign: "right", fontVariantNumeric: "tabular-nums", opacity: 0.75 },
  blocker: { display: "flex", alignItems: "baseline", gap: "0.45em", font: "inherit", fontSize: "0.9em", background: "none", border: 0, color: "inherit", padding: 0, textAlign: "left", width: "100%", flex: "none" },
  mark: { width: "0.5em", height: "0.5em", borderRadius: "50%", flex: "none", alignSelf: "center" },
  line: { flex: 1, minWidth: 0, overflowWrap: "anywhere" },
  foot: { display: "flex", flexWrap: "wrap", columnGap: "0.3em", fontSize: "0.8em", opacity: 0.65, flex: "none", height: "1.2em", overflow: "hidden" },
  count: { whiteSpace: "nowrap" },
};
