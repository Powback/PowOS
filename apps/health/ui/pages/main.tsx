/**
 * Health's page: today per type, the last 7 days, and which wearable's app each figure came from. The first time it
 * opens it asks Health Connect for read access (a system dialog, once) and starts the sync.
 */
import { useState } from "preact/hooks";
import { useApp, type HealthType, type Props } from "../lib/app";
import { KINDS, LABEL, UNIT, show, sourceName, today, week, weekQuery, type DailyRow } from "../lib/stats";
import { useHealthSync, type CursorRow, type Phase } from "../lib/sync";

const NOTE: Partial<Record<Phase, string>> = {
  "needs-grant": "Allow PowOS to read your health data in Health Connect.",
  update: "Health Connect needs an update before PowOS can read it.",
  none: "This phone has no Health Connect.",
  unsupported: "The PowOS app on this phone can't reach Health Connect yet.",
};

const dayName = (ms: number) => new Date(ms).toLocaleDateString([], { weekday: "short" });

export default function Main({ host, close }: Props) {
  const app = useApp(host);
  const rows = app.useTable<DailyRow>("daily", weekQuery());
  const cursor = app.useTable<CursorRow>("cursor")[0];
  const ingest = app.useReducer<any>("ingest");
  const { state, syncNow } = useHealthSync(host, cursor, app.db.status === "connected", ingest, true);
  const [open, setOpen] = useState<HealthType | null>(null);
  const t = today(rows);
  return (
    <div style={S.page}>
      <header style={S.head}>
        <button style={S.back} onClick={close} aria-label="back">‹</button>
        <h1 style={S.title}>Health</h1>
        <button class="surface" style={S.button} onClick={() => void syncNow()} disabled={state.phase === "syncing"}>
          {state.phase === "syncing" ? "Syncing…" : "Sync"}
        </button>
      </header>
      {NOTE[state.phase] && <section class="tile" style={S.card}>{NOTE[state.phase]} {state.phase === "needs-grant" && <button class="surface" style={S.button} onClick={() => void syncNow()}>Allow</button>}</section>}
      {state.phase === "error" && <div style={S.err}>{state.message}</div>}
      {!t.length && state.phase === "ok" && <div style={S.meta}>Nothing from today yet. Your wearables' apps write to Health Connect when they sync.</div>}
      {KINDS.map((kind) => {
        const w = week(rows, kind);
        if (!w.some((d) => d.value != null)) return null;
        const top = Math.max(...w.map((d) => d.value ?? 0), 1);
        const td = w[6];
        return (
          <section key={kind} class="tile" style={S.card} onClick={() => setOpen(open === kind ? null : kind)}>
            <div style={S.row}>
              <span style={S.label}>{LABEL[kind]}</span>
              <span style={S.big}>{td.value != null ? show(kind, td.value) : "–"} <small style={S.meta}>{UNIT[kind]}</small></span>
            </div>
            <div style={S.bars}>
              {w.map((d) => (
                <div key={d.day} style={S.barCol}>
                  <span style={{ ...S.bar, height: `${d.value != null ? Math.max(4, (d.value / top) * 100) : 0}%` }} />
                  <span style={S.meta}>{dayName(d.day).slice(0, 2)}</span>
                </div>
              ))}
            </div>
            {open === kind && (
              <div style={S.list}>
                {td.sources.map((s) => (
                  <div key={s.source} style={S.row}>
                    <span style={S.meta}>{sourceName(s.source)}</span>
                    <span>{show(kind, s.value)} {UNIT[kind]}</span>
                  </div>
                ))}
                {!td.sources.length && <div style={S.meta}>Nothing today.</div>}
              </div>
            )}
          </section>
        );
      })}
      {state.at && <div style={S.meta}>Synced {new Date(state.at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })} · {state.took ?? 0} new</div>}
    </div>
  );
}

const S: Record<string, Record<string, string | number>> = {
  page: { display: "flex", flexDirection: "column", gap: "12px", height: "100%", padding: "8px 16px 16px", boxSizing: "border-box", overflowY: "auto" },
  head: { display: "flex", alignItems: "center", gap: "8px" },
  back: { font: "inherit", fontSize: "28px", lineHeight: 1, background: "none", border: 0, color: "var(--color-accent)", padding: "0 8px 0 0" },
  title: { flex: 1, margin: 0, fontSize: "1.4em", fontWeight: 600 },
  card: { display: "flex", flexDirection: "column", gap: "10px", padding: "12px 14px" },
  row: { display: "flex", alignItems: "center", justifyContent: "space-between", gap: "10px" },
  label: { color: "var(--color-muted)" },
  big: { fontSize: "1.5em", fontWeight: 600, fontVariantNumeric: "tabular-nums" },
  bars: { display: "flex", alignItems: "flex-end", gap: "6px", height: "56px" },
  barCol: { flex: 1, height: "100%", display: "flex", flexDirection: "column", justifyContent: "flex-end", alignItems: "center", gap: "2px" },
  bar: { display: "block", width: "100%", borderRadius: "3px", background: "var(--color-accent)" },
  button: { font: "inherit", padding: "6px 14px", color: "inherit" },
  err: { color: "var(--color-red)" },
  list: { display: "flex", flexDirection: "column", gap: "6px", borderTop: "1px solid var(--divider)", paddingTop: "8px" },
  meta: { fontSize: "var(--text-small)", color: "var(--color-muted)" },
};
