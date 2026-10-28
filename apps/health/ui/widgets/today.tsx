// Health today: the day's figures per type from the local health database (apps/health module). The widget also runs
// the sync loop while it is on screen, so the numbers stay fresh without opening the page; permission is asked in the page.
// Fills its tile at every size: 2x1/3x1 the steps figure + an icon, taller adds types, from 3 rows a 7-day steps chart.
import { useApp, type Props } from "../lib/app";
import { LABEL, UNIT, show, today, week, weekQuery, type Day, type DailyRow } from "../lib/stats";
import { useHealthSync, type CursorRow } from "../lib/sync";

const HEART = "M12 21s-7.5-4.6-9.6-9.2C.9 8.4 2.7 4.8 6.2 4.8c2.1 0 3.6 1.1 5.8 3.4 2.2-2.3 3.7-3.4 5.8-3.4 3.5 0 5.3 3.6 3.8 7C19.5 16.4 12 21 12 21z";
const SHORT: Record<string, string> = { active_calories: "Calories" };
const soft = "color-mix(in srgb, currentColor 8%, transparent)";

type Tile = ReturnType<typeof today>[number];

function Figure({ tile }: { tile: Tile }) {
  return (
    <>
      {show(tile.kind, tile.day.value as number)} <small style={{ fontSize: "0.5em", opacity: 0.7 }}>{UNIT[tile.kind]}</small>
    </>
  );
}

function Small({ tile }: { tile: Tile }) {
  return (
    <div style={{ flex: 1, minHeight: 0, display: "flex", alignItems: "center", gap: "3cqw" }}>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: "min(24cqh, 12cqw)", opacity: 0.7, whiteSpace: "nowrap", lineHeight: 1.1 }}>{LABEL[tile.kind]}</div>
        <div style={{ fontSize: "min(52cqh, 26cqw)", fontWeight: 600, lineHeight: 1.05, fontVariantNumeric: "tabular-nums", whiteSpace: "nowrap" }}>
          <Figure tile={tile} />
        </div>
      </div>
      <svg viewBox="0 0 24 24" style={{ height: "min(62cqh, 20cqw)", width: "min(62cqh, 20cqw)", flex: "none", padding: "0.25em", borderRadius: "50%", background: soft, boxSizing: "border-box" }} aria-hidden="true">
        <path d={HEART} fill="currentColor" opacity="0.85" />
      </svg>
    </div>
  );
}

