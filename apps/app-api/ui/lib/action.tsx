/**
 * One action, opened: its typed inputs as fields, its output's shape, and a dry run through the runtime
 * (appcap_run.py: the exact request, auth shown only as its handle). Sends: `read` only in this first slice; a
 * reversible write stays a dry run; a spend is never sent from here - it is confirmed in chat.
 */
import { useState } from "preact/hooks";
import { call, shape, type Action, type CallResult, type Net, type Schema } from "./api";
import { Block, Muted, S } from "./ui";

type Args = Record<string, string | boolean>;

function Field({ name, s, value, set }: { name: string; s: Schema; value: string | boolean | undefined; set: (v: string | boolean) => void }) {
  const label = `${name}: ${s.type ?? "any"}`;
  if (s.type === "boolean") {
    return (
      <label style={S.row}>
        <span style={S.grow}>{label}</span>
        <input type="checkbox" checked={value === true} onChange={(e) => set((e.target as HTMLInputElement).checked)} />
      </label>
    );
  }
  const num = s.type === "number" || s.type === "integer";
  return (
    <label style={S.row}>
      <span style={{ ...S.muted, flex: "none" }}>{label}</span>
      <input
        style={S.field}
        inputMode={num ? "decimal" : "text"}
        min={s.minimum}
        max={s.maximum}
        value={typeof value === "string" ? value : ""}
        onInput={(e) => set((e.target as HTMLInputElement).value)}
      />
    </label>
  );
}

function preview(p: Record<string, unknown>): string[] {
  const lines = [String(p.request ?? p.ui ?? p.argv ?? "")];
  for (const k of ["auth", "body", "undo"]) if (p[k]) lines.push(`${k}: ${typeof p[k] === "string" ? p[k] : JSON.stringify(p[k])}`);
  return lines;
}

function request(r: CallResult): string {
  if (r.refused) return `refused: ${r.refused}`;
  const p = r.preview ?? {};
  const lines = preview(p);
  lines.push(p.dry_run ? "dry run - nothing was sent" : `sent - status ${p.status} in ${p.duration_ms} ms`);
  if (r.response_sample) lines.push("", r.response_sample.slice(0, 1200));
  return lines.join("\n");
}

function SendButton({ a, busy, run }: { a: Action; busy: boolean; run: (send: boolean) => void }) {
  if (a.safety === "spend") return <Muted>Confirm in chat - a spend is never sent from here.</Muted>;
  if (a.safety !== "read") return <Muted>Writes are dry run only for now.</Muted>;
  return (
    <button type="button" style={S.btn} disabled={busy || !a.enabled} onClick={() => run(true)}>
      Send
    </button>
  );
}

export function ActionPanel(p: { net?: Net; app: string; spec: string; id: string; a: Action }) {
  const [args, setArgs] = useState<Args>({});
  const [out, setOut] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const props = p.a.inputs?.properties ?? {};
  const run = (send: boolean) => {
    setBusy(true);
    call<CallResult>(p.net, p.app, "/call", { app: p.spec, action: p.id, args, send })
      .then((r) => setOut(request(r)), (e) => setOut(`couldn't run it: ${e?.message ?? e}`))
      .finally(() => setBusy(false));
  };
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: "8px" }}>
      {Object.entries(props).map(([k, s]) => (
        <Field key={k} name={k} s={s} value={args[k]} set={(v) => setArgs({ ...args, [k]: v })} />
      ))}
      <Muted>
        {p.a.endpoint}
        {p.a.auth ? ` · auth ${p.a.auth}` : ""} · returns {shape(p.a.output)}
      </Muted>
      {p.a.confirm_template && <Muted>asks first: {p.a.confirm_template}</Muted>}
      <div style={S.row}>
        <button type="button" style={{ ...S.btn, ...S.btnOn }} disabled={busy} onClick={() => run(false)}>
          Dry run
        </button>
        <SendButton a={p.a} busy={busy} run={run} />
      </div>
      {out && <Block>{out}</Block>}
    </div>
  );
}
