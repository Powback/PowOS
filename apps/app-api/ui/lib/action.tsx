/**
 * An app's actions by safety class, and one action opened: its typed inputs as fields, its output's shape, and a dry
 * run through the runtime (appcap_run.py: the exact request, auth shown only as its handle). Sends: `read` only in this
 * first slice; a reversible write stays a dry run; a spend is never sent from here - it is confirmed in chat. A draft
 * (`draft`: "+ add app" review) has no switches and only ever dry-runs (/call draft:true, appcap_run.py --draft).
 */
import { useEffect, useRef, useState } from "preact/hooks";
import { call, SAFETY, shape, type Action, type AppSpec, type AppWidget, type CallResult, type Net, type Schema } from "./api";
import { Block, Muted, S, Switch, title } from "./ui";

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

function SendButton({ a, busy, run, draft }: { a: Action; busy: boolean; run: (send: boolean) => void; draft?: boolean }) {
  if (draft) return <Muted>A draft only dry-runs: add it to your apps to use it.</Muted>;
  if (a.safety === "spend") return <Muted>Confirm in chat - a spend is never sent from here.</Muted>;
  if (a.safety !== "read") return <Muted>Writes are dry run only for now.</Muted>;
  return (
    <button type="button" style={S.btn} disabled={busy || !a.enabled} onClick={() => run(true)}>
      Send
    </button>
  );
}

export function ActionPanel(p: { net?: Net; app: string; spec: string; id: string; a: Action; draft?: boolean }) {
  const [args, setArgs] = useState<Args>({});
  const [out, setOut] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const props = p.a.inputs?.properties ?? {};
  const run = (send: boolean) => {
    setBusy(true);
    call<CallResult>(p.net, p.app, "/call", { app: p.spec, action: p.id, args, send: send && !p.draft, draft: !!p.draft })
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
        <SendButton a={p.a} busy={busy} run={run} draft={p.draft} />
      </div>
      {out && <Block>{out}</Block>}
    </div>
  );
}

export interface DetailProps {
  net?: Net;
  app: string;
  spec: AppSpec;
  /** The action's switch (the allowlist); none in a draft's review. */
  toggle?: (on: boolean, action?: string) => void;
  draft?: boolean;
  selectedAction?: string;
}

function ActionRow({ p, id }: { p: DetailProps; id: string }) {
  const [open, setOpen] = useState(p.selectedAction === id);
  const row = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (p.selectedAction === id) { setOpen(true); row.current?.scrollIntoView({ block: "start" }); }
  }, [p.selectedAction, id]);
  const a = p.spec.actions[id];
  const toggle = p.toggle;
  return (
    <div ref={row} style={S.card}>
      <div style={{ ...S.row, cursor: "pointer" }} onClick={() => setOpen(!open)}>
        <div style={S.grow}>
          <div style={S.name}>{title(id)}</div>
          <div style={S.idMuted}>{id}</div>
          <Muted>{a.summary}</Muted>
        </div>
        {toggle ? <Switch on={a.enabled} label={`${title(id)} allowed`} onFlip={(on) => toggle(on, id)} /> : <span style={S.muted}>{a.enabled ? "on when added" : "off"}</span>}
      </div>
      {open && <ActionPanel net={p.net} app={p.app} spec={p.spec.app} id={id} a={a} draft={p.draft} />}
    </div>
  );
}

/** "5x2 cells" when the widget declares a target grid size, else its minimum in dp. */
function widgetSize(w: AppWidget): string {
  return w.targetCellWidth ? `${w.targetCellWidth}x${w.targetCellHeight} cells` : `${w.minWidth}x${w.minHeight} dp`;
}

/** An Android app's analysed home-screen widgets (AppWidgetProviders): what each is, so a PowOS widget can be offered. */
export function Widgets({ widgets }: { widgets?: AppWidget[] }) {
  if (!widgets?.length) return null;
  return (
    <section style={{ display: "flex", flexDirection: "column", gap: "8px" }}>
      <h2 style={S.group}>
        Home-screen widgets <span style={{ ...S.muted, fontWeight: 400 }}>the app's own; each is also a widget-able action above</span>
      </h2>
      {widgets.map((w) => (
        <div key={w.provider} style={S.card}>
          <div style={S.name}>{w.label}</div>
          <div style={S.idMuted}>{w.provider}</div>
          <Muted>
            {widgetSize(w)} · {w.resize.length ? `resizes ${w.resize.join(" + ")}` : "fixed size"} · preview {w.preview}
            {w.updatePeriodMs >= 1800000 ? ` · updates every ${Math.round(w.updatePeriodMs / 60000)} min` : ""}
            {w.configure ? ` · set-up: ${w.configure}` : ""}
          </Muted>
        </div>
      ))}
    </section>
  );
}

export function Actions(p: DetailProps) {
  const ids = Object.keys(p.spec.actions).sort((a, b) => Number(b === p.selectedAction) - Number(a === p.selectedAction) || a.localeCompare(b));
  return (
    <>
      {SAFETY.map((g) => {
        const mine = ids.filter((id) => p.spec.actions[id].safety === g.id);
        if (!mine.length) return null;
        return (
          <section key={g.id} style={{ display: "flex", flexDirection: "column", gap: "8px" }}>
            <h2 style={S.group}>
              {g.label} <span style={{ ...S.muted, fontWeight: 400 }}>{g.note}</span>
            </h2>
            {mine.map((id) => <ActionRow key={id} p={p} id={id} />)}
          </section>
        );
      })}
      <Widgets widgets={p.spec.widgets} />
    </>
  );
}
