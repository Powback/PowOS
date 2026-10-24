/**
 * App API: what each of your apps can do, as one API (docs/APP-API-CAPTURE.md 1b.12). Switch an app or an action on
 * and off (the spec's own `enabled` flags, the allowlist every consumer obeys), see the views generated from its spec
 * (appcap_render.py: API, AI tools, CLI, widget bindings), dry-run an action, read the audit log and the trackers the
 * capture proxy saw. All of it is the local runtime on this device (lib/api.ts).
 */
import { useState } from "preact/hooks";
import { Actions, type DetailProps } from "../lib/action";
import { AddApp } from "../lib/add";
import { call, type AppSpec, type AuditRow, type Host, type Net, type Trackers, type Views } from "../lib/api";
import { Files } from "../lib/files";
import { optimistic } from "../lib/pending";
import { Recordings } from "../lib/recordings";
import { Rules } from "../lib/rules";
import { useRuntime } from "../lib/runtime";
import { Block, Muted, S, Seg, Switch, title } from "../lib/ui";

interface Props {
  host: Host;
  app: string;
  close?: () => void;
}

const TABS = ["Apps", "Audit", "Trackers", "Rules", "Recordings", "Files"];
const VIEWS: [string, keyof Views | null][] = [["Actions", null], ["API", "api"], ["AI tools", "tools"], ["CLI", "cli"], ["Widgets", "widgets"]];

function Unreachable({ err, retry }: { err: string; retry: () => void }) {
  return (
    <div style={S.card} onClick={retry}>
      <div style={S.name}>The App API runtime isn't answering on this device.</div>
      <Muted>{err} - tap to try again.</Muted>
    </div>
  );
}

function AppCard({ a, open, flip }: { a: AppSpec; open: () => void; flip: (on: boolean) => void }) {
  const n = Object.keys(a.actions ?? {}).length;
  return (
    <div style={{ ...S.card, cursor: "pointer" }} onClick={open}>
      <div style={S.row}>
        <div style={S.grow}>
          <div style={S.name}>{a.name}</div>
          <Muted>{a.error ? `spec refused: ${a.error}` : `${n} action${n === 1 ? "" : "s"} · ${a.app}`}</Muted>
        </div>
        {!a.error && <Switch on={a.enabled} label={`${a.name} on`} onFlip={flip} />}
      </div>
    </div>
  );
}

/** This app's origin(s), from its actions (official / captured / drafted - docs/APP-API-CAPTURE.md): usually one
 * value, joined when an app mixes a hand-written action with a captured or drafted one. */
function originOf(spec: AppSpec): string {
  const vals = [...new Set(Object.values(spec.actions ?? {}).map((a) => a.origin).filter(Boolean))].sort();
  return vals.join("/") || "unknown";
}

/** This app's auth handle(s) - secret:<app> or store:<app>:session, never a value (appcap_serve.summary already
 * strips it to the handle before this ever reaches the UI). null when no action needs auth. */
function authOf(spec: AppSpec): string | null {
  const vals = [...new Set(Object.values(spec.actions ?? {}).map((a) => a.auth).filter((a): a is string => !!a))].sort();
  return vals.length ? vals.join(", ") : null;
}

/** [spec] with an action's (or the app's own, key "_app") `enabled` optimistically overridden, for Detail's flip(). */
function withOverride(spec: AppSpec, overrides: Record<string, boolean>): AppSpec {
  if (!Object.keys(overrides).length) return spec;
  const actions = { ...spec.actions };
  for (const [id, on] of Object.entries(overrides)) {
    if (id !== "_app" && actions[id]) actions[id] = { ...actions[id], enabled: on };
  }
  return { ...spec, enabled: overrides["_app"] ?? spec.enabled, actions };
}

function Detail(p: DetailProps & { toggle: (on: boolean, action?: string) => void; back: () => void }) {
  const [view, setView] = useState("Actions");
  const [overrides, setOverrides] = useState<Record<string, boolean>>({});
  const [toggleErr, setToggleErr] = useState<string | null>(null);
  const spec = withOverride(p.spec, overrides);
  const which = VIEWS.find(([v]) => v === view)?.[1] ?? null;
  const [views, err] = useRuntime<Views>(p.net, p.app, which ? `/views?app=${encodeURIComponent(spec.app)}` : null, Number(spec.enabled));
  // The switch's own optimistic apply: it flips now, /enable runs in the background, a failure rolls it back with
  // why (optimistic(), lib/pending.tsx - same shape "+ add app" uses for its installed-app drafts).
  const flip = (on: boolean, action?: string) => {
    const key = action ?? "_app";
    const prev = action ? p.spec.actions[action].enabled : p.spec.enabled;
    setToggleErr(null);
    optimistic(
      () => setOverrides((o) => ({ ...o, [key]: on })),
      () => Promise.resolve(p.toggle(on, action)),
      (e) => {
        setOverrides((o) => ({ ...o, [key]: prev }));
        setToggleErr(`couldn't turn ${action ? title(action) : spec.name} ${on ? "on" : "off"}: ${(e as Error)?.message ?? String(e)}`);
      },
    );
  };
  const origin = originOf(spec);
  const auth = authOf(spec);
  return (
    <>
      <header style={S.head}>
        <button style={S.back} onClick={p.back} aria-label="back">‹</button>
        <h1 style={S.title}>{spec.name}</h1>
        <Switch on={spec.enabled} label={`${spec.name} on`} onFlip={(on) => flip(on)} />
      </header>
      <Muted>{auth ? `${origin} · auth ${auth}` : origin}</Muted>
      {spec.description && <Muted>{spec.description}</Muted>}
      {toggleErr && <Muted><span style={S.bad}>{toggleErr}</span></Muted>}
      <Seg options={VIEWS.map(([v]) => v)} picked={view} onPick={setView} />
      {which ? <Block>{err ? `couldn't render: ${err}` : views ? views[which] : "…"}</Block> : <Actions {...p} spec={spec} toggle={flip} />}
      <AppAudit net={p.net} app={p.app} specApp={spec.app} />
      <AppTrackers net={p.net} app={p.app} specApp={spec.app} />
    </>
  );
}

