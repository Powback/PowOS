/** Dedicated entry for the small host windows: no home, registry or widget boot. */
import { render } from "preact";
import { powos } from "./bridge.ts";
import { WindowBar, WindowGrip, StatusBar } from "./ui/chrome.tsx";
import { loadTheme } from "./ui/theme.ts";
import "./ui/uifont.ts";
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
// The recording ring (a [data-action] fixed on the cutout) comes and goes without resizing the body: its region is
// re-sent once it's drawn, so the strip takes its tap (StatusChrome.regions).
let lastRecording: ChromeState["recording"];
powos.on("chrome.changed", (state: ChromeState) => {
  draw(state);
  if ((state.recording ?? null) === (lastRecording ?? null)) return;
  lastRecording = state.recording;
  requestAnimationFrame(() => { void regions().catch(console.error); });
});
draw(await powos.chrome.state());
function regions() {
  return powos.chrome.regions([...document.querySelectorAll<HTMLElement>("[data-action]")].map((e) => {
    const r = e.getBoundingClientRect();
    return { action: e.dataset.action!, x: r.x, y: r.y, width: r.width, height: r.height };
  }));
}
const observer = new ResizeObserver(() => { void regions().catch(console.error); });
observer.observe(document.body);
window.addEventListener("fps-layout", () => { requestAnimationFrame(() => { void regions().catch(console.error); }); });
await new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve())));
await regions();
(window as unknown as { __powosAlive?: boolean }).__powosAlive = true;
await powos.chrome.ready();
