/**
 * A column that shows only the rows that fit, whole: after each layout, rows from the end are taken out (display:
 * none) until nothing overflows - never a row cut in half by the tile's edge, never a guessed count from cells. The
 * rows left share the height evenly. Measured again when the box resizes (a tile resized, the other screen).
 */
import { useLayoutEffect, useRef } from "preact/hooks";
import type { ComponentChildren } from "preact";

export function Fit({ style, children }: { style?: Record<string, string | number>; children: ComponentChildren }) {
  const ref = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const box = ref.current;
    if (!box) return;
    const fit = () => {
      const rows = [...box.children] as HTMLElement[];
      for (const r of rows) r.style.display = "";
      for (let i = rows.length - 1; i >= 0 && box.scrollHeight > box.clientHeight + 1; i--) rows[i].style.display = "none";
    };
    fit();
    const ro = typeof ResizeObserver === "function" ? new ResizeObserver(fit) : null;
    ro?.observe(box);
    return () => ro?.disconnect();
  });
  return (
    <div ref={ref} style={{ display: "flex", flexDirection: "column", justifyContent: "space-evenly", minHeight: 0, overflow: "hidden", ...style }}>
      {children}
    </div>
  );
}

/**
 * The tile as a size container, for the widget's type to follow: cq units in an element's own styles resolve against
 * an ANCESTOR container, so a box that is its own container and sets fontSize in cqmin measured the page (the
 * viewport - the font pinned at its 22 px cap on every tile, the cover screen's small ones cut). The widget's box goes
 * inside this one.
 */
export function Tile({ children }: { children: ComponentChildren }) {
  return <div style={{ containerType: "size", width: "100%", height: "100%" }}>{children}</div>;
}
