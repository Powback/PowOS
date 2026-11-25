/**
 * The lock face's corner shortcuts (the user, 11-25: "lock screen camera button or whatever?"), as stock's lock screen
 * (OxygenOS, One UI, Pixel) has them: the torch in one bottom corner, the camera in the other. Each acts on a press
 * and HOLD (HOLD_MS, a haptic as it fires) - never a tap, so a pocket or a stray touch doesn't light the torch; a tap
 * only says so (the face's hint). The torch switches without unlocking and shows its new state at once (optimistic,
 * the real state from "lock.torch" after); the camera opens over the lock in its secure mode (LockShortcuts.kt): only
 * what it takes now, its gallery asks for the unlock. An APK without them (lock.shortcuts rejects): no buttons.
 *
 * Which shortcut sits in which corner is LOCK_SHORTCUTS, in one place, so a "choose lock shortcuts" setting can set it.
 */
import { useEffect, useRef } from "preact/hooks";
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import { confirm } from "./haptics.ts";
import { Icon, type IconName } from "./icons.tsx";
import type { LockShortcutState } from "../types.ts";

export type LockShortcutId = "torch" | "camera";

/** The face's bottom corners: [left, right] (null: none there). The one place a future setting changes. */
export const LOCK_SHORTCUTS: readonly [LockShortcutId | null, LockShortcutId | null] = ["torch", "camera"];

/** ms a shortcut is held before it acts (stock's are about this long). */
export const HOLD_MS = 400;

/** What this phone has (null: not asked yet, or an APK without them), and the torch's state. */
export const shortcuts = signal<LockShortcutState | null>(null);

/** Asked again each time the face shows (lock.tsx refresh): the torch may have changed meanwhile. */
export function askShortcuts() {
  powos.lock.shortcuts().then(
    (s) => (shortcuts.value = s),
    () => (shortcuts.value = null),
  );
}
powos.on("lock.torch", ({ on }: { on: boolean }) => shortcuts.value && (shortcuts.value = { ...shortcuts.value, torch: on }));

interface Def {
  icon: (s: LockShortcutState) => IconName;
  label: string;
  /** Offered on this phone. */
  has: (s: LockShortcutState) => boolean;
  on?: (s: LockShortcutState) => boolean;
  run: (s: LockShortcutState) => void;
}

const DEFS: Record<LockShortcutId, Def> = {
  torch: {
    // One glyph, as stock's: on is the button filled (shell.css .lock-shortcut.on), not a different icon.
    icon: () => "flashlight",
    label: "torch",
    has: (s) => s.torch !== null,
    on: (s) => s.torch === true,
    run: (s) => {
      const want = !s.torch;
      // At once (optimistic); the torch's own answer after (Android refuses while the camera holds it).
      shortcuts.value = { ...s, torch: want };
      powos.lock.torch(want).then(
        (now) => shortcuts.value && (shortcuts.value = { ...shortcuts.value, torch: now }),
        () => shortcuts.value && (shortcuts.value = { ...shortcuts.value, torch: !want }),
      );
    },
  },
  camera: { icon: () => "cameraOutline", label: "camera", has: (s) => s.camera, run: () => void powos.lock.camera().catch(() => {}) },
};

/**
 * One corner's button: held HOLD_MS it acts (a haptic, the button grown under the finger meanwhile: shell.css
 * .lock-shortcut.holding); let go sooner, [hint] says to hold it. The finger is the button's from the press (the face's
 * swipe never starts on it).
 */
function Shortcut({ id, side, s, hint }: { id: LockShortcutId; side: "left" | "right"; s: LockShortcutState; hint: (t: string) => void }) {
  const d = DEFS[id];
  const timer = useRef(0);
  const el = useRef<HTMLButtonElement>(null);
  const stop = () => {
    clearTimeout(timer.current);
    timer.current = 0;
    el.current?.classList.remove("holding");
  };
  useEffect(() => stop, []);
  return (
    <button
      type="button"
      ref={el}
      class={`lock-shortcut tile ${side}${d.on?.(s) ? " on" : ""}`}
      aria-label={d.label}
      data-shortcut={id}
      style={{ "--lock-hold": `${HOLD_MS}ms` }}
      onPointerDown={(e) => {
        e.stopPropagation();
        (e.currentTarget as HTMLElement).setPointerCapture?.(e.pointerId);
        el.current?.classList.add("holding");
        timer.current = window.setTimeout(() => {
          timer.current = 0;
          el.current?.classList.remove("holding");
          confirm();
          d.run(shortcuts.value ?? s);
        }, HOLD_MS);
      }}
      onPointerUp={(e) => {
        e.stopPropagation();
        if (timer.current) hint(`touch and hold for the ${d.label}`);
        stop();
      }}
      onPointerCancel={stop}
      onContextMenu={(e) => e.preventDefault()}
    >
      <Icon name={d.icon(s)} />
    </button>
  );
}

/** The two corners (LOCK_SHORTCUTS), each only where this phone has it. */
export function LockShortcuts({ hint }: { hint: (t: string) => void }) {
  const s = shortcuts.value;
  if (!s) return null;
  return (
    <>
      {LOCK_SHORTCUTS.map((id, i) => (id && DEFS[id].has(s) ? <Shortcut key={id} id={id} side={i ? "right" : "left"} s={s} hint={hint} /> : null))}
    </>
  );
}
