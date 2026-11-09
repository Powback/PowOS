/**
 * Hacks on home: "Hacks: N open" and the hacks themselves, oldest first, one plain line each (what each works around).
 * The list is the HACK registry (docs/REMOTE-POWOS.md §4) as of the last ship (module `hack`, synced by
 * `powos progress hacks sync` from tools/phone/ship.sh): a hack leaves it when its registry row goes. Tap: the page,
 * on the hacks.
 */
import { age, hackLine, setFocus, useHacks } from "../lib/progress";
import type { Props } from "../lib/app";
import { Fit } from "../lib/fit";

const own = { onPointerDown: (e: Event) => e.stopPropagation() };

export default function Hacks({ host, app: id, cells }: Props) {
  const { status, hacks } = useHacks(host);
  const [cols] = cells ?? [2, 2];
  const open = () => {
    setFocus("hacks");
    host.openApp?.(id);
  };
  const live = status === "connected";
  return (
    <button type="button" style={S.box} onClick={open} {...own}>
      <div style={S.head}>
        <span style={S.label}>Hacks</span>
        <span style={S.count}>{live ? hacks.length : "–"}</span>
        <span style={S.label}>open</span>
      </div>
      <Fit style={{ flex: "1 1 0" }}>
        {hacks.length ? (
          hacks.slice(0, 12).map((h) => (
            <div key={h.key} style={S.row}>
              <span style={S.line}>{hackLine(h)}</span>
              {cols >= 3 && <span style={S.age}>{age(h.since)}</span>}
            </div>
          ))
        ) : (
          <span style={{ ...S.line, opacity: 0.6 }}>{live ? "none known" : "…"}</span>
        )}
      </Fit>
    </button>
  );
}

const S: Record<string, Record<string, string | number>> = {
  box: {
    containerType: "size", display: "flex", flexDirection: "column", justifyContent: "space-between", gap: "0.35em", width: "100%", height: "100%", padding: "0.7em 0.9em",
    boxSizing: "border-box", overflow: "hidden", lineHeight: 1.25,
    font: "inherit", fontSize: "clamp(9px, 6.4cqmin, 22px)", background: "none", border: 0, color: "inherit", textAlign: "left",
  },
  head: { display: "flex", alignItems: "baseline", gap: "0.35em", flex: "none", fontSize: "min(1em, 9cqw)" },
  label: { fontWeight: 600, opacity: 0.8 },
  count: { fontSize: "min(2.4em, 34cqh)", fontWeight: 700, lineHeight: 1, fontVariantNumeric: "tabular-nums" },
  row: { display: "flex", alignItems: "baseline", gap: "0.6em", fontSize: "0.85em", width: "100%", flex: "none" },
  line: { flex: "1 1 0", minWidth: 0, overflowWrap: "anywhere" },
  age: { flex: "none", marginLeft: "auto", opacity: 0.55, fontSize: "0.9em", fontVariantNumeric: "tabular-nums" },
};
