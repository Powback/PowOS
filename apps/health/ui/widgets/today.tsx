// Health today: the day's figures per type from the local health database (apps/health module). The widget also runs
// the sync loop while it is on screen, so the numbers stay fresh without opening the page; permission is asked in the page.
import { useApp, type Props } from "../lib/app";
import { LABEL, UNIT, show, today, weekQuery, type DailyRow } from "../lib/stats";
import { useHealthSync, type CursorRow } from "../lib/sync";

export default function Today({ host, cells, app: id }: Props) {
  const app = useApp(host);
  const rows = app.useTable<DailyRow>("daily", weekQuery());
  const cursor = app.useTable<CursorRow>("cursor")[0];
  const ingest = app.useReducer<any>("ingest");
  const { state } = useHealthSync(host, cursor, app.db.status === "connected", ingest, false);
  const t = today(rows);
  const small = (cells?.[1] ?? 2) < 2;
  const shown = t.slice(0, small ? 2 : 4);
  return (
    <div
      style={{ display: "flex", flexDirection: "column", height: "100%", padding: "10px 14px", boxSizing: "border-box", gap: "6px" }}
      onClick={() => host.openApp?.(id)}
    >
      <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: "8px 14px", flex: 1, alignContent: "center" }}>
        {shown.map(({ kind, day }) => (
          <div key={kind}>
            <div style={{ fontSize: "0.75em", opacity: 0.7 }}>{LABEL[kind]}</div>
            <div style={{ fontSize: "1.5em", fontWeight: 600, fontVariantNumeric: "tabular-nums" }}>
              {show(kind, day.value as number)} <small style={{ fontSize: "0.5em", opacity: 0.7 }}>{UNIT[kind]}</small>
            </div>
          </div>
        ))}
        {!shown.length && (
          <div style={{ gridColumn: "1 / -1", opacity: 0.75 }}>
            {state.phase === "needs-grant" || state.phase === "idle" ? "Open Health to connect Health Connect." : state.message ?? "Nothing from today yet."}
          </div>
        )}
      </div>
    </div>
  );
}
