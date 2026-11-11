/**
 * The shade's privacy row, right under the control center (the user, 11-03: "I should be able to see where my
 * microphone is used in the notification center, like under the control center"): one chip per app using the
 * microphone, the camera, the screen or location now - its icon, its name, what it uses and "now" - and, greyed, the
 * ones that stopped in the last RecordingOps.GRACE_MS ("12s ago"). A tap opens that app's permissions; PowOS's own mic
 * (its dictation) is stopped instead. The same AppOps watch as the recording light (RecordingLight.kt), pushed as
 * "privacy.changed". Nothing in use: no row.
 */
import { useEffect, useRef, useState } from "preact/hooks";
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import { notif } from "../state.ts";
import { followNotif } from "./gesture.ts";
import { Icon, type IconName } from "./icons.tsx";
import { Reveal } from "./reveal.tsx";
import type { PrivacyKind, PrivacyList, PrivacyUse } from "../types.ts";

/** RecordingOps.GRACE_MS: how long a stopped use stays in the row. The page drops it on its own clock too. */
export const PRIVACY_GRACE_MS = 15_000;

const uses = signal<PrivacyUse[]>([]);
powos.on("privacy.changed", (l: PrivacyList) => (uses.value = l?.items ?? []));
powos.privacy
  ?.list()
  .then((l) => (uses.value = l?.items ?? []))
  .catch(() => {}); // a host without the watch (the desktop's): no row

const WORDS: Record<PrivacyKind, string> = { mic: "Microphone", camera: "Camera", screen: "Screen", location: "Location" };
const GLYPHS: Record<PrivacyKind, IconName> = { mic: "microphoneOutline", camera: "cameraOutline", screen: "cellphoneScreenshot", location: "mapMarker" };

/** What [u] uses and since when, as its chip says it: "Microphone · now", "Camera, Microphone · 12s ago". */
export function privacyLine(u: PrivacyUse, now: number) {
  const what = u.kinds.map((k) => WORDS[k]).join(", ");
  const when = u.active || u.ended == null ? "now" : `${Math.max(1, Math.round((now - u.ended) / 1000))}s ago`;
  return `${what} · ${when}`;
}

/** The chips to show at [now]: in use, then stopped within the grace. */
export function privacyShown(list: PrivacyUse[], now: number) {
  return list.filter((u) => u.active || (u.ended != null && now - u.ended < PRIVACY_GRACE_MS));
}

function tap(u: PrivacyUse) {
  // PowOS's own dictation: stop it (speech.stop ends whichever window's dictation holds the mic). Anything else of
  // PowOS's, and every other app: its permissions, the shade out of the way.
  if (u.own && u.active && u.kinds.includes("mic")) return void powos.speech.stop();
  void powos.privacy.open(u.pkg);
  notif.value = false;
}

/** What a tap on [u]'s chip does, as its label says it. */
function tapWord(u: PrivacyUse, stop: boolean) {
  if (stop) return "Tap to stop";
  return u.anonymous ? "Open privacy settings" : "Open its permissions";
}

function Chip({ u, now }: { u: PrivacyUse; now: number }) {
  const stop = u.own && u.active && u.kinds.includes("mic");
  const line = privacyLine(u, now);
  return (
    <button
      type="button"
      class="privacy-chip tile"
      data-active={u.active ? "" : undefined}
      data-pkg={u.pkg}
      data-anonymous={u.anonymous ? "" : undefined}
      aria-label={`${u.app}: ${line}. ${tapWord(u, stop)}`}
      onClick={() => tap(u)}
    >
      {u.icon ? (
        <img class="privacy-icon" src={u.icon} alt="" />
      ) : u.own ? (
        <img class="privacy-icon" src="./icons/powos.svg" alt="" />
      ) : (
        <span class="privacy-icon privacy-icon-none"><Icon name="android" /></span>
      )}
      <span class="privacy-text">
        <span class="privacy-app">{u.app}</span>
        <span class="privacy-what">{stop && u.active ? `${line} · stop` : line}</span>
      </span>
      <span class="privacy-kinds" aria-hidden="true">
        {u.kinds.map((k) => (
          <span key={k} class="privacy-kind" data-kind={k}><Icon name={GLYPHS[k]} /></span>
        ))}
      </span>
    </button>
  );
}

/** The row; [i] its place in the shade's open cascade (shell.css .cascade). */
export function PrivacyRow({ i }: { i: number }) {
  const [now, setNow] = useState(() => Date.now());
  const shown = privacyShown(uses.value, now);
  const anyStopped = shown.some((u) => !u.active);
  // "Xs ago" counts up, and a stopped chip leaves once its grace is up - a second's tick while one is greyed only.
  useEffect(() => {
    setNow(Date.now());
    if (!anyStopped) return;
    const t = window.setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, [anyStopped, uses.value]);
  // Leaving: the last chips stay drawn while the row folds away (Reveal), not an empty box shrinking.
  const last = useRef<PrivacyUse[]>([]);
  if (shown.length) last.current = shown;
  return (
    <Reveal open={shown.length > 0} class="privacy-reveal">
      <div class="privacy-row cascade" data-q ref={followNotif} style={{ "--i": i }} role="group" aria-label="In use now">
        {(shown.length ? shown : last.current).map((u) => (
          <Chip key={`${u.pkg}:${u.uid}`} u={u} now={now} />
        ))}
      </div>
    </Reveal>
  );
}
