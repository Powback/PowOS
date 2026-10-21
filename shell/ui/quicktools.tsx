/**
 * Quick Tools (index.html?mode=quicktools): a small control center by the thumb, over any app - Good Lock's One Hand
 * Operation+ idea. An edge swipe brings it (EdgeGestures.kt); the host's window (QuickToolsHost.kt) is the whole
 * screen, the card sits by the finger on that edge.
 *
 * The same tiles and sliders as the control center (control.tsx, QuickSettings through the bridge): Wi-Fi,
 * Bluetooth, the torch, Do not disturb, rotation, screenshot, then brightness and volume. Tap a tile to switch it, hold
 * it for its page.
 *
 * Finger-tied: "qt.drag" { side, y, q } brings the card in from its edge as the finger goes; "qt.settle" { open }
 * springs it open or away. A tap outside the card (or Back, Home) puts it away; once it's gone, the host hides the
 * window (powos.overlay.closed). The compositor blurs what's under the card (nativeglass.ts), the card only tints.
 */
import { signal } from "@preact/signals";
import { useEffect, useLayoutEffect, useRef } from "preact/hooks";
import { powos } from "../bridge.ts";
import type { QuickTile } from "../types.ts";
import { onShut, quick, Slider, Tile } from "./control.tsx";

/** The tiles, in this order, where the phone has them. */
const TOOLS = ["wifi", "bt", "flashlight", "dnd", "rotation", "screenshot"];

/** Which edge it's by, the finger's height (CSS px), how far in (0..1), and whether it's settling (springing). */
const side = signal<"left" | "right">("right");
const fingerY = signal(innerHeight * 0.7);
const q = signal(0);
const settling = signal(false);
/** Open (settled) or on the way: the page is listening to the tiles. */
const live = signal(false);

/** The spring's length (ms), as the CSS transition's. */
const SETTLE_MS = 240;
let doneTimer = 0;

powos.on("qt.drag", (e: { side: "left" | "right"; y: number; q: number }) => {
  clearTimeout(doneTimer);
  side.value = e.side === "left" ? "left" : "right";
  fingerY.value = e.y;
  settling.value = false;
  q.value = Math.max(0, Math.min(1, e.q));
  live.value = true;
});
powos.on("qt.settle", ({ open }: { open: boolean }) => settle(open));

function settle(open: boolean) {
  clearTimeout(doneTimer);
  settling.value = true;
  q.value = open ? 1 : 0;
  if (open) {
    live.value = true;
    return;
  }
  // Away: once the card is gone, the window too.
  doneTimer = window.setTimeout(() => {
    live.value = false;
    powos.overlay.closed();
  }, SETTLE_MS);
}

// A tile that leaves (screenshot, a page held open): the card goes first.
onShut(() => settle(false));
powos.on("qs.collapse", () => settle(false));

export function QuickTools() {
  const card = useRef<HTMLDivElement>(null);
  const on = live.value;
  useEffect(() => {
    if (!on) return;
    powos.qs.listening(true);
    return () => powos.qs.listening(false);
  }, [on]);

  // The card by the finger, inside the screen.
  useLayoutEffect(() => {
    const el = card.current;
    if (!el) return;
    const h = el.offsetHeight;
    const margin = 48;
    const top = Math.max(margin, Math.min(innerHeight - h - margin, fingerY.value - h * 0.6));
    el.style.top = `${top}px`;
  });

  const tiles = quick.value.tiles ?? [];
  const tools = TOOLS.map((id) => tiles.find((t) => t.id === id)).filter((t): t is QuickTile => !!t);
  const b = quick.value.brightness ?? { value: 0.5, auto: false };
  const v = quick.value.volume ?? { value: 0.5, ringer: 2 };
  const right = side.value === "right";
  return (
    <div
      class={`qt-root ${right ? "right" : "left"} ${settling.value ? "settling" : ""}`}
      style={{ "--q": String(q.value) }}
      onPointerDown={(e) => {
        // A tap outside the card puts it away.
        if (!card.current?.contains(e.target as Node)) settle(false);
      }}
    >
      <div class="qt-card tile" ref={card}>
        <div class="cc-grid qt-grid">
          {tools.map((t) => (
            <Tile key={t.id} t={t} />
          ))}
        </div>
        <div class="qt-sliders">
          <Slider name="brightness" value={b.value} label="brightness" icon="brightness6" />
          <Slider name="volume" value={v.value} label="volume" icon={v.value > 0 ? "volumeHigh" : "volumeOff"} />
        </div>
      </div>
    </div>
  );
}
