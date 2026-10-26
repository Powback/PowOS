/**
 * Files an app reads and writes (appcap_files.py <state>/files/<app>.jsonl, written by the file tracer), and an
 * override you can set for any path (<state>/files/overrides.json + the content). Nothing here reads another app's
 * files - it shows the tracer's record and keeps the replacement content the tracer serves in that file's place.
 * Empty until the tracer runs.
 */
import { useState } from "preact/hooks";
import { call, type Net } from "./api";
import { Muted, S } from "./ui";

interface FileRow {
  path: string;
  reads: number;
  writes: number;
  last: string;
  override: boolean;
}
interface AppFiles {
  app: string;
  files: FileRow[];
}

function OverrideEditor({ net, app, owner, path, reload }: { net?: Net; app: string; owner: string; path: string; reload: () => void }) {
  const [text, setText] = useState<string | null>(null);
  const [loaded, setLoaded] = useState(false);
  if (!loaded) {
    setLoaded(true);
    call<{ content: string | null }>(net, app, `/files/override?app=${encodeURIComponent(owner)}&path=${encodeURIComponent(path)}`).then((d) => setText(d.content ?? ""));
  }
  const write = (content: string | null) => call(net, app, "/files/override", { app: owner, path, content }).then(() => reload());
  return (
    <div style={{ ...S.card, gap: "8px" }}>
      <textarea style={{ ...S.field, minHeight: "120px", fontFamily: "var(--font, monospace)" }} value={text ?? ""} onInput={(e) => setText((e.target as HTMLTextAreaElement).value)} />
      <div style={S.row}>
        <button type="button" style={{ ...S.btn, ...S.btnOn }} onClick={() => write(text ?? "")}>Save override</button>
        <button type="button" style={S.btn} onClick={() => write(null)}>Remove override</button>
      </div>
    </div>
  );
}

function FileRowView({ net, app, owner, f, reload }: { net?: Net; app: string; owner: string; f: FileRow; reload: () => void }) {
  const [edit, setEdit] = useState(false);
  return (
    <div style={S.card}>
      <div style={{ ...S.row, cursor: "pointer" }} onClick={() => setEdit(!edit)}>
        <span style={{ ...S.id, ...S.grow }}>{f.path}</span>
        {f.override && <span style={{ ...S.muted, color: "var(--color-accent)" }}>override</span>}
      </div>
      <Muted>{`${f.reads} read, ${f.writes} write${f.last ? ` · ${f.last.replace("T", " ")}` : ""}`}</Muted>
      {edit && <OverrideEditor net={net} app={app} owner={owner} path={f.path} reload={reload} />}
    </div>
  );
}

export function Files({ net, app }: { net?: Net; app: string }) {
  const [data, setData] = useState<AppFiles[] | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const load = () => call<{ apps: AppFiles[] }>(net, app, "/files").then((d) => (setData(d.apps), setErr(null)), (e) => setErr(String(e?.message ?? e)));
  if (data === null && err === null) load();
  if (err) return <Muted>{err}</Muted>;
  if (!data?.length) return <Muted>No file access recorded yet. Once the file tracer runs, the files each app reads and writes show up here, and you can override any of them with your own content.</Muted>;
  return (
    <>
      <Muted>What each app reads and writes. Open a file to replace what the app sees with your own content.</Muted>
      {data.map((a) => (
        <section key={a.app} style={{ display: "flex", flexDirection: "column", gap: "8px" }}>
          <h2 style={S.group}>{a.app}</h2>
          {a.files.map((f) => <FileRowView key={f.path} net={net} app={app} owner={a.app} f={f} reload={load} />)}
        </section>
      ))}
    </>
  );
}
