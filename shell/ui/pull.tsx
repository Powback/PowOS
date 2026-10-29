/**
 * The launcher: one overlay, as the notification shade is (index.html?mode=pull, PullHost.kt) - its own window over
 * whatever shows (home, an app, floating windows), for every way in: a swipe up on home's body or the pill (home hands
 * the host the finger, as its swipe down hands the shade its pull: Bridge.pull.homePull / open), the bottom corners
 * over an app or home (CornerPull.kt), an edge gesture's "app drawer". Home has no drawer of its own. The bottom-right
 * corner's swipe up brings the drawer, the bottom-left's PowOS AI's panel. The same panel as home's: the drawer's frame following the finger (--p), the drawer or PowOS AI's content in
 * it, the pill at its foot. Only tinted: the host blurs the app behind the window (WindowBlur), as the shade's.
 *
 * The host (OverlayHost, the edge gestures) follows the finger: "pull.begin" {kind} as a corner swipe starts,
 * "pull.drag" {p} every frame, "pull.end" {open} when it's let go, "pull.hide" when the window goes. On the panel the
 * swipes are the page's own (gesture.ts: down drags it shut). Shut - let go, Back, a tap beside it, an app launched -
 * the page tells the host (pull.closed / pull.launched) and the window goes.
 */
import { useEffect } from "preact/hooks";
import { computed, signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import { aiDraft, chatting, closeDrawer, dockPosition, drawer, pullKind, type LauncherOpen } from "../state.ts";
import { AppMenu } from "./apps.tsx";
import { openAssistant } from "./assistant.ts";
import { wideHome } from "../hosts/wide.ts";
import { Bar } from "./bar.tsx";
import { Drawer } from "./drawer.tsx";
import { Dock } from "./home.tsx";
import { drawerDrag, drawerOpen, drawerShown, followOpenness, homeGestures } from "./gesture.ts";
import { AiView } from "./powai.tsx";

/** The host's calls (the edge gestures' OverlayHost); an older host has none - then nothing to tell. */
const host = () => (powos as unknown as { pull?: { closed?: () => Promise<void>; launched?: () => Promise<void> } }).pull;

const kindOf = (k: unknown) => (k === "ai" ? "ai" : "apps");
pullKind.value = kindOf(new URLSearchParams(location.search).get("kind"));

/** How the opening one asked for it (home's pill: the search; the side button: the chat), done once it's open. */
let asked: LauncherOpen = {};

powos.on("pull.begin", (e: { kind?: string } & LauncherOpen) => {
  pullKind.value = kindOf(e?.kind);
  asked = e ?? {};
  if (asked.draft) aiDraft.value = aiDraft.value ? `${aiDraft.value}\n${asked.draft}` : asked.draft;
  drawerDrag.value = 0;
});
powos.on("pull.drag", (e: { p: number }) => (drawerDrag.value = Math.max(0, Math.min(1, e?.p ?? 0))));
powos.on("pull.end", (e: { open: boolean }) => {
  drawerDrag.value = null;
  if (!e?.open) return closeDrawer();
  drawer.value = 1;
  const how = asked;
  asked = {};
  if (how.chat) openAssistant(how);
  else if (how.search) focusSearch();
});

/** The pill's field focused and the keyboard up (ShellBridge.overlayKeyboard makes this window the IME's target). */
function focusSearch() {
  requestAnimationFrame(() => {
    document.querySelector<HTMLTextAreaElement>(".pull-screen > .bar textarea")?.focus();
    void powos.keyboard.show();
  });
}
powos.on("pull.hide", () => {
  drawerDrag.value = null;
  closeDrawer();
});

/** The keyboard up (the host's insets: app.tsx applies the same ones as --inset-keyboard). */
const keyboardUp = signal(false);
powos.on("system.insets", (i: { keyboard?: number } | null) => (keyboardUp.value = (i?.keyboard ?? 0) > 0));

/** Home's dock under the pill, as on home: on the app grid only - not in the chat, not with the keyboard up (the user:
    the dock stays with the launcher so it's there when the launcher is used over other apps). */
const dockShown = computed(() => pullKind.value === "apps" && !chatting.value && !keyboardUp.value);

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
    <div class={`home pull-screen dock-${dockPosition.value} ${wideHome.value ? "unfolded" : ""} ${open ? "open" : ""} ${pullDragging.value ? "dragging" : ""}`} {...homeGestures()}>
      <div class="stage">
        <div class="launcher-frame tile" data-p ref={followOpenness} />
        <div class="launcher-clip" data-p ref={followOpenness}>
          <div class="launcher" data-p ref={followOpenness}>
            <div class="launcher-inner">
              <div class="drawer-clip">
                {pullKind.value === "ai" ? (
                  <AiView shown={open} cls="ai-panel" pill={false} />
                ) : (
                  <Drawer />
                )}
              </div>
            </div>
          </div>
        </div>
      </div>
      <Bar />
      {dockShown.value && <Dock />}
      {/* A held app's menu ("add to home" puts it on home's page). */}
      <AppMenu />
    </div>
  );
}
