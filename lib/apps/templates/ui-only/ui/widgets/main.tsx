/**
 * __NAME__'s home widget: an island in the shell's home page, live on the same stored value as the page (useStored).
 * A tap opens the page. It has no controls of its own, so home's long press (move, resize, remove) always reaches the
 * tile; a control you add stops pointerdown propagating (`onPointerDown={(e) => e.stopPropagation()}`), keep it small.
 *
 * It fills its tile at every size: the outer box is the size container, the inner one takes a font in cqmin of it (a
 * cqmin font on the container itself resolves against the viewport instead, and blows up).
 */
import { useStored, type Props } from "../lib/app";

export default function Widget({ host, app }: Props) {
  const [count] = useStored(app, "count", 0);
  return (
    <div style={S.box}>
      <button type="button" style={S.inner} onClick={() => host.openApp?.(app)}>
        <span style={S.name}>__NAME__</span>
        <span style={S.count}>{count}</span>
      </button>
    </div>
  );
}

const S: Record<string, Record<string, string | number>> = {
  box: { containerType: "size", height: "100%", boxSizing: "border-box", overflow: "hidden" },
  inner: {
    display: "flex", flexDirection: "column", justifyContent: "space-between", width: "100%", height: "100%",
    padding: "0.6em 0.9em", boxSizing: "border-box", font: "inherit", fontSize: "clamp(13px, 8cqmin, 28px)",
    background: "none", border: 0, color: "inherit", textAlign: "left",
  },
  name: { fontWeight: 600, opacity: 0.85, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" },
  count: { fontSize: "2.2em", fontWeight: 600, fontVariantNumeric: "tabular-nums" },
};
