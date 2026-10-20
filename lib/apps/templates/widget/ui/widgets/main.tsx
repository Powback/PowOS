/**
 * __NAME__'s home widget: usable in place, not a preview - tick entries off, remove them, add new ones right here;
 * the header opens the app's page. An island in the shell's one shared home page (no WebView of its own), live on the
 * same database as the page. Its size in cells: [w, h].
 */
import { useState } from "preact/hooks";
import { useApp, type Props } from "../lib/app";

interface Entry {
  id: bigint;
  text: string;
  done: boolean;
}

/** A control's touches are its own: home's long press / drag of the tile doesn't start on it. */
const own = { onPointerDown: (e: Event) => e.stopPropagation() };

export default function Widget({ host, app: id, cells = [4, 2] }: Props) {
  const app = useApp(host);
  const entries = app.useTable<Entry>("entry").sort((a, b) => Number(a.done) - Number(b.done) || Number(a.id - b.id));
  const add = app.useReducer<{ text: string }>("add");
  const toggle = app.useReducer<{ id: bigint }>("toggle");
  const remove = app.useReducer<{ id: bigint }>("remove");
  const [text, setText] = useState("");
  const [err, setErr] = useState<string | null>(null);
  const run = (p: Promise<unknown>) => p.then(() => setErr(null), (e) => setErr(String(e?.message ?? e)));
  // Rows that fit: the header and the add field take one each.
  const lines = Math.max(0, cells[1] * 2 - 2);
  const open = entries.filter((e) => !e.done).length;
  return (
    <div style={S.box}>
      <button type="button" style={S.head} onClick={() => host.openApp?.(id)}>
        <span style={{ flex: 1, textAlign: "left" }}>__NAME__</span>
        <span>{app.useStatus() === "connected" ? open : "…"} ›</span>
      </button>
      {entries.slice(0, lines).map((e) => (
        <div key={String(e.id)} style={S.row}>
          <input type="checkbox" checked={e.done} onChange={() => run(toggle({ id: e.id }))} {...own} style={S.check} />
          <span style={{ ...S.text, opacity: e.done ? 0.5 : 1, textDecoration: e.done ? "line-through" : "none" }}>{e.text}</span>
          <button type="button" style={S.x} onClick={() => run(remove({ id: e.id }))} {...own} aria-label="remove">
            ×
          </button>
        </div>
      ))}
      {entries.length > lines && <div style={{ opacity: 0.6 }}>+{entries.length - lines} more</div>}
      <form
        style={S.row}
        onSubmit={(e) => {
          e.preventDefault();
          if (text.trim()) run(add({ text }).then(() => setText("")));
        }}
      >
        <input
          value={text}
          onInput={(e) => setText((e.target as HTMLInputElement).value)}
          placeholder={err ?? "add…"}
          enterKeyHint="done"
          {...own}
          style={S.input}
        />
      </form>
    </div>
  );
}

const S: Record<string, Record<string, string | number>> = {
  box: { display: "flex", flexDirection: "column", gap: "2px", height: "100%", padding: "8px 12px", boxSizing: "border-box", overflow: "hidden" },
  head: { display: "flex", font: "inherit", fontWeight: 600, opacity: 0.85, background: "none", border: 0, color: "inherit", padding: "0 0 2px" },
  row: { display: "flex", alignItems: "center", gap: "8px", minHeight: "26px" },
  check: { width: "18px", height: "18px", margin: 0 },
  text: { flex: 1, minWidth: 0, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" },
  x: { font: "inherit", fontSize: "18px", background: "none", border: 0, color: "inherit", opacity: 0.5, padding: "0 4px" },
  input: { flex: 1, minWidth: 0, font: "inherit", padding: "4px 8px", borderRadius: "8px", border: "1px solid var(--color-border, #555)", background: "transparent", color: "inherit" },
};
