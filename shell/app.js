/** The shell: loads the host's state and mounts home. */
import { render } from "preact";
import { html } from "./ui/html.js";
import { Home } from "./ui/home.js";
import { load } from "./state.js";
import "./hot.js";

const style = document.createElement("link");
style.rel = "stylesheet";
style.href = "./ui/shell.css";
style.dataset.hot = "";
document.head.append(style);

await load();
render(html`<${Home} />`, document.body);
