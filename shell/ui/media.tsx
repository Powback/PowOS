/**
 * The media card (one active MediaSession: Media.kt / MediaShape.kt through ShellMedia.kt), shared by the control
 * center (control.tsx MediaCards) and the lock face (lock.tsx LockMedia). One component, two places: the shade's card
 * as it was, and on the lock face (`locked`, the user 11-25: "we are missing basic features such as a media control
 * on the lockscreen if media is playing") the same card a step taller, as stock's lock screen player:
 * - the transport and seek act at once, no unlock (stock's do the same); opening the app (the card's body) and the
 *   output picker ask for the unlock first (the host: ShellBridge mediaControl / media.output on the lock face);
 * - the session's own actions (like, shuffle...: PlaybackState.CustomAction, at most two) beside the transport;
 * - where it plays (the phone, a Bluetooth device by its name, headphones, a cast) as a chip by the app's icon.
 * Play/pause flips the moment it's pressed (optimistic: usePlaying), back if the session hasn't followed in 2 s.
 */
import { useEffect, useRef, useState } from "preact/hooks";
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import { Icon, type IconName } from "./icons.tsx";
import { apps } from "./launchers.tsx";
import { paintDots } from "./pagedots.tsx";
import type { MediaState } from "../types.ts";

/** What's playing: asked for once a card's place is shown, then kept up to date ("media.changed"). */
export const media = signal<MediaState | null>(null);
let mediaAsked = false;
export function askMedia() {
  if (mediaAsked) return;
  mediaAsked = true;
  powos.on("media.changed", (m: MediaState) => (media.value = m));
  refreshMedia();
}
/** The state read again (the lock face shown: the host doesn't send the ticks while the screen is off). */
export const refreshMedia = () => void powos.media.state().then((m) => (media.value = m), () => {});

/** The sessions to show a card for: each one with a track, at most [max] (an older host sends only the one: [m] itself). */
export function sessionsOf(m: MediaState | null, max = 2): MediaState[] {
  if (!m?.available) return [];
  return (m.sessions ?? [m]).filter((x) => x.title).slice(0, max);
}

/** A session's app icon: its app in the list the quick launchers read (an Android key is "a:<package>/<activity>"). */
function appIcon(pkg?: string): string | null {
  if (!pkg) return null;
  return apps.value.find((a) => a.key === `a:${pkg}` || a.key.startsWith(`a:${pkg}/`))?.icon ?? null;
}

/** The apps list, read once where no quick launcher row has read it (the lock face): the cards' app icons. */
let appsAsked = false;
export function askAppIcons() {
  if (appsAsked || apps.value.length) return;
  appsAsked = true;
  powos.apps.list().then((a) => (apps.value.length ? null : (apps.value = a)), () => {});
}

const clock = (sec: number) => `${Math.floor(sec / 60)}:${String(Math.floor(sec % 60)).padStart(2, "0")}`;

/** ms a pressed play/pause waits for the session to follow before it shows the truth again (rollback). */
const FLIP_MS = 2000;

/**
 * Whether [m] plays as shown: the press's own answer at once (optimistic), the session's once it agrees or FLIP_MS
 * passed without it (then the button shows what really happened: the app refused, or never answered).
 */
function usePlaying(m: MediaState): [boolean, () => void] {
  const [want, setWant] = useState<boolean | null>(null);
  useEffect(() => {
    if (want === null) return;
    if (want === m.playing) return setWant(null);
    const t = window.setTimeout(() => setWant(null), FLIP_MS);
    return () => clearTimeout(t);
  }, [want, m.playing]);
  const playing = want ?? m.playing;
  return [playing, () => (setWant(!playing), void powos.media.control(playing ? "pause" : "play", m.package).catch(() => setWant(null)))];
}

/** A custom action's button: the app's own icon (/_media/<id>, a mask in the card's colour), else its name's first letter. */
function Custom({ a, pkg }: { a: NonNullable<MediaState["actions"]>[number]; pkg?: string }) {
  const src = a.icon ? `/_media/${encodeURIComponent(a.icon)}` : null;
  return (
    <button type="button" class="cc-custom" aria-label={a.name} onClick={() => powos.media.control(`custom:${a.id}`, pkg)}>
      {src ? <span class="cc-custom-icon" style={{ "--icon": `url("${src}")` }} /> : <span class="cc-custom-letter">{a.name.slice(0, 1)}</span>}
    </button>
  );
}

/**
 * Previous, play/pause (the filled disc), next - on this session - centred on the card, each a 44 px target; the elapsed
 * time [at] and what's left at the row's two ends, only while the card is wide enough for them (shell.css container query).
 * Locked: the session's own actions take the row's ends instead (the times go under the line), as stock's player.
 */
