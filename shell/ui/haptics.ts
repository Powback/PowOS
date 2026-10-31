/**
 * The shell's one haptic feel: a light tick as a gesture crosses its commit threshold, confirm as something commits.
 * Android's host plays them with View.performHapticFeedback (ShellBridge "haptics.*" -> ui/Haptics.kt, the same the
 * native gestures use, so the feel matches) - the system's "touch feedback" setting decides, never forced here. The
 * dev/mock host buzzes navigator.vibrate(8) and counts (window.__hapticsMock); an older or desktop host has none.
 *
 * The rule (the user, 10-31: "some small haptics thing there" as the launcher's threshold is reached): once as the
 * finger crosses, nothing more while held past it, again only when it goes back and crosses again.
 */
import { effect, type ReadonlySignal } from "@preact/signals";
import { powos } from "../bridge.ts";

export const tick = () => void powos.haptics?.tick().catch(() => {});
export const confirm = () => void powos.haptics?.confirm().catch(() => {});

/** A threshold's crossings: [at] each frame with whether it's past; ticks on the frame it goes from short to past. */
export function crossing() {
  let past = false;
  return {
    at(now: boolean) {
      if (now && !past) tick();
      past = now;
    },
    reset() {
      past = false;
    },
  };
}

/**
 * A panel's openness under a finger ([drag]: 0..1, null when no finger): ticks as it crosses what letting go would
 * commit - opening (from shut), past [openAt]; shutting (from open, [wasOpen] at the drag's start), down to [keepAt].
 */
export function panelTicks(drag: ReadonlySignal<number | null>, wasOpen: () => boolean, openAt: number, keepAt: number) {
  const gate = crossing();
  let fromOpen: boolean | null = null;
  return effect(() => {
    const p = drag.value;
    if (p == null) {
      fromOpen = null;
      return gate.reset();
    }
    fromOpen ??= wasOpen();
    gate.at(fromOpen ? p <= keepAt : p > openAt);
  });
}
