/**
 * The shade (index.html?mode=shade): PowOS's notification panel (notifications.tsx, the same as home's) in the system
 * window the native shade host puts over everything - the stock shade's place. The host follows the finger on the top
 * edge ("shade.drag", "shade.settle"); on the panel, swipes are the page's own (gesture.ts: up drags it shut, cards
 * slide away). Once it's shut the host hides the window (shade.closed).
 */
import { useEffect } from "preact/hooks";
import { powos } from "../bridge.ts";
import { notif } from "../state.ts";
import { homeGestures, notifDrag, notifShown } from "./gesture.ts";
import { NotificationPanel } from "./notifications.tsx";

powos.on("shade.drag", ({ q }: { q: number }) => (notifDrag.value = Math.max(0, Math.min(1, q))));
powos.on("shade.settle", ({ open }: { open: boolean }) => {
  notifDrag.value = null;
  notif.value = open;
});

export function Shade() {
  // Shut (and not being pulled): the window goes away until the next pull.
  const shut = notifShown() === 0;
  useEffect(() => {
    if (!shut) return;
    const t = window.setTimeout(() => notifShown() === 0 && powos.shade.closed(), 300);
    return () => clearTimeout(t);
  }, [shut]);
  return (
    <div class="home shade-screen" {...homeGestures()}>
      <NotificationPanel />
    </div>
  );
}
