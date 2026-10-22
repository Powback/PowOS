/**
 * Which apps run, for the short accent bar under their icons (apps.tsx AppCell's data-run, shell.css .app[data-run]):
 * the host's map, app key -> "running" | "frozen", asked once and then kept by its "apps.running" event - nothing
 * polls, and nothing draws while it doesn't change. Android: an app with a task in recents (the task stack listener);
 * Linux apps, Steam and its games: a window, and powos-sleep-gui's freeze/thaw (system/RunningApps.kt).
 */
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import type { RunState } from "../types.ts";

export const running = signal<Record<string, RunState>>({});

const take = (m: Record<string, RunState> | null) => (running.value = m ?? {});
const ask = () => powos.apps.running?.().then(take, () => undefined);

if (powos.apps.running) {
  powos.on("apps.running", take);
  // The host maps windows and tasks to the apps it lists: a new list (an install, a Linux app) maps them again.
  powos.on("apps.changed", ask);
  void ask();
}
