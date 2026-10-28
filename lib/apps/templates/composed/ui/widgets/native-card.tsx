/**
 * __NAME__ - a composed widget (native card), made by `powos compose` from: __WORDS__
 *
 * An Android app's own widget drawn in PowOS's type and glass: its title, big value(s), label, one small picture, a
 * progress bar and list rows, read from the widget's view tree through the bridge (so it never leaves the phone). A tap
 * on a target goes back to the real widget (its own touch handling) - this only reads. While the widget shows nothing
 * we can draw (empty tree) the card falls back to the widget's own pixels. What it shows is ../composition.json.
 */
import { useEffect, useRef, useState } from "preact/hooks";
import type { Props } from "../lib/app";
import { useAndroidBlock, type CardComposition, type WidgetTree } from "../lib/compose";
import composition from "../composition.json";

const C = composition as unknown as CardComposition;
const U = C.uses.find((u) => u.as === C.show.from) ?? C.uses[0];

/** A control's touches are its own: home's long press / drag of the tile doesn't start on it. */
const own = { onPointerDown: (e: Event) => e.stopPropagation() };

function useSize(ref: { current: Element | null }): [number, number] {
  const [s, setS] = useState<[number, number]>([0, 0]);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setS([el.clientWidth, el.clientHeight]));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  return s;
}

/** What the card draws from a tree: the largest-size texts by role, in reading order. */
export function pick(t: WidgetTree) {
  const by = (r: string) => t.texts.filter((x) => x.role === r).sort((a, b) => a.b[1] - b.b[1] || a.b[0] - b.b[0]);
  const values = by("value").sort((a, b) => b.size - a.size).slice(0, 2);
  const title = by("title")[0]?.t;
  const label = by("label")[0]?.t;
  const prog = t.progress.find((p) => !p.indeterminate && p.max > 0);
  const rows = (t.lists.find((l) => l.rows.length)?.rows ?? []).map((r) => r.filter(Boolean).join("  ·  ")).filter(Boolean);
  const image = t.images.slice().sort((a, b) => b.b[2] * b.b[3] - a.b[2] * a.b[3])[0];
  return { values, title, label, prog, rows, image, targets: t.targets.filter((x) => x.label).slice(0, 3) };
}

