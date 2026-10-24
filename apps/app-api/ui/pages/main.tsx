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

function Detail(p: DetailProps & { toggle: (on: boolean, action?: string) => void; back: () => void }) {
  const [view, setView] = useState("Actions");
  const which = VIEWS.find(([v]) => v === view)?.[1] ?? null;
  const [views, err] = useRuntime<Views>(p.net, p.app, which ? `/views?app=${encodeURIComponent(p.spec.app)}` : null, Number(p.spec.enabled));
  return (
    <>
      <header style={S.head}>
        <button style={S.back} onClick={p.back} aria-label="back">‹</button>
        <h1 style={S.title}>{p.spec.name}</h1>
        <Switch on={p.spec.enabled} label={`${p.spec.name} on`} onFlip={(on) => p.toggle(on)} />
      </header>
      {p.spec.description && <Muted>{p.spec.description}</Muted>}
      <Seg options={VIEWS.map(([v]) => v)} picked={view} onPick={setView} />
      {which ? <Block>{err ? `couldn't render: ${err}` : views ? views[which] : "…"}</Block> : <Actions {...p} />}
    </>
  );
}

function Audit({ net, app }: { net?: Net; app: string }) {
  const [d, err] = useRuntime<{ rows: AuditRow[] }>(net, app, "/audit?n=100");
  if (err) return <Muted>{err}</Muted>;
  if (!d?.rows.length) return <Muted>Nothing has been called yet. Every call - dry run or sent, from the AI, the CLI, a widget or here - shows up here.</Muted>;
  return (
    <>
      {d.rows.map((r, i) => (
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

function TrackersView({ net, app }: { net?: Net; app: string }) {
  const [d, err, reload] = useRuntime<Trackers>(net, app, "/trackers");
  if (err) return <Muted>{err}</Muted>;
  if (!d?.apps.length) return <Muted>No trackers seen yet. Once the capture proxy runs, the trackers each app contacts show up here, blocked unless you allow them.</Muted>;
  const allow = (a: string, on: boolean) => call(net, app, "/trackers/allow", { app: a, allow: on }).then(reload);
  const t = d.total;
  return (
    <>
      <Muted>{`${t.trackers} trackers in ${t.apps} apps · ${t.blocked} calls blocked · ${t.allowed} allowed`}</Muted>
      {d.apps.map((a) => (
        <div key={a.app} style={S.card}>
          <div style={S.row}>
            <span style={{ ...S.name, ...S.grow }}>{a.app}</span>
            <span style={S.muted}>allow trackers</span>
            <Switch on={a.allow} label={`allow trackers in ${a.app}`} onFlip={(on) => allow(a.app, on)} />
          </div>
          {a.seen.map((s) => (
            <Muted key={s.tracker + s.host}>{`${s.tracker} · ${s.host} · ${s.blocked} blocked, ${s.allowed} allowed`}</Muted>
          ))}
        </div>
      ))}
    </>
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
    const toggle = (on: boolean, action?: string) => call(net, app, "/enable", { app: spec.app, action, enabled: on }).then(reload, reload);
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
