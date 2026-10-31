/**
 * Which apps run, for the short accent bar under their icons (apps.tsx AppCell's data-run, shell.css .app[data-run]):
 * the host's map, app key -> "running" | "frozen", asked once and then kept by its "apps.running" event - nothing
 * polls, and nothing draws while it doesn't change. Android: an app with a task in recents (the task stack listener);
 * Linux apps, Steam and its games: a window, and powos-sleep-gui's freeze/thaw (system/RunningApps.kt).
 */
import { computed, signal, type ReadonlySignal } from "@preact/signals";
import { powos } from "../bridge.ts";
import type { RunState } from "../types.ts";

export const running = signal<Record<string, RunState>>({});

/**
 * The host's map, kept while equal: it sends "apps.running" again on every task-stack change (a home page swipe, a
 * PowOS app page), and a new object re-rendered every cell reading it (AppCell 161x by a signal, perf-1793458475110).
 */
const take = (m: Record<string, RunState> | null) => {
  const next = m ?? {};
  const was = running.value;
  const keys = Object.keys(next);
  if (keys.length === Object.keys(was).length && keys.every((k) => was[k] === next[k])) return;
  running.value = next;
};

const runs = new Map<string, ReadonlySignal<RunState | undefined>>();
/** App [key]'s run state as its own signal: a cell reading it re-renders only when its app's state flips. */
export function runOf(key: string): ReadonlySignal<RunState | undefined> {
  let s = runs.get(key);
  if (!s) runs.set(key, (s = computed(() => running.value[key])));
  return s;
}
const ask = () => powos.apps.running?.().then(take, () => undefined);

if (powos.apps.running) {
  powos.on("apps.running", take);
  // The host maps windows and tasks to the apps it lists: a new list (an install, a Linux app) maps them again.
  powos.on("apps.changed", ask);
  void ask();
}
