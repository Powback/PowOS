/**
 * Recorded flows (appcap_flows.py <state>/recordings/*.har, the capture proxy's own HAR files). View a recording's
 * requests, edit one in place (the original is kept once), and replay it - a dry run by default; a send only for
 * GET/HEAD, audited. Secret values (auth, cookies, tokens, keys) always show as <hidden> and are never editable away:
 * leaving a <hidden> value alone keeps the recorded one, and a send injects it on the device, never in the open.
 */
import { useState } from "preact/hooks";
import { call, type Net } from "./api";
import { Block, Muted, S } from "./ui";

interface Flow {
  i: number;
  method: string;
  url: string;
  status?: number;
  headers: { name: string; value: string }[];
  body: string;
}
interface Rec {
  name: string;
  flows: number;
  edited: boolean;
  time: string;
}

function replayText(r: any): string {
  const lines = [r.refused ? `refused: ${r.refused}` : r.request];
  if (r.rule) lines.push(`rule: ${r.rule}`);
  lines.push(r.dry_run ? "dry run - nothing was sent" : `sent - status ${r.status} in ${r.duration_ms} ms`);
  if (r.response_sample) lines.push("", String(r.response_sample).slice(0, 1000));
  return lines.join("\n");
}

function FlowRow({ net, app, name, f, reload }: { net?: Net; app: string; name: string; f: Flow; reload: () => void }) {
  const [url, setUrl] = useState(f.url);
  const [out, setOut] = useState<string | null>(null);
  const save = () => call(net, app, "/recording/edit", { name, i: f.i, url }).then(() => reload());
  const replay = (send: boolean) => call(net, app, "/recording/replay", { name, i: f.i, send }).then((r) => setOut(replayText(r)), (e) => setOut(String(e?.message ?? e)));
  return (
    <div style={S.card}>
      <div style={S.row}>
        <span style={{ ...S.id, flex: "0 0 auto" }}>{f.method}</span>
        <span style={S.muted}>{f.status ?? ""}</span>
      </div>
      <input style={S.field} value={url} onInput={(e) => setUrl((e.target as HTMLInputElement).value)} />
      {f.headers.some((h) => h.value === "<hidden>") && <Muted>secrets shown as &lt;hidden&gt; - left alone, the recorded value is kept</Muted>}
      <div style={S.row}>
        <button type="button" style={S.btn} disabled={url === f.url} onClick={save}>Save edit</button>
        <button type="button" style={{ ...S.btn, ...S.btnOn }} onClick={() => replay(false)}>Dry run</button>
        {f.method === "GET" || f.method === "HEAD" ? <button type="button" style={S.btn} onClick={() => replay(true)}>Replay</button> : <Muted>replay: GET/HEAD only</Muted>}
      </div>
      {out && <Block>{out}</Block>}
    </div>
  );
}

export function Recordings({ net, app }: { net?: Net; app: string }) {
  const [recs, setRecs] = useState<Rec[] | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [open, setOpen] = useState<string | null>(null);
  const [flows, setFlows] = useState<Flow[]>([]);
  const loadList = () => call<{ recordings: Rec[] }>(net, app, "/recordings").then((d) => (setRecs(d.recordings), setErr(null)), (e) => setErr(String(e?.message ?? e)));
  const loadRec = (name: string) => call<{ flows: Flow[] }>(net, app, `/recording?name=${encodeURIComponent(name)}`).then((d) => (setOpen(name), setFlows(d.flows)));
  if (recs === null && err === null) loadList();
  if (err) return <Muted>{err}</Muted>;
  if (open) {
    return (
      <>
        <button type="button" style={S.btn} onClick={() => setOpen(null)}>‹ all recordings</button>
        <Muted>{open}</Muted>
        {flows.map((f) => <FlowRow key={f.i} net={net} app={app} name={open} f={f} reload={() => loadRec(open)} />)}
      </>
    );
  }
  if (!recs?.length) return <Muted>No recordings yet. The capture proxy writes a HAR per app here; then you can view, edit and replay its requests.</Muted>;
  return (
    <>
      {recs.map((r) => (
        <div key={r.name} style={{ ...S.card, cursor: "pointer" }} onClick={() => loadRec(r.name)}>
          <div style={S.name}>{r.name}</div>
          <Muted>{`${r.flows} request${r.flows === 1 ? "" : "s"} · ${r.time}${r.edited ? " · edited" : ""}`}</Muted>
        </div>
      ))}
    </>
  );
}