function Tiles({ tiles, grow, narrow }: { tiles: Tile[]; grow: boolean; narrow: boolean }) {
  return (
    <div style={{ display: "grid", gridTemplateColumns: narrow ? "1fr" : "1fr 1fr", gap: "0.5em", flex: grow ? 1 : "none", minHeight: 0, alignContent: "stretch" }}>
      {tiles.map((tile) => (
        <div key={tile.kind} style={{ background: soft, borderRadius: "0.7em", padding: "0.4em 0.6em", display: "flex", flexDirection: "column", justifyContent: "center", minWidth: 0 }}>
          <div style={{ fontSize: "0.7em", opacity: 0.7, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{SHORT[tile.kind] ?? LABEL[tile.kind]}</div>
          <div style={{ fontSize: "1.3em", fontWeight: 600, lineHeight: 1.15, fontVariantNumeric: "tabular-nums", whiteSpace: "nowrap" }}>
            <Figure tile={tile} />
          </div>
        </div>
      ))}
    </div>
  );
}

function Chart({ days }: { days: Day[] }) {
  const max = Math.max(1, ...days.map((d) => d.value ?? 0));
  return (
    <div style={{ flex: 1, minHeight: "3em", display: "flex", flexDirection: "column", gap: "0.2em" }}>
      <div style={{ fontSize: "0.7em", opacity: 0.7 }}>Steps, 7 days</div>
      <div style={{ flex: 1, minHeight: 0, display: "flex", alignItems: "flex-end", gap: "0.4em" }}>
        {days.map((d, i) => (
          <div key={d.day} style={{ flex: 1, height: "100%", display: "flex", flexDirection: "column", justifyContent: "flex-end", gap: "0.2em" }}>
            <div style={{ height: `${Math.max(4, ((d.value ?? 0) / max) * 100)}%`, minHeight: "0.3em", maxHeight: "calc(100% - 1.2em)", borderRadius: "0.3em", background: "currentColor", opacity: i === 6 ? 0.9 : 0.35 }} />
            <div style={{ fontSize: "0.6em", opacity: 0.6, textAlign: "center", lineHeight: 1 }}>{"SMTWTFS"[new Date(d.day).getDay()]}</div>
          </div>
        ))}
      </div>
    </div>
  );
}

/** Nothing to show yet: a big heart + "Connect Health", scaled to the tile (container units), one line, centred. */
function Empty({ row, tall }: { row: boolean; tall: boolean }) {
  // Row (one-cell-high tiles): heart then text across the width. Column: the text spans the width, the heart takes the height left.
  const size = row ? "min(96cqh, 40cqw)" : tall ? "max(10cqmin, min(92cqh - 58.8cqw, 98cqw))" : "max(10cqmin, min(84cqh - 16.7cqw, 88cqw))";
  const text = row ? "calc((88cqw - min(96cqh, 40cqw) - 3cqw) / 7.4)" : tall ? "24.5cqw" : "11.9cqw";
  return (
    <div style={{ position: "absolute", inset: 0, display: "flex", flexDirection: row ? "row" : "column", alignItems: "center", justifyContent: "center", gap: row ? "3cqw" : "3cqh", fontWeight: 600 }}>
      <svg viewBox="0 0 24 24" style={{ height: size, width: size, flex: "none" }} aria-hidden="true">
        <path d={HEART} fill="currentColor" opacity="0.85" />
      </svg>
      <div style={{ fontSize: text, whiteSpace: "nowrap", lineHeight: 1.1, textAlign: "center", opacity: 0.9 }}>{tall ? <>Connect<br />Health</> : "Connect Health"}</div>
    </div>
  );
}

function Body({ shown, nrows, cols, chart }: { shown: Tile[]; nrows: number; cols: number; chart: Day[] }) {
  if (!shown.length) return <Empty row={nrows < 2} tall={nrows >= 3 && cols < nrows} />;
  if (nrows < 2) return <Small tile={shown[0]} />;
  return (
    <>
      <Tiles tiles={shown} grow={!chart.length} narrow={cols < 3} />
      {chart.length > 0 && <Chart days={chart} />}
    </>
  );
}

/** How many figures beyond steps a tile of this size holds. */
const extra = (cols: number, nrows: number) => (nrows < 2 ? 0 : cols < 3 ? Math.min(nrows, 3) - 1 : nrows === 2 ? 3 : 3);

export default function Today({ host, cells, app: id }: Props) {
  const app = useApp(host);
  const rows = app.useTable<DailyRow>("daily", weekQuery());
  const cursor = app.useTable<CursorRow>("cursor")[0];
  const ingest = app.useReducer<any>("ingest");
  useHealthSync(host, { cursor, ready: app.db.status === "connected", ingest, ask: false });
  const t = today(rows);
  const nrows = cells?.[1] ?? 2;
  const cols = cells?.[0] ?? 2;
  const steps = t.find((x) => x.kind === "steps") ?? t[0];
  const shown = steps ? [steps, ...t.filter((x) => x !== steps).slice(0, extra(cols, nrows))] : [];
  const chart = nrows >= (cols < 3 ? 4 : 3) ? week(rows, "steps") : [];
  const body = <Body shown={shown} nrows={nrows} cols={cols} chart={chart} />;
  return (
    <div style={{ width: "100%", height: "100%", containerType: "size" }} onClick={() => host.openApp?.(id)}>
      <div style={{ display: "flex", flexDirection: "column", width: "100%", height: "100%", padding: shown.length ? (nrows < 2 ? "3px 8px" : "8px 12px") : 0, position: "relative", boxSizing: "border-box", gap: "0.5em", fontSize: "clamp(13px, 6cqmin, 22px)" }}>{body}</div>
    </div>
  );
}
