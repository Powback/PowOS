/** Dedicated entry for the small host windows: no home, registry or widget boot. */
import { render } from "preact";
import { powos } from "./bridge.ts";
import { WindowBar, WindowGrip, StatusBar } from "./ui/chrome.tsx";
import { loadTheme } from "./ui/theme.ts";
import type { ChromeState } from "./types.ts";
import "./hot.ts";
import "./ui/glass.ts";

const mode = new URLSearchParams(location.search).get("mode") ?? "windowbar";
document.documentElement.dataset.mode = mode;
const css = document.createElement("link");
css.rel = "stylesheet";
css.href = "./ui/chrome.css";
css.dataset.hot = "";
const styled = new Promise<void>((resolve, reject) => { css.onload = () => resolve(); css.onerror = () => reject(new Error("chrome stylesheet failed")); });
document.head.append(css);
await Promise.all([loadTheme(), styled]);
const action = (name: string) => { void powos.chrome.action(name).catch(console.error); };
function draw(state: ChromeState) {
  render(state.kind === "status" ? <StatusBar state={state} action={action} /> : state.kind === "grip" ? <WindowGrip /> : <WindowBar state={state} action={action} />, document.body);
}
powos.on("chrome.changed", draw);
draw(await powos.chrome.state());
const regions = () => powos.chrome.regions([...document.querySelectorAll<HTMLElement>("[data-action]")].map((e) => {
  const r = e.getBoundingClientRect();
  return { action: e.dataset.action!, x: r.x, y: r.y, width: r.width, height: r.height };
}));
const observer = new ResizeObserver(() => { void regions().catch(console.error); });
observer.observe(document.body);
await new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve())));
await regions();
(window as unknown as { __powosAlive?: boolean }).__powosAlive = true;
await powos.chrome.ready();
