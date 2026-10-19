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
  location.reload();
});
