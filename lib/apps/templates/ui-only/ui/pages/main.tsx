/**
 * __NAME__'s full-screen page: what opens from the drawer, search and the recent apps. Edit and save: `powos app dev`
 * rebuilds it and the open page updates in place. A UI-only app: its state is useStored (ui/lib/app.ts).
 */
import { useStored, type Props } from "../lib/app";

export default function Main({ app, close }: Props) {
  const [count, setCount] = useStored(app, "count", 0);
  return (
    <div style={S.page}>
      <header style={S.head}>
        <button type="button" style={S.back} onClick={close} aria-label="back">‹</button>
        <h1 style={S.title}>__NAME__</h1>
      </header>
      <div style={S.count}>{count}</div>
      <div style={S.row}>
        <button type="button" style={S.button} onClick={() => setCount(count - 1)} aria-label="less">−</button>
        <button type="button" style={S.button} onClick={() => setCount(count + 1)} aria-label="more">+</button>
      </div>
      <button type="button" style={{ ...S.button, alignSelf: "center", opacity: 0.7 }} onClick={() => setCount(0)}>Reset</button>
    </div>
  );
}

const S: Record<string, Record<string, string | number>> = {
  page: { display: "flex", flexDirection: "column", gap: "16px", height: "100%", padding: "8px 16px 16px", boxSizing: "border-box", overflowY: "auto" },
  head: { display: "flex", alignItems: "center", gap: "8px" },
  back: { font: "inherit", fontSize: "28px", lineHeight: 1, background: "none", border: 0, color: "var(--color-accent, #8af)", padding: "0 8px 0 0" },
  title: { flex: 1, margin: 0, fontSize: "1.4em", fontWeight: 600 },
  count: { fontSize: "64px", fontWeight: 600, textAlign: "center", fontVariantNumeric: "tabular-nums" },
  row: { display: "flex", gap: "12px", justifyContent: "center" },
  button: { font: "inherit", fontSize: "20px", minWidth: "64px", padding: "10px 16px", borderRadius: "12px", border: 0, background: "var(--color-accent, #8af)", color: "var(--color-background, #000)" },
};
