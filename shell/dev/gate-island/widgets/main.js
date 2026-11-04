// The gate's stand-in island (dev/gate.mjs serves ./_app/gate.<anything>/ from here): proves an island was found and
// its module imported (NI1, nonroot-islands).
import { h } from "preact";
export default function GateIsland({ app }) {
  return h("div", { class: "gate-island" }, `${app} live`);
}
