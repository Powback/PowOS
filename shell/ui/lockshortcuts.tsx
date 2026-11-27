/**
 * The lock face's corner shortcuts (the user, 11-25: "lock screen camera button or whatever?"), as stock's lock screen
 * (OxygenOS, One UI, Pixel) has them: the torch in one bottom corner, the camera in the other. Each acts on a press
 * and HOLD (HOLD_MS, a haptic as it fires) - never a tap, so a pocket or a stray touch doesn't light the torch; a tap
 * only says so (the face's hint). The torch switches without unlocking and shows its new state at once (optimistic,
 * the real state from "lock.torch" after); the camera opens over the lock in its secure mode (LockShortcuts.kt): only
 * what it takes now, its gallery asks for the unlock. An APK without them (lock.shortcuts rejects): no buttons.
 *
 * Which shortcut sits in which corner is the user's (lockstyle.ts corners, chosen in the face's edit, lockedit.tsx): the
 * torch, the camera, the focus mode (ui/focus.ts: on/off at once, shown filled while on), the recorder or any app - an
 * app opens after the unlock (lock.open: the PIN pad / fingerprint first), never over the lock.
 */
import { useEffect, useRef } from "preact/hooks";
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import { confirm } from "./haptics.ts";
import { Icon, type IconName } from "./icons.tsx";
import type { App, LockShortcutState } from "../types.ts";
import { focusOn, toggleFocus } from "./focus.ts";
import { lockFace, type LockCorner } from "./lockstyle.ts";

export type LockShortcutId = Exclude<LockCorner, null>;

/** The recorder: the first of these apps installed (the control center's quick launcher's list, launchers.tsx). */
export const RECORDER = [/^a:com\.oneplus\.soundrecorder/, /^a:com\.google\.android\.apps\.recorder/, /^a:com\.android\.soundrecorder/, /^l:org\.kde\.krecorder/];

/** The installed apps (asked as the face shows, for the recorder and an app corner); empty until known. */
export const lockApps = signal<App[]>([]);

/** The app a corner opens: its own key, or the recorder's; undefined when it isn't installed. */
export function cornerApp(id: LockShortcutId, list: App[]): App | undefined {
  if (id.startsWith("app:")) return list.find((a) => a.key === id.slice(4));
  if (id !== "recorder") return undefined;
  const re = RECORDER.find((r) => list.some((a) => r.test(a.key)));
  return re && list.find((a) => re.test(a.key));
}

/** Unlock, then [app] (an older APK without lock.open: the unlock, then the launch). */
function openAfterUnlock(app: App | undefined) {
  if (!app) return;
  powos.lock.open(app.key).catch(() => void powos.lock.unlock().then(() => powos.apps.launch(app.key)).catch(() => {}));
}

/** ms a shortcut is held before it acts (stock's are about this long). */
export const HOLD_MS = 400;

/** What this phone has (null: not asked yet, or an APK without them), and the torch's state. */
export const shortcuts = signal<LockShortcutState | null>(null);

/** Asked again each time the face shows (lock.tsx refresh): the torch may have changed meanwhile, an app installed. */
export function askShortcuts() {
  powos.lock.shortcuts().then(
    (s) => (shortcuts.value = s),
    () => (shortcuts.value = null),
  );
  powos.apps.list().then((a) => (lockApps.value = a), () => {});
}
powos.on("lock.torch", ({ on }: { on: boolean }) => shortcuts.value && (shortcuts.value = { ...shortcuts.value, torch: on }));

interface Def {
  icon: (s: LockShortcutState) => IconName;
  /** An app's own picture in place of the glyph. */
  img?: () => string | undefined;
  label: string;
  /** Offered on this phone. */
  has: (s: LockShortcutState) => boolean;
  on?: (s: LockShortcutState) => boolean;
  run: (s: LockShortcutState) => void;
}

const DEFS: Record<"torch" | "camera" | "focus", Def> = {
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
  // On / off at once (focus.ts: its signal, then Do not disturb); filled while a mode is on.
  focus: { icon: () => "minusCircleOutline", label: "focus", has: () => true, on: () => !!focusOn.value, run: () => toggleFocus() },
};

/** [id]'s definition: a built-in one, or an app (the recorder, any app) that opens after the unlock. */
export function defOf(id: LockShortcutId): Def {
  if (id === "torch" || id === "camera" || id === "focus") return DEFS[id];
  const app = () => cornerApp(id, lockApps.value);
  return {
    icon: () => (id === "recorder" ? "microphoneOutline" : "apps"),
    img: id === "recorder" ? undefined : () => app()?.icon,
    label: id === "recorder" ? "recorder" : (app()?.label ?? "app").toLowerCase(),
    has: () => !!app(),
    run: () => openAfterUnlock(app()),
  };
}

/**
 * One corner's button: held HOLD_MS it acts (a haptic, the button grown under the finger meanwhile: shell.css
 * .lock-shortcut.holding); let go sooner, [hint] says to hold it. The finger is the button's from the press (the face's
 * swipe never starts on it).
 */
function Shortcut({ id, side, s, hint }: { id: LockShortcutId; side: "left" | "right"; s: LockShortcutState; hint: (t: string) => void }) {
  const d = defOf(id);
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
      {d.img?.() ? <img class="lock-shortcut-app" src={d.img()} alt="" /> : <Icon name={d.icon(s)} />}
    </button>
  );
}

/** The two corners (lockstyle.ts corners), each only where this phone has it. */
export function LockShortcuts({ hint }: { hint: (t: string) => void }) {
  const s = shortcuts.value;
  if (!s) return null;
  return (
    <>
      {lockFace.value.corners.map((id, i) => (id && defOf(id).has(s) ? <Shortcut key={`${i}:${id}`} id={id} side={i ? "right" : "left"} s={s} hint={hint} /> : null))}
    </>
  );
}
