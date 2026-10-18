/** The shell: loads the host's state and mounts home. */
import { render } from "preact";
import { html } from "./ui/html.js";
import { Home } from "./ui/home.js";
import { load } from "./state.js";
import { powos } from "./bridge.js";
import "./hot.js";

const style = document.createElement("link");
style.rel = "stylesheet";
style.href = "./ui/shell.css";
style.dataset.hot = "";
document.head.append(style);

/** The host's insets (system bars, cutout, keyboard) as --inset-* custom properties, kept current. */
function applyInsets(i) {
  const root = document.documentElement.style;
  for (const side of ["top", "bottom", "left", "right", "keyboard"]) root.setProperty(`--inset-${side}`, `${i?.[side] ?? 0}px`);
}
powos.on("system.insets", applyInsets);
applyInsets(await powos.system.insets());

await load();
render(html`<${Home} />`, document.body);