export default function Widget({ host, cells = [4, 2] }: Props) {
  const box = useRef<HTMLDivElement>(null);
  const [w, h] = useSize(box);
  const b = useAndroidBlock(host, U, [w, h]);
  const tiny = cells[1] < 2;
  const font = Math.min(20, Math.max(12, Math.min(w || 240, (h || 120) * 1.6) * 0.06));
  const t = b.tree;
  const d = t && b.phase === "live" ? pick(t) : null;
  const head = C.show.title || d?.title || C.name;
  const open = () => C.open && host.openApp?.(C.open);
  // A target's centre (dp in the widget) as a fraction of the widget, sent as that fraction of the tile.
  const press = (x: [number, number, number, number]) => {
    if (!t) return;
    void b.tap(((x[0] + x[2] / 2) / t.w) * (w || 1), ((x[1] + x[3] / 2) / t.h) * (h || 1), w || 1, h || 1);
  };
  return (
    <div ref={box} style={{ ...S.box, fontSize: `${font}px` }}>
      {b.phase === "fallback" && b.frame && (
        // The widget's own pixels (shell/AppWidgets.kt): a tap goes to it where it landed.
        <img
          src={b.frame}
          alt=""
          draggable={false}
          style={S.pixels}
          onClick={(e) => {
            const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
            void b.tap(e.clientX - r.left, e.clientY - r.top, [r.width, r.height]);
          }}
        />
      )}
      {b.phase === "loading" && <div style={S.note}>…</div>}
      {(b.phase === "unavailable" || b.phase === "missing") && (
        <div style={S.note}>{b.phase === "missing" ? "Put this widget back on home" : "Update the PowOS app"}</div>
      )}
      {d && (
        <>
          {!tiny && (
            <button type="button" style={S.head} onClick={open} {...own}>
              <span style={S.title}>{head}</span>
              {d.image && b.images[d.image.ref] && <img src={b.images[d.image.ref]} alt="" style={S.thumb} />}
            </button>
          )}
          <div style={S.main}>
            {d.values.map((v, i) => (
              <span key={v.t} style={{ ...S.value, fontSize: `${i === 0 ? 2.1 : 1.2}em`, opacity: i === 0 ? 1 : 0.8 }}>{v.t}</span>
            ))}
            {d.label && <span style={S.label}>{d.label}</span>}
            {tiny && d.image && b.images[d.image.ref] && <img src={b.images[d.image.ref]} alt="" style={S.thumb} />}
          </div>
          {d.prog && (
            <span style={S.track} aria-label={`${Math.round((d.prog.v / d.prog.max) * 100)}%`}>
              <span style={{ ...S.fill, width: `${Math.max(0, Math.min(100, (d.prog.v / d.prog.max) * 100))}%` }} />
            </span>
          )}
          {!tiny && d.rows.length > 0 && (
            <div style={S.list}>
              {d.rows.map((r, i) => (
                <div key={i} style={S.row}>{r}</div>
              ))}
            </div>
          )}
          {!tiny && d.targets.length > 0 && (
            <div style={S.targets}>
              {d.targets.map((x, i) => (
                <button key={i} type="button" style={S.chip} onClick={() => press(x.b)} {...own}>{x.label}</button>
              ))}
            </div>
          )}
        </>
      )}
    </div>
  );
}

const S: Record<string, Record<string, string | number>> = {
  box: {
    containerType: "size", display: "flex", flexDirection: "column", gap: "0.35em", height: "100%", boxSizing: "border-box",
    overflow: "hidden", padding: "0.7em 0.9em", position: "relative",
  },
  pixels: { position: "absolute", inset: 0, width: "100%", height: "100%", objectFit: "contain", borderRadius: "inherit" },
  note: { flex: 1, display: "flex", alignItems: "center", justifyContent: "center", textAlign: "center", color: "var(--color-muted, currentColor)" },
  head: { display: "flex", alignItems: "center", gap: "0.5em", font: "inherit", fontWeight: 600, background: "none", border: 0, color: "inherit", padding: 0, flex: "none", minWidth: 0 },
  title: { flex: 1, minWidth: 0, textAlign: "left", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis", opacity: 0.9 },
  thumb: { flex: "none", width: "1.8em", height: "1.8em", borderRadius: "0.45em", objectFit: "cover" },
  main: { display: "flex", alignItems: "baseline", flexWrap: "wrap", gap: "0.15em 0.6em", flex: "none", minWidth: 0 },
  value: { fontVariantNumeric: "tabular-nums", fontWeight: 600, lineHeight: 1.1, whiteSpace: "nowrap" },
  label: { opacity: 0.65, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis", minWidth: 0 },
  track: { flex: "none", height: "0.4em", borderRadius: "0.2em", overflow: "hidden", background: "color-mix(in srgb, currentColor 14%, transparent)" },
  fill: { display: "block", height: "100%", borderRadius: "0.2em", background: "var(--color-accent, #fc6)" },
  list: { flex: 1, minHeight: 0, display: "flex", flexDirection: "column", gap: "0.2em", overflow: "hidden" },
  row: { padding: "0.2em 0.6em", borderRadius: "0.6em", background: "color-mix(in srgb, currentColor 8%, transparent)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" },
  targets: { display: "flex", gap: "0.4em", flex: "none" },
  chip: { font: "inherit", color: "inherit", border: 0, padding: "0.25em 0.8em", borderRadius: "1em", background: "color-mix(in srgb, currentColor 12%, transparent)", maxWidth: "40%", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" },
};
