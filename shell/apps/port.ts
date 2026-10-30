/**
 * The page's native port itself (ShellNative.kt), with no imports of the shell's state: a leaf, so modules that
 * state.ts imports (ui/webwindows.tsx) can use it without an import cycle. apps/native.ts re-exports all of it.
 */
import { signal } from "@preact/signals";

declare global {
  interface Window {
    PowosNative?: { connect?(): void; postMessage?(message: string): void };
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
 * Page frame ids for the host's frame-synced commands ("b.f" glass regions, "w.f" web windows): one counter, so what
 * two of them measured on the same frame carries the same id and lands on the same draw (FrameSync.kt).
 */
let frameIds = 0;
export const nextFrameId = () => ++frameIds;
