/**
 * Hot reload: the host sends "files.changed" ({ path }, relative to the shell) when a file is saved. A stylesheet is
 * swapped in place; anything else reloads the page, which reads its state from the host again. Re-importing single
 * modules in place would keep more state, but ES modules can't be replaced under their importers - a page reload is
 * fast at this size, and always right.
 */
import { powos } from "./bridge.ts";

powos.on("files.changed", ({ path }: { path: string }) => {
  if (path.endsWith(".css")) {
    for (const link of document.querySelectorAll<HTMLLinkElement>("link[rel=stylesheet][data-hot]")) {
      const href = link.getAttribute("href")!.split("?")[0];
      if (path.endsWith(href.replace(/^\.\//, ""))) link.href = `${href}?t=${Date.now()}`;
    }
    return;
  }
  reload();
});

/**
 * A WebView that isn't on screen (the shell behind an app, the screen off) doesn't navigate: a reload asked for then
 * is lost, and a stylesheet swapped meanwhile then lays new styles over old modules. It waits for the shell to show.
 */
let pending = false;
function reload() {
  if (document.hidden) pending = true;
  else location.reload();
}
document.addEventListener("visibilitychange", () => {
  if (pending && !document.hidden) location.reload();
});
