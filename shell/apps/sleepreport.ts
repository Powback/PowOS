/**
 * Unified sleep's view of the shell (docs/UNIFIED-SLEEP.md): which PowOS app islands are on screen (working) and which
 * are paused off screen (onscreen.ts: their work stops). Written to the shell's store as sleep.json, debounced, only
 * when something changed; `powos sleep status` reads it there (powos-sleepd, as root).
 */
import { useEffect } from "preact/hooks";
import { powos } from "../bridge.ts";

const islands = new Map<string, { name: string; on: boolean; since: number }>();
let timer = 0;

function flush() {
  timer = 0;
  powos.store
    .set("sleep", { time: Date.now(), islands: [...islands].map(([key, i]) => ({ key, ...i })) })
    .catch(() => {});
}

function changed() {
  if (!timer) timer = window.setTimeout(flush, 2000);
}

/** An island's on-screen state, as the shell pauses it; gone when it unmounts. */
export function useSleepReport(key: string, name: string, on: boolean) {
  useEffect(() => {
    const was = islands.get(key);
    if (!was || was.on !== on || was.name !== name) {
      islands.set(key, { name, on, since: Date.now() });
      changed();
    }
  }, [key, name, on]);
  useEffect(
    () => () => {
      islands.delete(key);
      changed();
    },
    [key],
  );
}
