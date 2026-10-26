/**
 * Rewrite rules (appcap_flows.py <state>/rules.json): a local block/rewrite list the capture proxy applies. Nothing
 * here intercepts anything - it edits the list. A rule matches a host glob (and path glob) and either blocks the
 * request or rewrites one header / replaces text in the body.
 */
import { useState } from "preact/hooks";
import { call, type Net } from "./api";
import { Muted, S } from "./ui";

interface Rule {
  id?: string;
  enabled: boolean;
  app: string;
  host: string;
  path: string;
  action: "block" | "rewrite";
  header?: { name: string; value: string };
  body?: { find: string; replace: string };
}

const BLANK: Rule = { enabled: true, app: "", host: "", path: "*", action: "block" };

function describe(r: Rule): string {
  if (r.action === "block") return `block ${r.host}${r.path === "*" ? "" : r.path}`;
  const bits = [r.header && `header ${r.header.name}`, r.body && `body "${r.body.find}"→"${r.body.replace}"`].filter(Boolean);
  return `rewrite ${r.host}: ${bits.join(", ")}`;
}

function Editor({ draft, set, save, cancel }: { draft: Rule; set: (r: Rule) => void; save: () => void; cancel: () => void }) {
  const f = (k: keyof Rule) => (e: Event) => set({ ...draft, [k]: (e.target as HTMLInputElement).value });
  return (
    <div style={{ ...S.card, gap: "8px" }}>
      <div style={S.row}>
        <input style={S.field} placeholder="host (e.g. *.doubleclick.net)" value={draft.host} onInput={f("host")} />
        <input style={{ ...S.field, flex: "0 0 90px" }} placeholder="path *" value={draft.path} onInput={f("path")} />
      </div>
      <div style={S.row}>
        <select style={S.field} value={draft.action} onChange={(e) => set({ ...draft, action: (e.target as HTMLSelectElement).value as Rule["action"] })}>
          <option value="block">block</option>
          <option value="rewrite">rewrite</option>
        </select>
        <input style={S.field} placeholder="app (optional)" value={draft.app} onInput={f("app")} />
      </div>
      {draft.action === "rewrite" && (
        <>
          <div style={S.row}>
            <input style={S.field} placeholder="set header name" value={draft.header?.name ?? ""} onInput={(e) => set({ ...draft, header: { name: (e.target as HTMLInputElement).value, value: draft.header?.value ?? "" } })} />
            <input style={S.field} placeholder="header value" value={draft.header?.value ?? ""} onInput={(e) => set({ ...draft, header: { name: draft.header?.name ?? "", value: (e.target as HTMLInputElement).value } })} />
          </div>
          <div style={S.row}>
            <input style={S.field} placeholder="find in body" value={draft.body?.find ?? ""} onInput={(e) => set({ ...draft, body: { find: (e.target as HTMLInputElement).value, replace: draft.body?.replace ?? "" } })} />
            <input style={S.field} placeholder="replace with" value={draft.body?.replace ?? ""} onInput={(e) => set({ ...draft, body: { find: draft.body?.find ?? "", replace: (e.target as HTMLInputElement).value } })} />
          </div>
        </>
      )}
      <div style={S.row}>
        <button type="button" style={{ ...S.btn, ...S.btnOn }} onClick={save}>Add rule</button>
        <button type="button" style={S.btn} onClick={cancel}>Cancel</button>
      </div>
    </div>
  );
}

export function Rules({ net, app }: { net?: Net; app: string }) {
  const [rules, setRules] = useState<Rule[] | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [draft, setDraft] = useState<Rule | null>(null);
  const load = () => call<{ rules: Rule[] }>(net, app, "/rules").then((d) => (setRules(d.rules), setErr(null)), (e) => setErr(String(e?.message ?? e)));
  if (rules === null && err === null) load();
  const write = (next: Rule[]) => call<{ rules: Rule[] }>(net, app, "/rules", { rules: next }).then((d) => setRules(d.rules), (e) => setErr(String(e?.message ?? e)));
  if (err) return <Muted>{err}</Muted>;
  return (
    <>
      <Muted>Blocks and rewrites the capture proxy applies to your apps' traffic. Editing the list here changes nothing on its own.</Muted>
      {(rules ?? []).map((r, i) => (
        <div key={r.id ?? i} style={S.card}>
          <div style={S.row}>
            <span style={{ ...S.grow, textDecoration: r.enabled ? "none" : "line-through", opacity: r.enabled ? 1 : 0.5 }}>{describe(r)}</span>
            <button type="button" style={S.btn} onClick={() => write(rules!.map((x, j) => (j === i ? { ...x, enabled: !x.enabled } : x)))}>{r.enabled ? "off" : "on"}</button>
            <button type="button" style={S.btn} onClick={() => write(rules!.filter((_, j) => j !== i))}>remove</button>
          </div>
        </div>
      ))}
      {draft ? (
        <Editor draft={draft} set={setDraft} cancel={() => setDraft(null)} save={() => (write([...(rules ?? []), draft]), setDraft(null))} />
      ) : (
        <button type="button" style={S.btn} onClick={() => setDraft({ ...BLANK })}>+ rule</button>
      )}
    </>
  );
}
