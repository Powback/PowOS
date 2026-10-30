/**
 * The page's native port itself (ShellNative.kt), with no imports of the shell's state: a leaf, so modules that
 * state.ts imports (ui/webwindows.tsx) can use it without an import cycle. apps/native.ts re-exports all of it.
 */
import { signal } from "@preact/signals";

declare global {
  interface Window {
    PowosNative?: { connect?(): void; postMessage?(message: string): void };
    PowosGeometry?: { frame(key: string, line: string): void };
  }
}

/** The port, once the app has handed it over (null: an APK without ShellNative, or not yet). */
export const native = signal<MessagePort | null>(null);

/** What the app says back over the port ("n.res ...": apps/net.ts), to each listener. */
export const fromNative = new Set<(text: string) => void>();

addEventListener("message", (e: MessageEvent) => {
  if (e.data !== "powos-native" || !e.ports?.[0]) return;
  native.value?.close();
  const p = e.ports[0];
  // A page that reloaded leaves the last one's tiles behind: they go first.
  p.postMessage("s.reset");
  p.onmessage = (m: MessageEvent) => {
    if (typeof m.data === "string") for (const f of fromNative) f(m.data);
  };
  native.value = p;
});
try {
  const n = window.PowosNative;
  if (n?.postMessage) n.postMessage("connect");
  else n?.connect?.();
} catch {}

export const send = (command: string) => native.value?.postMessage(command);

/**
 * The geometry interface's key (ShellNative.Geometry): the host hands it over the port ("w.key <hex>") so only this
 * frame can use window.PowosGeometry, which Android puts into every frame of the page.
 */
let geometryKey: string | null = null;
fromNative.add((text) => {
  if (text.startsWith("w.key ")) geometryKey = text.slice(6);
});

/** Test knob (CDP: `__ww.direct = false`): "w.f" over the port, as before the direct interface. */
export const geometryChannel = { direct: true };

/**
 * A "w.f" line to the host, off its main thread when it can be: the direct interface runs on the WebView's binder
 * thread, synchronously in this rAF, so the host has the geometry before this frame's commit (ShellNative.Geometry).
 * The port otherwise (an older APK, no key yet).
 */
export function sendGeometry(line: string) {
  const g = window.PowosGeometry;
  if (geometryChannel.direct && g && geometryKey) {
    try {
      g.frame(geometryKey, line);
      return;
    } catch {}
  }
  send(line);
}

/**
 * Page frame ids for the host's frame-synced commands ("b.f" glass regions, "w.f" web windows): one counter, so what
 * two of them measured on the same frame carries the same id and lands on the same draw (FrameSync.kt).
 */
let frameIds = 0;
export const nextFrameId = () => ++frameIds;
