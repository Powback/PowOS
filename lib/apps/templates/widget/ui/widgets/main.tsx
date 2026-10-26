/**
 * __NAME__'s home widget: usable in place, not a preview - tick entries off, remove them, add new ones right here;
 * the header opens the app's page. An island in the shell's one shared home page (no WebView of its own), live on the
 * same database as the page. Its size in cells: [w, h].
 *
 * It fills its tile at every size, by default (the widget preview, `powos app preview`, checks every size from the
 * manifest's minSize to 4x4 on both of the phone's screens and fails a widget that clips, leaves a side empty or is
 * small in a big tile):
 * - the box is a size container: text and controls are in em of a font that follows the tile (cqmin), so a big tile
 *   is big content, not small content in a lot of glass;
 * - the list takes the height that's left and its rows share it (up to ~1.6 lines each); more rows than fit scroll up
 *   and down in whole rows (pan-y + snap: a home tile's own gesture) - never a count guessed from cells;
 * - nothing is drawn with a line: fields and chips are a soft fill.
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

export default function Widget({ host, app: id }: Props) {
  const app = useApp(host);
  const entries = app.useTable<Entry>("entry").sort((a, b) => Number(a.done) - Number(b.done) || Number(a.id - b.id));
  const add = app.useReducer<{ text: string }>("add");
  const toggle = app.useReducer<{ id: bigint }>("toggle");
  const remove = app.useReducer<{ id: bigint }>("remove");
  const [text, setText] = useState("");
  const [err, setErr] = useState<string | null>(null);
  const run = (p: Promise<unknown>) => p.then(() => setErr(null), (e) => setErr(String(e?.message ?? e)));
  const open = entries.filter((e) => !e.done).length;
  return (
    <div style={S.box}>
      <button type="button" style={S.head} onClick={() => host.openApp?.(id)}>
        <span style={{ flex: 1, textAlign: "left" }}>__NAME__</span>
        <span>{app.useStatus() === "connected" ? open : "…"} ›</span>
      </button>
      <div style={S.list} {...own}>
        {entries.map((e) => (
          <div key={String(e.id)} style={S.row}>
            <input type="checkbox" checked={e.done} onChange={() => run(toggle({ id: e.id }))} {...own} style={S.check} />
            <span style={{ ...S.text, opacity: e.done ? 0.5 : 1, textDecoration: e.done ? "line-through" : "none" }}>{e.text}</span>
            <button type="button" style={S.x} onClick={() => run(remove({ id: e.id }))} {...own} aria-label="remove">
              ×
            </button>
          </div>
        ))}
      </div>
      <form
        style={S.add}
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
  // The tile's size drives the type: 13 px on a small tile, up to 22 px on the inner screen's big ones.
  box: {
    containerType: "size", display: "flex", flexDirection: "column", gap: "0.3em", height: "100%", padding: "0.6em 0.9em",
    boxSizing: "border-box", overflow: "hidden", fontSize: "clamp(13px, 6cqmin, 22px)",
  },
  head: { display: "flex", font: "inherit", fontWeight: 600, opacity: 0.85, background: "none", border: 0, color: "inherit", padding: 0 },
  // The rows share what's left of the height; more than fit scroll in whole rows.
  list: { flex: 1, minHeight: 0, display: "flex", flexDirection: "column", overflowY: "auto", scrollSnapType: "y mandatory", touchAction: "pan-y", scrollbarWidth: "none" },
  row: { display: "flex", alignItems: "center", gap: "0.6em", flex: "1 0 2em", maxHeight: "3.2em", scrollSnapAlign: "start" },
  check: { width: "1.2em", height: "1.2em", margin: 0, flex: "none" },
  text: { flex: 1, minWidth: 0, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" },
  x: { font: "inherit", fontSize: "1.3em", background: "none", border: 0, color: "inherit", opacity: 0.5, padding: "0 0.2em" },
  add: { display: "flex", flex: "none" },
  input: {
    flex: 1, minWidth: 0, font: "inherit", padding: "0.35em 0.7em", borderRadius: "0.7em", border: 0,
    background: "color-mix(in srgb, currentColor 8%, transparent)", color: "inherit",
  },
};
