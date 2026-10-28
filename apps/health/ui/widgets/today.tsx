// Health today: the day's figures per type from the local health database (apps/health module). The widget also runs
// the sync loop while it is on screen, so the numbers stay fresh without opening the page; permission is asked in the page.
// Fills its tile at every size: 2x1/3x1 the steps figure + an icon, taller adds types, from 3 rows a 7-day steps chart.
import { useApp, type Props } from "../lib/app";
import { LABEL, UNIT, show, today, week, weekQuery, type DailyRow } from "../lib/stats";
import { useHealthSync, type CursorRow } from "../lib/sync";

const HEART = "M12 21s-7.5-4.6-9.6-9.2C.9 8.4 2.7 4.8 6.2 4.8c2.1 0 3.6 1.1 5.8 3.4 2.2-2.3 3.7-3.4 5.8-3.4 3.5 0 5.3 3.6 3.8 7C19.5 16.4 12 21 12 21z";
const soft = "color-mix(in srgb, currentColor 8%, transparent)";

export default function Today({ host, cells, app: id }: Props) {
  const app = useApp(host);
  const rows = app.useTable<DailyRow>("daily", weekQuery());
  const cursor = app.useTable<CursorRow>("cursor")[0];
  const ingest = app.useReducer<any>("ingest");
  useHealthSync(host, { cursor, ready: app.db.status === "connected", ingest, ask: false });
  const t = today(rows);
  const cols = cells?.[0] ?? 2;
  const nrows = cells?.[1] ?? 2;
  const steps = t.find((x) => x.kind === "steps") ?? t[0];
  const chart = nrows >= 3 ? week(rows, "steps") : [];
  const others = t.filter((x) => x !== steps);
  const more = nrows < 2 ? 0 : nrows === 2 ? (cols >= 3 ? 3 : 1) : 3;
  const shown = [steps, ...others.slice(0, more)].filter(Boolean);
  const max = Math.max(1, ...chart.map((d) => d.value ?? 0));
  const peak = Math.max(...chart.map((d) => d.value ?? 0));

  return (
    <div style={{ width: "100%", height: "100%", containerType: "size" }} onClick={() => host.openApp?.(id)}>
      <div style={{ display: "flex", flexDirection: "column", width: "100%", height: "100%", padding: "8px 12px", boxSizing: "border-box", gap: "0.5em", fontSize: "clamp(13px, 6cqmin, 22px)" }}>
        {!shown.length ? (
          <div style={{ flex: 1, display: "flex", alignItems: "center", justifyContent: "center", textAlign: "center", fontWeight: 600, opacity: 0.8 }}>Tap to connect Health</div>
        ) : nrows < 2 ? (
          <div style={{ flex: 1, minHeight: 0, display: "flex", alignItems: "center", gap: "0.6em" }}>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ fontSize: "0.7em", opacity: 0.7, whiteSpace: "nowrap" }}>{LABEL[shown[0].kind]}</div>
              <div style={{ fontSize: "1.5em", fontWeight: 600, lineHeight: 1.1, fontVariantNumeric: "tabular-nums", whiteSpace: "nowrap" }}>
                {show(shown[0].kind, shown[0].day.value as number)} <small style={{ fontSize: "0.5em", opacity: 0.7 }}>{UNIT[shown[0].kind]}</small>
              </div>
            </div>
            <svg viewBox="0 0 24 24" style={{ height: "2.2em", width: "2.2em", flex: "none", padding: "0.4em", borderRadius: "50%", background: soft, boxSizing: "border-box" }} aria-hidden="true">
              <path d={HEART} fill="currentColor" opacity="0.85" />
            </svg>
          </div>
        ) : (
          <>
            <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: "0.5em", flex: chart.length ? "none" : 1, minHeight: 0, alignContent: "stretch" }}>
              {shown.map(({ kind, day }) => (
                <div key={kind} style={{ background: soft, borderRadius: "0.7em", padding: "0.4em 0.6em", display: "flex", flexDirection: "column", justifyContent: "center", minWidth: 0 }}>
                  <div style={{ fontSize: "0.7em", opacity: 0.7, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{LABEL[kind]}</div>
                  <div style={{ fontSize: "1.3em", fontWeight: 600, lineHeight: 1.15, fontVariantNumeric: "tabular-nums", whiteSpace: "nowrap" }}>
                    {show(kind, day.value as number)} <small style={{ fontSize: "0.5em", opacity: 0.7 }}>{UNIT[kind]}</small>
                  </div>
                </div>
              ))}
            </div>
            {chart.length > 0 && (
              <div style={{ flex: 1, minHeight: "3em", display: "flex", flexDirection: "column", gap: "0.2em" }}>
                <div style={{ fontSize: "0.7em", opacity: 0.7 }}>Steps, 7 days</div>
                <div style={{ flex: 1, minHeight: 0, display: "flex", alignItems: "flex-end", gap: "0.4em" }}>
                  {chart.map((d, i) => (
                    <div key={d.day} style={{ flex: 1, height: "100%", display: "flex", flexDirection: "column", justifyContent: "flex-end", alignItems: "stretch", gap: "0.2em" }}>
                      <div style={{ height: `${Math.max(4, ((d.value ?? 0) / max) * 100)}%`, minHeight: "0.3em", maxHeight: "calc(100% - 1.2em)", borderRadius: "0.3em", background: "currentColor", opacity: i === 6 ? 0.9 : (d.value ?? 0) === peak ? 0.6 : 0.35 }} />
                      <div style={{ fontSize: "0.6em", opacity: 0.6, textAlign: "center", lineHeight: 1 }}>{["S", "M", "T", "W", "T", "F", "S"][new Date(d.day).getDay()]}</div>
                    </div>
                  ))}
                </div>
              </div>
            )}
          </>
        )}
      </div>
    </div>
  );
}
