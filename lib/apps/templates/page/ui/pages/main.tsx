/**
 * __NAME__'s full-screen page: what opens from the drawer, search and the recent apps (the shell renders it in its own
 * page, with the host). Edit and save: `powos app dev` rebuilds it and the open page updates in place.
 */
import { useState } from "preact/hooks";
import { useApp, type Props } from "../lib/app";

interface Entry {
  id: bigint;
  text: string;
  done: boolean;
  module: string;
}

export default function Main({ host, close }: Props) {
  const app = useApp(host);
  const status = app.useStatus();
  const entries = app.useTable<Entry>("entry").sort((a, b) => Number(a.done) - Number(b.done) || Number(a.id - b.id));
  const add = app.useReducer<{ text: string }>("add");
  const toggle = app.useReducer<{ id: bigint }>("toggle");
  const remove = app.useReducer<{ id: bigint }>("remove");
  const clearDone = app.useReducer("clear_done");
  const [text, setText] = useState("");
  const [err, setErr] = useState<string | null>(null);
  const run = (p: Promise<unknown>) => p.then(() => setErr(null), (e) => setErr(String(e?.message ?? e)));
  const submit = (e: Event) => {
    e.preventDefault();
    if (!text.trim()) return;
    run(add({ text }).then(() => setText("")));
  };
  return (
    <div style={S.page}>
      <header style={S.head}>
        <button style={S.back} onClick={close} aria-label="back">‹</button>
        <h1 style={S.title}>__NAME__</h1>
        <span style={{ ...S.dot, background: status === "connected" ? "var(--color-green, #4c4)" : "var(--color-yellow, #cc4)" }} />
      </header>
      <form style={S.row} onSubmit={submit}>
        <input style={S.input} value={text} onInput={(e) => setText((e.target as HTMLInputElement).value)} placeholder="Add…" />
        <button style={S.button} type="submit">Add</button>
      </form>
      {err && <div style={S.err}>{err}</div>}
      <ul style={S.list}>
        {entries.map((e) => (
          <li key={String(e.id)} style={S.item}>
            <input type="checkbox" checked={e.done} onChange={() => run(toggle({ id: e.id }))} style={S.check} />
            <span style={{ flex: 1, opacity: e.done ? 0.5 : 1, textDecoration: e.done ? "line-through" : "none" }}>{e.text}</span>
            <button style={S.x} onClick={() => run(remove({ id: e.id }))} aria-label="remove">×</button>
          </li>
        ))}
      </ul>
      {entries.some((e) => e.done) && (
        <button style={{ ...S.button, alignSelf: "center" }} onClick={() => run(clearDone())}>Clear done</button>
      )}
    </div>
  );
}

const S: Record<string, Record<string, string | number>> = {
  page: { display: "flex", flexDirection: "column", gap: "12px", height: "100%", padding: "8px 16px 16px", boxSizing: "border-box", overflowY: "auto" },
  head: { display: "flex", alignItems: "center", gap: "8px" },
  back: { font: "inherit", fontSize: "28px", lineHeight: 1, background: "none", border: 0, color: "var(--color-accent, #8af)", padding: "0 8px 0 0" },
  title: { flex: 1, margin: 0, fontSize: "1.4em", fontWeight: 600 },
  dot: { width: "8px", height: "8px", borderRadius: "50%" },
  row: { display: "flex", gap: "8px" },
  input: { flex: 1, font: "inherit", padding: "10px 12px", borderRadius: "12px", border: "1px solid var(--color-border, #555)", background: "transparent", color: "inherit" },
  button: { font: "inherit", padding: "10px 16px", borderRadius: "12px", border: 0, background: "var(--color-accent, #8af)", color: "var(--color-background, #000)" },
  err: { color: "var(--color-red, #e66)", fontSize: "0.9em" },
  list: { listStyle: "none", margin: 0, padding: 0, display: "flex", flexDirection: "column", gap: "4px" },
  item: { display: "flex", alignItems: "center", gap: "10px", padding: "10px 4px", borderBottom: "1px solid var(--color-border, #333)" },
  check: { width: "20px", height: "20px" },
  x: { font: "inherit", fontSize: "20px", background: "none", border: 0, color: "inherit", opacity: 0.5 },
};
