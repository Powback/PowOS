// The gate's stand-in for the razr's test island (TH1, island-hold): its root is its own size container with its type in
// cqmin (the app template's pattern), and its one control eats pointerdown as the template tells controls to. Home's
// long press must still lift the tile from that control, a tap must stay the control's, and cqmin must measure the tile.
import { h } from "preact";
import { useState } from "preact/hooks";
export default function GateHold() {
  const [n, setN] = useState(0);
  return h(
    "div",
    { class: "gate-hold", style: { containerType: "size", fontSize: "12cqmin", width: "100%", height: "100%", display: "flex" } },
    h("button", { type: "button", style: { flex: 1, font: "inherit" }, onPointerDown: (e) => e.stopPropagation(), onClick: () => setN((k) => k + 1) }, `taps ${n}`),
  );
}