function Transport({ m, at, playing, toggle, locked }: { m: MediaState; at: number; playing: boolean; toggle: () => void; locked?: boolean }) {
  const pkg = m.package;
  const duration = m.duration ?? 0;
  const [c0, c1] = locked ? (m.actions ?? []) : [];
  const end = (c: typeof c0, time: string) => (locked ? (c ? <Custom a={c} pkg={pkg} /> : <span />) : <span class="cc-time">{time}</span>);
  return (
    <span class="cc-transport">
      {end(c0, duration ? clock(at) : "")}
      <button type="button" aria-label="previous" disabled={m.canPrevious === false} onClick={() => powos.media.control("previous", pkg)}>
        <Icon name="skipPrevious" />
      </button>
      <button type="button" class="cc-play" aria-label={playing ? "pause" : "play"} onClick={toggle}>
        <Icon name={playing ? "pause" : "play"} />
      </button>
      <button type="button" aria-label="next" disabled={m.canNext === false} onClick={() => powos.media.control("next", pkg)}>
        <Icon name="skipNext" />
      </button>
      {end(c1, duration ? `−${clock(Math.max(0, duration - at))}` : "")}
    </span>
  );
}

/**
 * The transport row and the progress line under it: the line is a range input drawn 3 px thin, no knob till it's
 * dragged (a drag seeks; the elapsed time follows the finger). While it plays the line glides between the host's
 * one-second ticks (shell.css .cc-seek.live, --p registered: only the line repaints); keyed by the track, so a new one
 * starts from its own place instead of sweeping back. A session that doesn't take seeking: the line only shows where
 * it is. Locked: the times under the line's two ends.
 */
function Playback({ m, locked }: { m: MediaState; locked?: boolean }) {
  const [drag, setDrag] = useState<number | null>(null);
  const [playing, toggle] = usePlaying(m);
  const duration = m.duration ?? 0;
  const at = drag ?? Math.min(duration, m.position ?? 0);
  // Gliding only while it really plays (not on a press the session hasn't followed yet); a drag shows its knob.
  const line = drag !== null ? "dragging" : playing && m.playing ? "live" : "";
  return (
    <>
      <Transport m={m} at={at} playing={playing} toggle={toggle} locked={locked} />
      <Seek m={m} at={at} line={line} setDrag={setDrag} />
      {locked && <Times at={at} duration={duration} />}
    </>
  );
}

/** The progress line (Playback's): a range input; let go, it seeks and stays there till the host's next tick. */
function Seek({ m, at, line, setDrag }: { m: MediaState; at: number; line: string; setDrag: (v: number | null) => void }) {
  const duration = m.duration ?? 0;
  const value = (e: Event) => Number((e.target as HTMLInputElement).value);
  return (
    <input
      type="range"
      key={m.title ?? ""}
      class={`cc-seek ${line}`}
      aria-label="seek"
      min={0}
      max={duration || 1}
      step={1}
      value={at}
      style={{ "--p": String(duration ? at / duration : 0) }}
      disabled={!duration || m.seekable === false}
      onInput={(e) => setDrag(value(e))}
      onChange={(e) => {
        powos.media.seek(m.package, value(e)).catch(() => {});
        window.setTimeout(() => setDrag(null), 1200);
      }}
    />
  );
}

/** The lock face's times, under the line's two ends: where it is, how long it is. */
function Times({ at, duration }: { at: number; duration: number }) {
  if (!duration) return null;
  return (
    <span class="cc-times">
      <span class="cc-time">{clock(at)}</span>
      <span class="cc-time">{clock(duration)}</span>
    </span>
  );
}

const OUTPUT_ICON: Record<NonNullable<MediaState["output"]>["kind"], IconName> = {
  phone: "cellphone",
  bluetooth: "bluetooth",
  wired: "volumeHigh",
  cast: "cast",
};
const OUTPUT_NAME: Record<NonNullable<MediaState["output"]>["kind"], string> = { phone: "This phone", bluetooth: "Bluetooth", wired: "Headphones", cast: "Casting" };

/** Where it plays (locked): its kind's icon and the device's name, a tap opens the output picker after the unlock. */
function Output({ m }: { m: MediaState }) {
  const o = m.output;
  if (!o) return null;
  return (
    <button type="button" class="cc-output" aria-label={`output: ${o.name ?? OUTPUT_NAME[o.kind]}`} onClick={() => powos.media.output(m.package)}>
      <Icon name={OUTPUT_ICON[o.kind]} />
      <span>{o.name ?? OUTPUT_NAME[o.kind]}</span>
    </button>
  );
}

