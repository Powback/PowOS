/** What an app did lately and what was blocked for it: audit rows and trackers (runtime GET /audit, /trackers). */
import type { ComponentChildren } from "preact";
import { call, type AuditRow, type Net, type Trackers } from "./api";
import { useRuntime } from "./runtime";
import { Muted, S, Switch, title } from "./ui";

export function AuditRows({ rows }: { rows: AuditRow[] }) {
  return (
    <>
      {rows.map((r, i) => (
        <div key={i} style={S.card}>
          <div style={S.row}>
            <span style={{ ...S.name, ...S.grow }}>{title(r.action)}</span>
            <span style={S.muted}>{r.ts.replace("T", " ")}</span>
          </div>
          <div style={S.idMuted}>{`${r.app}.${r.action}`}</div>
          <Muted>
            {r.safety ?? "?"} · {r.refused ? <span style={S.bad}>refused: {r.refused}</span> : r.sent ? `sent, ${r.status}` : "dry run"}
          </Muted>
        </div>
      ))}
    </>
  );
}

export function Audit({ net, app }: { net?: Net; app: string }) {
  const [d, err] = useRuntime<{ rows: AuditRow[] }>(net, app, "/audit?n=100");
  if (err) return <Muted>{err}</Muted>;
  if (!d?.rows.length) return <Muted>Nothing has been called yet. Every call - dry run or sent, from the AI, the CLI, a widget or here - shows up here.</Muted>;
  return <AuditRows rows={d.rows} />;
}

/** The last 10 audit rows for one app (GET /audit?app=<id>&n=10). */
export function AppAudit({ net, app, specApp }: { net?: Net; app: string; specApp: string }) {
  const [d, err] = useRuntime<{ rows: AuditRow[] }>(net, app, `/audit?app=${encodeURIComponent(specApp)}&n=10`);
  if (err) return <Muted>{err}</Muted>;
  return d?.rows.length ? <AuditRows rows={d.rows} /> : <Muted>Nothing has used this app's data yet.</Muted>;
}

function TrackerAppRow({ a, net, app, reload }: { a: Trackers["apps"][number]; net?: Net; app: string; reload: () => void }) {
  const allow = (on: boolean) => call(net, app, "/trackers/allow", { app: a.app, allow: on }).then(reload);
  return (
    <div style={S.card}>
      <div style={S.row}>
        <span style={{ ...S.name, ...S.grow }}>{a.app}</span>
        <span style={S.muted}>allow trackers</span>
        <Switch on={a.allow} label={`allow trackers in ${a.app}`} onFlip={allow} />
      </div>
      {a.seen.map((s) => (
        <Muted key={s.tracker + s.host}>{`${s.tracker} · ${s.host} · ${s.blocked} blocked, ${s.allowed} allowed`}</Muted>
      ))}
    </div>
  );
}

export function TrackersView({ net, app }: { net?: Net; app: string }) {
  const [d, err, reload] = useRuntime<Trackers>(net, app, "/trackers");
  if (err) return <Muted>{err}</Muted>;
  if (!d?.apps.length) return <Muted>No trackers seen yet. Once the capture proxy runs, the trackers each app contacts show up here, blocked unless you allow them.</Muted>;
  const t = d.total;
  return (
    <>
      <Muted>{`${t.trackers} trackers in ${t.apps} apps · ${t.blocked} calls blocked · ${t.allowed} allowed`}</Muted>
      {d.apps.map((a) => <TrackerAppRow key={a.app} a={a} net={net} app={app} reload={reload} />)}
    </>
  );
}

/** A collapsed card: [head] always shows, [children] on tap (native details: no state, no JS). */
export function Fold({ head, children, id }: { head: ComponentChildren; children: ComponentChildren; id?: string }) {
  return (
    <details style={S.card} data-fold={id}>
      <summary style={S.fold}>{head}</summary>
      <div style={{ display: "flex", flexDirection: "column", gap: "8px", marginTop: "10px" }}>{children}</div>
    </details>
  );
}

/** "Privacy": this app's trackers, collapsed; the summary says what was blocked (GET /trackers?app=<id>). */
export function Privacy({ net, app, specApp }: { net?: Net; app: string; specApp: string }) {
  const [d, err, reload] = useRuntime<Trackers>(net, app, `/trackers?app=${encodeURIComponent(specApp)}`);
  const mine = d?.apps[0];
  const blocked = mine?.seen.reduce((n, s) => n + s.blocked, 0) ?? 0;
  const head = (
    <span style={S.foldRow}>
      <span style={S.name}>Privacy</span>
      <span style={S.muted}>{mine ? (mine.allow ? "trackers allowed" : `${blocked} tracker calls blocked`) : "nothing blocked yet"}</span>
    </span>
  );
  return (
    <Fold head={head} id="privacy">
      {err ? <Muted>{err}</Muted> : !mine ? <Muted>No trackers seen for this app. If it contacts any, they are blocked unless you allow them.</Muted> : <TrackerAppRow a={mine} net={net} app={app} reload={reload} />}
    </Fold>
  );
}
