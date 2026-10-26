/**
 * Hot reload: the host sends "files.changed" ({ path }, relative to the shell) when a file is saved. A stylesheet is
 * swapped in place; anything else reloads the page, which reads its state from the host again. Re-importing single
 * modules in place would keep more state, but ES modules can't be replaced under their importers - a page reload is
 * fast at this size, and always right.
 */
import { powos } from "./bridge.ts";
import { appChanged } from "./apps/pages.ts";

powos.on("files.changed", ({ path }: { path: string }) => {
  // A PowOS app's installed UI (`powos app ui`/`dev`): its page and widgets are imported again in place - the shell
  // page isn't reloaded (apps/pages.ts).
  if (path.startsWith("_app/")) {
    const id = path.split("/")[1];
    if (id) appChanged(id);
    return;
  }
  // push.sh's commit marker (.pushing, there while a push's files are moved in): the files themselves reload the page.
  if (path.startsWith(".")) return;
  // The shell's dev and test files (dev/: the mock's data; test/: the gate-test page): no live page loads them.
  if (path.startsWith("dev/") || path.startsWith("test/")) return;
  if (path.endsWith(".css")) {
    // Not on screen: a stylesheet swapped then never loaded its new sheet (the WebView doesn't load while hidden) and
    // the page was left with none - home unstyled. Swapped once it shows instead.
    if (document.hidden) pendingCss.add(path);
    else swapCss(path);
    return;
  }
  reload();
});

const pendingCss = new Set<string>();
function swapCss(path: string) {
  for (const link of document.querySelectorAll<HTMLLinkElement>("link[rel=stylesheet][data-hot]")) {
    const href = link.getAttribute("href")!.split("?")[0];
    if (path.endsWith(href.replace(/^\.\//, ""))) link.href = `${href}?t=${Date.now()}`;
  }
}
document.addEventListener("visibilitychange", () => {
  if (document.hidden) return;
  pendingCss.forEach(swapCss);
  pendingCss.clear();
});

/**
 * A WebView that isn't on screen (the shell behind an app, the screen off) doesn't navigate: a reload asked for then
 * is lost, and a stylesheet swapped meanwhile then lays new styles over old modules. It waits for the shell to show.
 */
let pending = false;
let timer = 0;
/** Once the changes stop: a push of several files reloads once, after the last one is written. */
function reload() {
  clearTimeout(timer);
  timer = window.setTimeout(() => {
    if (document.hidden) pending = true;
    else location.reload();
  }, 300);
}
document.addEventListener("visibilitychange", () => {
  if (pending && !document.hidden) location.reload();
});
