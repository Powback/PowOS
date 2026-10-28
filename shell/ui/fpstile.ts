/** The control center's "fps meter" switch (Tools): writes store perf.meter, which every shell window listens to. */
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import type { QuickTile } from "../types.ts";

export const FPS_ID = "powos.fps";
const on = signal<boolean | null>(null);
powos.on("perf.meter", (v: { on?: boolean } | null) => (on.value = v?.on !== false));

/** Reads the real state (while the shade shows). */
export function askFps() {
  powos.store.get<{ on?: boolean }>("perf.meter").then((v) => (on.value = v?.on !== false), () => {});
}

export function fpsTile(): QuickTile {
  return { id: FPS_ID, label: "fps meter", on: !!on.value, detail: on.value ? "on" : "off" };
}

/** Flips at once; a failed write puts it back. */
export function toggleFps() {
  const was = !!on.value;
  on.value = !was;
  powos.store.set("perf.meter", { on: !was }).catch(() => (on.value = was));
}
