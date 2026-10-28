/**
 * App API, as one flow (docs/app-to-widget.md): pick an app (lib/app-list.tsx: search, recent first) -> its page of
 * plain cards (lib/app-page.tsx: widgets, live data, actions, privacy) -> "Make a widget". Developer details (routes,
 * views, audit, rules, recordings, files) sit in one fold each. Everything is the local runtime on this device
 * (lib/api.ts; docs/APP-API-CAPTURE.md 1b.12): switches are the spec's own `enabled` flags, the allowlist every
 * consumer obeys.
 */
import { useEffect, useState } from "preact/hooks";
import { AddApp } from "../lib/add";
import { Audit, TrackersView } from "../lib/activity";
import { AppList, remember } from "../lib/app-list";
import { AppPage } from "../lib/app-page";
import { call, type AppSpec, type Host, type Net } from "../lib/api";
import { Files } from "../lib/files";
import { Recordings } from "../lib/recordings";
import { Rules } from "../lib/rules";
import { useRuntime } from "../lib/runtime";
import { Muted, S, Seg } from "../lib/ui";

interface Props {
  host: Host;
  app: string;
  close?: () => void;
  route?: Record<string, string>;
}

const TABS = ["Audit", "Trackers", "Rules", "Recordings", "Files"];

function Unreachable({ err, retry }: { err: string; retry: () => void }) {
  return (
    <div style={S.card} onClick={retry}>
      <div style={S.name}>The App API runtime isn't answering on this device.</div>
      <Muted>{err} - tap to try again.</Muted>
    </div>
  );
}

/** Rules, recordings, files, the full audit log and every tracker: the developer tools, one fold at the bottom. */
function DevTools({ net, app }: { net?: Net; app: string }) {
  const [tab, setTab] = useState("Audit");
  const Body = TAB[tab];
  return (
    <details style={S.card} data-fold="developer">
      <summary style={S.fold}><span style={S.foldRow}><span style={S.name}>Developer</span><span style={S.muted}>audit, trackers, rules, recordings, files</span></span></summary>
      <div style={{ display: "flex", flexDirection: "column", gap: "8px", marginTop: "10px" }}>
        <Seg options={TABS} picked={tab} onPick={setTab} />
        <Body net={net} app={app} />
      </div>
    </details>
  );
}

const TAB: Record<string, (p: { net?: Net; app: string }) => preact.ComponentChild> = {
  Audit, Trackers: TrackersView, Rules, Recordings, Files,
};

export default function Main({ host, app, close, route }: Props) {
  const net = host.net;
  const [openId, setOpenId] = useState<string | null>(route?.app ?? null);
  useEffect(() => { setOpenId(route?.app ?? null); }, [route]);
  const [adding, setAdding] = useState(false);
  const [d, err, reload] = useRuntime<{ apps: AppSpec[] }>(net, app, "/apps");
  const spec = d?.apps.find((a) => a.app === openId);
  const open = (id: string) => (remember(id), setOpenId(id));
  if (adding && !spec) {
    const added = (id: string) => (setAdding(false), open(id), reload());
    return (
      <div style={S.page}>
        <AddApp host={host} app={app} back={() => setAdding(false)} added={added} />
      </div>
    );
  }
  // Reload either way (the server's own state wins), but let a failure keep rejecting past the reload - the page's
  // optimistic() flip needs that to roll its switch back with the reason.
  const enable = (id: string) => (on: boolean, action?: string) =>
    call(net, app, "/enable", { app: id, action, enabled: on }).then(
      (r) => (reload(), r),
      (e) => (reload(), Promise.reject(e)),
    );
  if (spec) {
    return (
      <div style={S.page}>
        <AppPage selectedAction={route?.action} addToHome={host.addAppWidget} host={host} net={net} app={app} spec={spec} toggle={enable(spec.app)} back={() => setOpenId(null)} makeWidget={() => setAdding(true)} />
      </div>
    );
  }
  return (
    <div style={S.page}>
      <header style={S.head}>
        <button style={S.back} onClick={close} aria-label="back">‹</button>
        <h1 style={S.title}>Your apps</h1>
      </header>
      {err ? <Unreachable err={err} retry={reload} /> : d ? <AppList apps={d.apps} open={open} add={() => setAdding(true)} flip={(id) => (on) => enable(id)(on).then(() => {}, () => {})} /> : <Muted>…</Muted>}
      <DevTools net={net} app={app} />
    </div>
  );
}
