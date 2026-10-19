/**
 * __NAME__'s home widget: an island in the shell's one shared home page (no WebView of its own), live on the same
 * database as the app's page. A tap opens the app's page (if it has one). Its size in cells: [w, h].
 */
import { useApp, type Props } from "../lib/app";

interface Entry {
  id: bigint;
  text: string;
  done: boolean;
}

export default function Widget({ host, app: id, cells = [4, 2] }: Props) {
  const app = useApp(host);
  const open = app.useTable<Entry>("entry").filter((e) => !e.done).sort((a, b) => Number(a.id - b.id));
  const lines = Math.max(0, cells[1] * 2 - 1);
  return (
    <div style={S.box} onClick={() => host.openApp?.(id)}>
      <div style={S.head}>
        <span style={{ flex: 1 }}>__NAME__</span>
        <span>{app.useStatus() === "connected" ? open.length : "…"}</span>
      </div>
      {open.slice(0, lines).map((e) => (
        <div key={String(e.id)} style={S.line}>{e.text}</div>
      ))}
      {open.length === 0 && <div style={{ opacity: 0.5 }}>Nothing yet</div>}
    </div>
  );
}

const S: Record<string, Record<string, string | number>> = {
  box: { display: "flex", flexDirection: "column", gap: "2px", height: "100%", padding: "10px 14px", boxSizing: "border-box", overflow: "hidden" },
  head: { display: "flex", fontWeight: 600, opacity: 0.85, marginBottom: "2px" },
  line: { whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" },
};
