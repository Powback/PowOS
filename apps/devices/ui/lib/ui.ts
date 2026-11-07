/** Devices' styles, in the shell's tokens (docs/DESIGN-LANGUAGE.md): soft fills, the accent only on what's in flight. */
export const KIND: Record<string, string> = { desktop: "PC", phone: "Phone", server: "Server", tv: "TV", laptop: "Laptop", mac: "Mac" };

export const S: Record<string, Record<string, string | number>> = {
  page: { display: "flex", flexDirection: "column", gap: "var(--gap, 8px)", height: "100%", padding: "8px var(--edge, 16px) 24px", fontFamily: "var(--font-body)", boxSizing: "border-box", overflowY: "auto" },
  head: { display: "flex", alignItems: "center", gap: "8px", minHeight: "44px" },
  back: { font: "inherit", fontSize: "28px", lineHeight: 1, background: "none", border: 0, color: "inherit", padding: "0 8px 0 0" },
  title: { flex: 1, margin: 0, fontSize: "1.4em", fontWeight: 600 },
  card: { display: "flex", flexDirection: "column", gap: "10px", padding: "12px", borderRadius: "var(--radius, 12px)", background: "var(--soft-fill)" },
  row: { display: "flex", alignItems: "center", gap: "12px" },
  grow: { flex: 1, minWidth: 0 },
  name: { fontWeight: 600 },
  muted: { color: "var(--color-muted)", fontSize: "var(--text-small, 0.9em)" },
  dot: { flex: "none", width: "10px", height: "10px", borderRadius: "50%", transition: "background var(--spring-fast-ms) var(--spring-fast)" },
  actions: { display: "flex", flexWrap: "wrap", gap: "8px" },
  btn: { font: "inherit", padding: "10px 16px", borderRadius: "20px", border: 0, background: "var(--control-fill, var(--soft-fill))", color: "inherit", transition: "background var(--spring-fast-ms) var(--spring-fast)" },
  btnOn: { background: "var(--color-accent)", color: "var(--color-background)" },
  ghost: { font: "inherit", padding: "8px 10px", border: 0, background: "none", color: "var(--color-muted)" },
  error: { display: "flex", flexDirection: "column", gap: "8px", color: "var(--status-needs)" },
  okText: { color: "var(--status-working)", fontSize: "var(--text-small, 0.9em)" },
  joinCard: { boxShadow: "inset 0 0 0 1.5px var(--color-accent)" },
  joinRow: { display: "flex", flexDirection: "column", gap: "6px", paddingTop: "8px" },
  joinCode: { fontSize: "2.2em", fontWeight: 600, letterSpacing: "0.12em", fontVariantNumeric: "tabular-nums", lineHeight: 1.1 },
  confirm: { display: "flex", flexDirection: "column", gap: "8px" },
  errorText: { color: "var(--status-needs)", fontSize: "var(--text-small, 0.9em)" },
  field: { flex: "1 1 auto", width: "100%", minWidth: 0, boxSizing: "border-box", font: "inherit", padding: "8px 12px", borderRadius: "8px", border: 0, background: "var(--control-fill, var(--soft-fill))", color: "inherit" },
  found: { font: "inherit", textAlign: "left", padding: "10px 12px", borderRadius: "var(--radius, 12px)", border: 0, background: "var(--control-fill, var(--soft-fill))", color: "inherit" },
};