/**
 * One session's card (the user, 2026-10-30: "surely there's some better way to do the media"; 10-31 board: "blurred
 * artwork background, proper font, centred controls, thin progress"). 110 px in the control center, folded and unfolded:
 * - its ground is the art itself, heavily blurred and dimmed by the shade's own tint (--shade-tint) over the card's
 *   shared glass (shell.css .cc-media.has-art ::before/::after); no art: the glass with a faint accent tint;
 * - the art as a small rounded tile, the track beside it on one line each (title semibold --text-item, artist secondary
 *   --text-body, ellipsised; a tap opens the app), the app's icon at the corner (its output picker: speaker, Bluetooth,
 *   cast);
 * - the transport centred under them (44 px targets), the times at its ends if they fit, the 3 px progress line under it.
 * Every control acts on this session (its package), not whichever plays. [leave]: what the card's place does before
 * the app or the picker opens (the control center shuts). Locked: the lock face's (the header above).
 */
export function MediaCard({ m, locked, leave }: { m: MediaState; locked?: boolean; leave?: () => void }) {
  const art = m.art ? `/_media/${encodeURIComponent(m.art)}` : null;
  return (
    <div
      class={`cc-media tile ${art ? "has-art" : "no-art"} ${m.playing ? "" : "paused"}${locked ? " locked" : ""}`}
      style={art ? { "--art": `url("${art}")` } : undefined}
    >
      {art ? <img class="cc-art" src={art} alt="" /> : <span class="cc-art cc-art-none"><Icon name="musicNote" /></span>}
      <button type="button" class="cc-track" onClick={() => (leave?.(), powos.media.control("open", m.package))}>
        <span class="cc-label">{m.title}</span>
        {m.artist ? <span class="cc-detail">{m.artist}</span> : null}
      </button>
      {locked ? <LockedApp m={m} /> : <AppButton m={m} leave={leave} />}
      <Playback m={m} locked={locked} />
    </div>
  );
}

/** The control center's corner: the app's icon, a tap opens the output picker (speaker, Bluetooth, cast). */
function AppButton({ m, leave }: { m: MediaState; leave?: () => void }) {
  const icon = appIcon(m.package);
  return (
    <button type="button" class="cc-media-app" aria-label={`output: ${m.app ?? "this app"}`} onClick={() => (leave?.(), powos.media.output(m.package))}>
      {icon ? <img src={icon} alt="" /> : <Icon name="speakerWireless" />}
    </button>
  );
}

/** The lock face's: the app's icon as a badge on the art, and where it plays as a chip (Output). */
function LockedApp({ m }: { m: MediaState }) {
  const icon = appIcon(m.package);
  return (
    <>
      <span class="cc-media-app">{icon ? <img src={icon} alt={m.app ?? ""} /> : <Icon name="musicNote" />}</span>
      <Output m={m} />
    </>
  );
}

/** A paused session stays on the lock face this long (stock's: 10 minutes), then its card goes. */
export const PAUSED_KEEP_S = 600;

/**
 * The sessions the lock face shows at [now] (ms): every one with a track, the most recent first (the host's order:
 * playing ones first), a paused one only for PAUSED_KEEP_S after it stopped. [seen]: when each state arrived (ms), so
 * a card paused a while ago goes on time with no new tick from the host (a paused session sends none).
 */
export function lockSessions(m: MediaState | null, seen: number, now: number): MediaState[] {
  return sessionsOf(m, 4).filter((s) => s.playing || s.idle == null || s.idle + (now - seen) / 1000 < PAUSED_KEEP_S);
}

/** The lock face's media: when the current state arrived (lockSessions' [seen]). */
export const mediaSeen = { at: Date.now() };
media.subscribe(() => (mediaSeen.at = Date.now()));

/**
 * Swiping between the lock face's [n] cards (a scroll-snapped track) and its page dots (pagedots.tsx, painted from the
 * scroll as it moves, never through a render): the track's ref and the dots' ref.
 */
export function useCardDots(n: number): [{ current: HTMLDivElement | null }, { current: HTMLDivElement | null }] {
  const track = useRef<HTMLDivElement | null>(null);
  const dots = useRef<HTMLDivElement | null>(null);
  useEffect(() => {
    const el = track.current;
    if (!el) return;
    let rest = 0;
    const at = () => el.scrollLeft / Math.max(1, el.clientWidth);
    const on = () => {
      paintDots(dots.current, at(), true);
      clearTimeout(rest);
      rest = window.setTimeout(() => paintDots(dots.current, Math.round(at()), false), 120);
    };
    paintDots(dots.current, Math.round(at()), false);
    el.addEventListener("scroll", on, { passive: true });
    return () => (clearTimeout(rest), el.removeEventListener("scroll", on));
  }, [n]);
  return [track, dots];
}
