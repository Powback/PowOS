/** App API's few controls, in the shell's tokens: soft fills on the frost, the accent only on what is on, no lines. */
import type { ComponentChildren } from "preact";

export function Switch({ on, label, onFlip }: { on: boolean; label: string; onFlip: (on: boolean) => void }) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={on}
      aria-label={label}
      style={{ ...S.track, background: on ? "var(--color-accent)" : "var(--control-fill, var(--soft-fill))" }}
      onClick={(e) => (e.stopPropagation(), onFlip(!on))}
    >
      <span style={{ ...S.knob, transform: on ? "translateX(18px)" : "none" }} />
    </button>
  );
}

export function Seg({ options, picked, onPick }: { options: string[]; picked: string; onPick: (o: string) => void }) {
  return (
    <div style={S.seg} role="tablist">
      {options.map((o) => (
        <button
          type="button"
          role="tab"
          key={o}
          aria-selected={o === picked}
          style={o === picked ? { ...S.segBtn, ...S.segOn } : S.segBtn}
          onClick={() => onPick(o)}
        >
          {o}
        </button>
      ))}
    </div>
  );
}

/** Generated text (a view, a request): monospace, wrapped - never a sideways scroll. */
export const Block = ({ children }: { children: ComponentChildren }) => <pre style={S.block}>{children}</pre>;

/** An action id as a plain title: "list_rooms" -> "List rooms" (the id itself shows muted under it). */
export const title = (id: string) => {
  const t = id.replace(/[_-]+/g, " ").trim();
  return t.charAt(0).toUpperCase() + t.slice(1);
};

export const Muted = ({ children }: { children: ComponentChildren }) => <div style={S.muted}>{children}</div>;

export const S: Record<string, Record<string, string | number>> = {
  page: { display: "flex", flexDirection: "column", gap: "12px", height: "100%", padding: "8px 16px 24px", boxSizing: "border-box", overflowY: "auto" },
  head: { display: "flex", alignItems: "center", gap: "8px", minHeight: "44px" },
  back: { font: "inherit", fontSize: "28px", lineHeight: 1, background: "none", border: 0, color: "inherit", padding: "0 8px 0 0" },
  title: { flex: 1, margin: 0, fontSize: "1.4em", fontWeight: 600 },
  card: { display: "flex", flexDirection: "column", gap: "6px", padding: "12px", borderRadius: "var(--radius, 12px)", background: "var(--soft-fill)" },
  row: { display: "flex", alignItems: "center", gap: "12px" },
  grow: { flex: 1, minWidth: 0 },
  name: { fontWeight: 600 },
  // The accent fill carries the dark foreground (the background colour), as the shell's own on-states do
  // (rich.css .choice-opt.on): --accent-text is accent-tinted text for neutral ground, pale on the fill.
  id: { fontFamily: "var(--font, monospace)", fontWeight: 600, overflowWrap: "anywhere" },
  idMuted: { fontFamily: "var(--font, monospace)", color: "var(--color-muted)", fontSize: "var(--text-small, 0.85em)", overflowWrap: "anywhere" },
  muted: { color: "var(--color-muted)", fontSize: "var(--text-small, 0.9em)" },
  group: { margin: "8px 0 0", fontSize: "1em", fontWeight: 600 },
  track: { position: "relative", flex: "none", width: "44px", height: "26px", borderRadius: "13px", border: 0, padding: 0 },
  knob: { position: "absolute", top: "3px", left: "3px", width: "20px", height: "20px", borderRadius: "50%", background: "var(--color-foreground)", transition: "transform 160ms" },
  seg: { display: "flex", gap: "4px", padding: "4px", borderRadius: "20px", background: "var(--soft-fill)", flexWrap: "wrap" },
  segBtn: { flex: "1 0 auto", font: "inherit", padding: "8px 12px", borderRadius: "16px", border: 0, background: "none", color: "inherit" },
  segOn: { background: "var(--color-accent)", color: "var(--color-background)" },
  block: { margin: 0, padding: "10px 12px", borderRadius: "8px", background: "var(--soft-fill)", fontFamily: "var(--font, monospace)", fontSize: "var(--text-small, 0.85em)", whiteSpace: "pre-wrap", overflowWrap: "anywhere" },
  btn: { font: "inherit", padding: "10px 16px", borderRadius: "20px", border: 0, background: "var(--soft-fill)", color: "inherit" },
  btnOn: { background: "var(--color-accent)", color: "var(--color-background)" },
  field: { flex: 1, minWidth: 0, font: "inherit", padding: "8px 12px", borderRadius: "8px", border: 0, background: "var(--soft-fill)", color: "inherit" },
  bad: { color: "var(--color-red)" },
};
