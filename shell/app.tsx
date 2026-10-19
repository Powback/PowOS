/** The shell: the host's insets as CSS, its state loaded, home mounted. */
import { render } from "preact";
import { powos } from "./bridge.ts";
import { load } from "./state.ts";
import { Home } from "./ui/home.tsx";
import type { Insets } from "./types.ts";
import "./hot.ts";

/** The host's insets (system bars, cutout, keyboard) as --inset-* custom properties, kept current. */
function applyInsets(i: Partial<Insets> | null) {
  const root = document.documentElement.style;
  for (const side of ["top", "bottom", "left", "right", "keyboard"] as const) root.setProperty(`--inset-${side}`, `${i?.[side] ?? 0}px`);
}
powos.on("system.insets", applyInsets);
applyInsets(await powos.system.insets());

await load();
render(<Home />, document.body);
