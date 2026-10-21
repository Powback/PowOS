/**
 * The pull-up panel over any app (index.html?mode=pull): home's pull-up corners (state.ts pullKind) in the overlay
 * window the host puts over an app - the bottom-right corner's swipe up brings the drawer, the bottom-left's PowOS AI's
 * panel. The same panel as home's: the drawer's frame following the finger (--p), the drawer or PowOS AI's content in
 * it, the pill at its foot. Only tinted: the host blurs the app behind the window (WindowBlur), as the shade's.
 *
 * The host (OverlayHost, the edge gestures) follows the finger: "pull.begin" {kind} as a corner swipe starts,
 * "pull.drag" {p} every frame, "pull.end" {open} when it's let go, "pull.hide" when the window goes. On the panel the
 * swipes are the page's own (gesture.ts: down drags it shut). Shut - let go, Back, a tap beside it, an app launched -
 * the page tells the host (pull.closed / pull.launched) and the window goes.
 */
import { useEffect } from "preact/hooks";
import { computed } from "@preact/signals";
import { powos } from "../bridge.ts";
import { closeDrawer, drawer, pullKind } from "../state.ts";
import { Bar } from "./bar.tsx";
import { Drawer } from "./drawer.tsx";
import { drawerDrag, drawerOpen, drawerShown, followOpenness, homeGestures } from "./gesture.ts";
import { AiContent, AiHeader } from "./powai.tsx";

/** The host's calls (the edge gestures' OverlayHost); an older host has none - then nothing to tell. */
const host = () => (powos as unknown as { pull?: { closed?: () => Promise<void>; launched?: () => Promise<void> } }).pull;

const kindOf = (k: unknown) => (k === "ai" ? "ai" : "apps");
pullKind.value = kindOf(new URLSearchParams(location.search).get("kind"));

powos.on("pull.begin", (e: { kind?: string }) => {
  pullKind.value = kindOf(e?.kind);
  drawerDrag.value = 0;
});
powos.on("pull.drag", (e: { p: number }) => (drawerDrag.value = Math.max(0, Math.min(1, e?.p ?? 0))));
powos.on("pull.end", (e: { open: boolean }) => {
  drawerDrag.value = null;
  if (e?.open) drawer.value = 1;
  else closeDrawer();
});
powos.on("pull.hide", () => {
  drawerDrag.value = null;
  closeDrawer();
});

/** A finger on the panel: a render when that starts and ends, not one for every frame of the drag. */
const pullDragging = computed(() => drawerDrag.value != null);

/** How long the panel takes to settle shut (gesture.ts / shell.css --p transition) before the window can go. */
const SETTLE_MS = 300;

export function Pull() {
  const open = drawerOpen.value;
  // Shut and settled - let go, Back, a tap beside it, an app launched from it (state.ts launch closes the drawer) - the
  // host hides the window.
  useEffect(() => {
    if (open) return;
    const t = window.setTimeout(() => drawerShown() === 0 && void host()?.closed?.(), SETTLE_MS);
    return () => clearTimeout(t);
  }, [open]);
  return (
    <div class={`home pull-screen ${open ? "open" : ""} ${pullDragging.value ? "dragging" : ""}`} {...homeGestures()}>
      <div class="stage">
        <div class="launcher" data-p ref={followOpenness}>
          <div class="launcher-frame tile" />
          <div class="launcher-inner">
            <div class="drawer-clip">
              {pullKind.value === "ai" ? (
                <div class="ai-panel">
                  <AiHeader />
                  <AiContent shown={open} />
                </div>
              ) : (
                <Drawer />
              )}
            </div>
          </div>
        </div>
      </div>
      <Bar />
    </div>
  );
}