function AuditRows({ rows }: { rows: AuditRow[] }) {
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

function Audit({ net, app }: { net?: Net; app: string }) {
  const [d, err] = useRuntime<{ rows: AuditRow[] }>(net, app, "/audit?n=100");
  if (err) return <Muted>{err}</Muted>;
  if (!d?.rows.length) return <Muted>Nothing has been called yet. Every call - dry run or sent, from the AI, the CLI, a widget or here - shows up here.</Muted>;
  return <AuditRows rows={d.rows} />;
}

/** The last 10 audit rows for one app, embedded in its detail (same rows/route as the Audit tab, filtered + capped
 * server-side: GET /audit?app=<id>&n=10, appcap_serve.audit). */
function AppAudit({ net, app, specApp }: { net?: Net; app: string; specApp: string }) {
  const [d, err] = useRuntime<{ rows: AuditRow[] }>(net, app, `/audit?app=${encodeURIComponent(specApp)}&n=10`);
  return (
    <section style={{ display: "flex", flexDirection: "column", gap: "8px" }}>
      <h2 style={S.group}>Audit</h2>
      {err ? <Muted>{err}</Muted> : !d?.rows.length ? <Muted>Nothing has been called yet.</Muted> : <AuditRows rows={d.rows} />}
    </section>
  );
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

function TrackersView({ net, app }: { net?: Net; app: string }) {
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

/** This app's trackers, embedded in its detail: the Trackers tab's own route (/trackers has no per-app filter -
 * appcap_serve.trackers always returns every app), filtered here to the one the detail is open on. */
function AppTrackers({ net, app, specApp }: { net?: Net; app: string; specApp: string }) {
  const [d, err, reload] = useRuntime<Trackers>(net, app, "/trackers");
  const mine = d?.apps.find((a) => a.app === specApp);
  return (
    <section style={{ display: "flex", flexDirection: "column", gap: "8px" }}>
      <h2 style={S.group}>Trackers</h2>
      {err ? <Muted>{err}</Muted> : !mine ? <Muted>No trackers seen yet for this app.</Muted> : <TrackerAppRow a={mine} net={net} app={app} reload={reload} />}
    </section>
  );
}

interface AppsProps {
  net?: Net;
  app: string;
  d: { apps: AppSpec[] } | null;
  err: string | null;
  reload: () => void;
  open: (id: string) => void;
  add: () => void;
}

/** "+ add app": describe one to PowOS AI, pick an installed one, or import its API (lib/add.tsx); drafts wait there. */
function AddCard({ add }: { add: () => void }) {
  return (
    <div style={{ ...S.card, cursor: "pointer" }} onClick={add} data-add-app="">
      <div style={S.name}>+ add app</div>
      <Muted>Describe it, pick an installed app, or import its API. It waits as a draft until you add it.</Muted>
    </div>
  );
}

function AppsTab({ net, app, d, err, reload, open, add }: AppsProps) {
  const toggle = (spec: string) => (on: boolean, action?: string) =>
    call(net, app, "/enable", { app: spec, action, enabled: on }).then(reload, reload);
  if (err) return <Unreachable err={err} retry={reload} />;
  return (
    <>
      {d?.apps.map((a) => <AppCard key={a.app} a={a} open={() => open(a.app)} flip={toggle(a.app)} />)}
      <AddCard add={add} />
    </>
  );
}

const TAB: Record<string, (p: { net?: Net; app: string }) => preact.ComponentChild> = {
  Audit, Trackers: TrackersView, Rules, Recordings, Files,
};

export default function Main({ host, app, close }: Props) {
  const net = host.net;
  const [tab, setTab] = useState("Apps");
  const [openId, setOpenId] = useState<string | null>(null);
  const [adding, setAdding] = useState(false);
  const [d, err, reload] = useRuntime<{ apps: AppSpec[] }>(net, app, "/apps");
  const spec = d?.apps.find((a) => a.app === openId);
  if (adding && !spec) {
    const added = (id: string) => (setAdding(false), setOpenId(id), reload());
    return (
      <div style={S.page}>
        <AddApp host={host} app={app} back={() => setAdding(false)} added={added} />
      </div>
    );
  }
  if (spec) {
    // Reload either way (the server's own state wins), but let a failure keep rejecting past the reload - Detail's
    // optimistic() flip needs that to roll its switch back with the reason.
    const toggle = (on: boolean, action?: string) =>
      call(net, app, "/enable", { app: spec.app, action, enabled: on }).then(
        (r) => (reload(), r),
        (e) => (reload(), Promise.reject(e)),
      );
    return (
      <div style={S.page}>
        <Detail net={net} app={app} spec={spec} toggle={toggle} back={() => setOpenId(null)} />
      </div>
    );
  }
  const Body = TAB[tab];
  return (
    <div style={S.page}>
      <header style={S.head}>
        <button style={S.back} onClick={close} aria-label="back">‹</button>
        <h1 style={S.title}>App API</h1>
      </header>
      <Seg options={TABS} picked={tab} onPick={setTab} />
      {tab === "Apps" ? <AppsTab net={net} app={app} d={d} err={err} reload={reload} open={setOpenId} add={() => setAdding(true)} /> : Body && <Body net={net} app={app} />}
    </div>
  );
}
