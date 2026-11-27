/** The same title bar, resize grip and status bar in every host. Native code supplies data, never glyphs or labels. */
import { useEffect, useRef, useState } from "preact/hooks";
import type { ChromeState, LiveActivity } from "../types.ts";
import { tick } from "./haptics.ts";
import { FpsMeter } from "./fpsmeter.tsx";
import { NotificationIcons, SystemIcons, statusWords, useSystemStatus } from "./statusicons.tsx";

export type ChromeAction = (action: string) => void;

export function Mark({ kind }: { kind: string }) {
  const paths: Record<string, string> = {
    minimise: "M4 12h16", maximise: "M5 5h14v14H5z", restore: "M5 9h10v10H5z M9 5h10v10",
    close: "M5 5l14 14M5 19L19 5", tile: "M4 5h7v14H4z M13 5h7v14h-7z", resize: "M9 17l8-8M15 18l3-3",
    wifi: "M3 8a15 15 0 0 1 18 0M6 12a10 10 0 0 1 12 0M9 16a5 5 0 0 1 6 0M12 20h.01",
    cellular: "M4 20v-3M9 20v-7M14 20V9M19 20V4", ethernet: "M4 5h16v10H4zM12 15v5M8 20h8",
    charging: "M14 2L5 13h7l-2 9 9-13h-7z",
    offline: "M5 5l14 14M5 19L19 5", vpn: "M7 10V7a5 5 0 0 1 10 0v3M5 10h14v11H5z",
    keyboard: "M3 6h18v12H3z M7 10h.01M11 10h.01M15 10h.01M8 14h8",
  };
  return <svg viewBox="0 0 24 24" aria-hidden="true"><path d={paths[kind] ?? paths.offline} /></svg>;
}

export function WindowBar({ state, action }: { state: ChromeState; action: ChromeAction }) {
  return <div class="window-chrome chrome-surface" aria-label={`${state.title ?? "Application"} window`}>
    <div class="chrome-surface window-glass" />
    <div class="window-caption">
      {state.icon && <img src={state.icon} alt="" draggable={false} />}
      <span>{state.title ?? "Application"}</span>
    </div>
    {["minimise", "maximise", "close"].map((name) => {
      // The maximise button opens the app full screen (its old shape, a new meaning); maximised in place, it restores.
      const label = name === "maximise" ? (state.maximised ? "restore" : "full screen") : name;
      return <button key={name} data-action={name} class={state.pressed === name ? "pressed" : ""}
        aria-label={label[0].toUpperCase() + label.slice(1)} title={label}
        onClick={() => action(name)}><Mark kind={label === "full screen" ? "maximise" : label} /></button>;
    })}
  </div>;
}

export function WindowGrip() {
  return <div class="chrome-surface window-grip" role="img" aria-label="Resize window"><Mark kind="resize" /></div>;
}

/** One minute timer, suspended while hidden. Time is formatted in the user's locale; wake/time-zone changes refresh it. */
function useClock() {
  const [, setTime] = useState(() => new Date());
  useEffect(() => {
    let timer = 0;
    const update = () => {
      clearTimeout(timer);
      setTime(new Date());
      if (!document.hidden) timer = window.setTimeout(update, 60_000 - Date.now() % 60_000);
    };
    update();
    document.addEventListener("visibilitychange", update);
    window.addEventListener("focus", update);
    return () => { clearTimeout(timer); document.removeEventListener("visibilitychange", update); window.removeEventListener("focus", update); };
  }, []);
  return new Date();
}

function statusLabel(state: ChromeState, battery: number | null, words: string[]) {
  const parts = ["System controls", ...(words.length ? words : [state.network])];
  if (battery != null) parts.push(`battery ${battery}%`);
  if (state.charging) parts.push("charging");
  return parts.filter(Boolean).join(", ");
}

/**
 * The bar's side padding (CSS px): the screen's cutouts, and a maximised web window's bar under this one
 * (StatusChrome.merge, TB1) - one bar: its icon and title, then the clock; the status icons, then its controls. Each
 * keeps its own space; the host leaves the window's parts untouchable here.
 */
function sides(state: ChromeState) {
  const merged = state.mergeLeft != null || state.mergeRight != null;
  return {
    merged,
    left: Math.max(8, state.left ?? 0, state.mergeLeft ?? 0),
    right: Math.max(8, state.right ?? 0, (state.mergeRight ?? 0) + 8),
  };
}

export function StatusBar({ state, action }: { state: ChromeState; action: ChromeAction }) {
  const now = useClock();
  const time = state.clock ?? now.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  const battery = state.battery == null ? null : Math.round(Math.max(0, Math.min(100, state.battery)));
  // A camera hole in the middle (folded cover screen, StatusChrome.kt holeLeft): the meter ends left of it, not under it.
  const hole = state.holeLeft;
  const { merged, left, right } = sides(state);
  // The live pill round the camera (compact): the clock and the icons end where it starts.
  const island = islandReach(state);
  return <div class={`status-chrome${hole != null ? " has-hole" : ""}${merged ? " merged" : ""}`} style={{ paddingLeft: `${left}px`, paddingRight: `${right}px`, ...(hole != null ? { "--hole-left": `${hole}px` } : {}) }}>
    {/* data-action: the host makes only these touchable on the strip (chrome.regions -> ShadeHost edgeRegion). */}
    <button class="status-clock" data-action="notifications" aria-label={`Notifications${state.notifications ? `, ${state.notifications} new` : ""}, ${time}`} onClick={() => action("notifications")}
      style={hole != null ? { maxWidth: `${Math.max(0, hole - left - 6 - island.left)}px` } : undefined}>
      <time dateTime={now.toISOString()}>{time}</time>
      <Notifs />
    </button>
    <FpsMeter />
    <Controls state={state} battery={battery} action={action} right={right} islandRight={island.right} />
    <RecordingLight state={state} action={action} />
  </div>;
}

const RECORDING_WORDS = { camera: "Camera", mic: "Microphone", screen: "Screen recording" } as const;
function recordingLabel(kind: NonNullable<ChromeState["recording"]>, apps?: string[]) {
  return `${RECORDING_WORDS[kind]} in use${apps?.length ? ` by ${apps.join(", ")}` : ""}`;
}

/**
 * The recording light on the camera's cutout (none on this screen: [Indicators]' dot) - or, with something live, the
 * live pill round it, its outline in the recording colour.
 */
function RecordingLight({ state, action }: { state: ChromeState; action: ChromeAction }) {
  if (state.live?.length && state.camera) return <LiveIsland key={state.live[0].key} live={state.live} camera={state.camera} recording={state.recording ?? null} action={action} />;
  return state.recording && state.camera ? <RecordingRing kind={state.recording} camera={state.camera} apps={state.recordingApps} action={action} /> : null;
}

/** The pill's reach past the hole (CSS px): [ISLAND_OUT] round it, an icon before, the time / progress after. */
const ISLAND_OUT = 4, ISLAND_EDGE = 2, ISLAND_LEAD = 26, ISLAND_TRAIL = 50, ISLAND_WIDE = 220, ISLAND_MARGIN = 6;

/**
 * How far the pill reaches left and right of the hole's padded box: the trail goes right, unless the screen ends there
 * (the inner screen's camera, top right) - then it all goes left. [wide]: long-pressed, the title shows too.
 */
function islandSides(camera: NonNullable<ChromeState["camera"]>, wide: boolean) {
  const want = wide ? Math.max(ISLAND_TRAIL, Math.min(ISLAND_WIDE, innerWidth * 0.5)) : ISLAND_TRAIL;
  const roomRight = Math.max(0, innerWidth - (camera.x + camera.width + ISLAND_OUT) - ISLAND_MARGIN);
  const roomLeft = Math.max(0, camera.x - ISLAND_OUT - ISLAND_MARGIN);
  const right = want <= roomRight ? want : 0;
  return { left: Math.min(roomLeft, ISLAND_LEAD + want - right), right };
}

/** The compact pill's reach beside the hole (none: 0, 0). */
function islandReach(state: ChromeState) {
  return state.live?.length && state.camera ? islandSides(state.camera, false) : { left: 0, right: 0 };
}

function liveLabel(live: LiveActivity[], recording: ChromeState["recording"], now: number) {
  const a = live[0];
  return [a.title ? `${a.app}: ${a.title}` : a.app, a.clock ? clockText(a.clock, now) : "", live.length > 1 ? `${live.length - 1} more` : ""].filter(Boolean).join(", ")
    + (recording ? `. ${RECORDING_WORDS[recording]} in use` : "") + ". Open";
}

/** A press: [onLong] after 450 ms held (a haptic tick); onClick's [wasLong] says (once) the click ending it was that one. */
function useLongPress(onLong: () => void) {
  const press = useRef({ timer: 0, long: false });
  const stop = () => clearTimeout(press.current.timer);
  return {
    wasLong: () => { const long = press.current.long; press.current.long = false; return long; },
    handlers: {
      onPointerDown: () => { press.current.long = false; stop(); press.current.timer = window.setTimeout(() => { press.current.long = true; tick(); onLong(); }, 450); },
      onPointerUp: stop, onPointerCancel: stop, onContextMenu: (e: Event) => e.preventDefault(),
    },
  };
}

/** Now, every second while [on] (a running timer). */
function useSecond(on: boolean) {
  const [now, setNow] = useState(Date.now);
  useEffect(() => {
    if (!on) return;
    const id = setInterval(() => { if (!document.hidden) setNow(Date.now()); }, 1000);
    return () => clearInterval(id);
  }, [on]);
  return now;
}

function clockText(clock: NonNullable<LiveActivity["clock"]>, now: number) {
  const s = Math.max(0, Math.round((clock.down ? clock.base - now : now - clock.base) / 1000));
  const h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60, sec = String(s % 60).padStart(2, "0");
  return h ? `${h}:${String(m).padStart(2, "0")}:${sec}` : `${m}:${sec}`;
}

const LIVE_GLYPHS: Record<LiveActivity["kind"], string> = {
  call: "M6 3l3 4-2 2a11 11 0 0 0 8 8l2-2 4 3-2 3C10 21 3 14 3 5z", timer: "M12 8v5l3 2M9 2h6M12 22a8 8 0 1 0 0-16 8 8 0 0 0 0 16z",
  progress: "M12 4v11M7 10l5 5 5-5M5 20h14", live: "M12 12h.01M8 8a6 6 0 0 0 0 8M16 8a6 6 0 0 1 0 8", media: "M9 18V5l11-2v13M9 18a3 3 0 1 1-6 0 3 3 0 0 1 6 0zM20 16a3 3 0 1 1-6 0 3 3 0 0 1 6 0z",
};

/** Before the hole: what kind it is, how many more there are (and the trail, when there's no room after the hole). */
function LiveLead({ a, more, children }: { a: LiveActivity; more: number; children?: preact.ComponentChildren }) {
  return <span class="live-lead"><svg viewBox="0 0 24 24" aria-hidden="true"><path d={LIVE_GLYPHS[a.kind]} /></svg>{more > 0 && <b class="live-more">+{more}</b>}{children}</span>;
}

/** What the pill says after the hole: the time, the progress, a playing meter. */
function LiveTrail({ a, now }: { a: LiveActivity; now: number }) {
  if (a.clock) return <span class="live-time">{clockText(a.clock, now)}</span>;
  if (a.kind === "progress") {
    const p = a.progress;
    const ring = (spin: boolean) => <svg class={`live-ring${spin ? " live-spin" : ""}`} viewBox="0 0 20 20" aria-hidden="true"><circle cx="10" cy="10" r="8" />
      <circle class="live-ring-done" cx="10" cy="10" r="8" pathLength="100" style={spin ? undefined : { strokeDasharray: `${Math.round((p ?? 0) * 100)} 100` }} /></svg>;
    return p == null ? <span class="live-time" role="img" aria-label="In progress">{ring(true)}</span> : <span class="live-time">{ring(false)}{Math.round(p * 100)}%</span>;
  }
  if (a.kind === "media") return <span class="live-eq" aria-hidden="true"><i /><i /><i /></span>;
  return <span class="live-time">{a.kind === "call" ? "Call" : ""}</span>;
}

/**
 * Live activities round the camera ring (StatusChrome.kt LiveActivities: ongoing notifications - media playing, a
 * call, a timer / stopwatch, progress, Android 16 live updates): a black pill hugging the hole, its app's kind before
 * it and the time / progress after. Tap: opens the app (its notification's tap action; the pill shows it pressed at
 * once - "always show the pending change"). Long-press: wider, with what it is. More than one: a count.
 */
export function LiveIsland({ live, camera, recording, action }: { live: LiveActivity[]; camera: NonNullable<ChromeState["camera"]>; recording: ChromeState["recording"]; action?: ChromeAction }) {
  const a = live[0];
  const [wide, setWide] = useState(false);
  const [opening, setOpening] = useState(false);
  const now = useSecond(!!a.clock);
  const press = useLongPress(() => setWide((w) => !w));
  const { left, right } = islandSides(camera, wide);
  // Its size changed: the strip's touchable region follows (shell/chrome.tsx regions).
  useEffect(() => { requestAnimationFrame(() => dispatchEvent(new Event("chrome-regions"))); }, [left, right, a.key]);
  useEffect(() => () => { requestAnimationFrame(() => dispatchEvent(new Event("chrome-regions"))); }, []);
  useEffect(() => { if (!opening) return; const id = setTimeout(() => setOpening(false), 1200); return () => clearTimeout(id); }, [opening]);
  const trail = <>{wide && <span class="live-title">{[a.title ?? a.app, a.text].filter(Boolean).join(" · ")}</span>}<LiveTrail a={a} now={now} /></>;
  const out = ISLAND_OUT;
  return <button type="button" class={`live-island${wide ? " wide" : ""}${opening ? " opening" : ""}`} data-kind={a.kind} data-rec={recording ?? undefined} data-action="live"
    aria-label={liveLabel(live, recording, now)}
    style={{ left: `${camera.x - out - left}px`, top: `${camera.y - out}px`, width: `${camera.width + 2 * out + left + right}px`, height: `${camera.height + 2 * out}px`,
      gridTemplateColumns: `${Math.max(0, left - ISLAND_EDGE)}px ${camera.width + 2 * out}px 1fr` }}
    {...press.handlers}
    onClick={() => {
      if (press.wasLong()) return;
      setOpening(true);
      setWide(false);
      action?.(`live:${a.key}`);
    }}>
    <LiveLead a={a} more={live.length - 1}>{!right && trail}</LiveLead>
    <span class="live-hole" />
    <span class="live-trail">{!!right && trail}</span>
  </button>;
}

/**
 * The recording light: a ring around the camera's cutout while an app uses the camera (green), captures the screen
 * (red) or records audio (orange) - StatusChrome.kt's AppOps watch. Drawn where the camera is on this screen (cover
 * folded, inner unfolded). A tap opens the control center, whose privacy row (ui/privacy.tsx) names who uses it
 * (data-action "privacy": the host makes it touchable on the strip, StatusChrome.action).
 */
export function RecordingRing({ kind, camera, apps, action }: { kind: NonNullable<ChromeState["recording"]>; camera: NonNullable<ChromeState["camera"]>; apps?: string[]; action?: ChromeAction }) {
  // [camera] is the hole itself (StatusChrome.kt CameraHole: the OEM's hole / the cutout path's shape, not the padded
  // cutout box - a ring from the box was twice the camera, 11-25). The ring hugs it: --rec-gap clear of the hole, then
  // --rec-stroke, concentric (a pill hole gets a pill ring). Sizes live in chrome.css; the box is laid out by CSS calc.
  return <button type="button" class="status-rec-ring" data-kind={kind} data-action="privacy" aria-label={`${recordingLabel(kind, apps)}. Show who`}
    onClick={() => action?.("privacy")}
    style={{ "--hole-x": `${camera.x}px`, "--hole-y": `${camera.y}px`, "--hole-w": `${camera.width}px`, "--hole-h": `${camera.height}px` }} />;
}

/** No camera cutout on this screen (a desktop, a tablet without one): the light as a dot before the status icons. */
function RecordingDot({ kind, apps }: { kind: NonNullable<ChromeState["recording"]>; apps?: string[] }) {
  return <span class="status-rec-dot" data-kind={kind} role="img" aria-label={recordingLabel(kind, apps)} />;
}

/** The notification icons after the clock: their own reader, so a status change doesn't redraw the clock. */
function Notifs() {
  return <NotificationIcons status={useSystemStatus()} />;
}

/**
 * The control button: the recording dot, then the system icons (statusicons.tsx; the stock set when the host sends
 * "system.status", else ChromeState's network kind and VPN), the battery rightmost. Beside a centred camera hole its
 * width ends at the hole, and the icons that don't fit go (lowest priority first).
 */
function Controls({ state, battery, action, right, islandRight }: { state: ChromeState; battery: number | null; action: ChromeAction; right: number; islandRight: number }) {
  const status = useSystemStatus();
  // The hole's right edge: the camera's cutout on the strip, else the hole's left edge and a punch-hole's width.
  const holeRight = state.holeLeft == null ? null : state.camera ? state.camera.x + state.camera.width : state.holeLeft + 28;
  const maxWidth = holeRight != null ? `${Math.max(0, innerWidth - right - holeRight - 6 - islandRight)}px` : undefined;
  return <button class="status-indicators" data-action="controls" aria-label={statusLabel(state, battery, statusWords(status))} onClick={() => action("controls")} style={maxWidth ? { maxWidth } : undefined}>
    {state.recording && !state.camera && <RecordingDot kind={state.recording} apps={state.recordingApps} />}
    {status ? <SystemIcons status={status} vpn={!!state.vpn} first={battery != null ? <Battery state={state} battery={battery} saver={status.batterySaver} /> : null} />
      : <Indicators state={state} battery={battery} />}
  </button>;
}

function Battery({ state, battery, saver }: { state: ChromeState; battery: number; saver?: boolean }) {
  // Stock: amber in battery saver, red when low (15% and below) and not charging.
  const tone = saver ? "saver" : battery <= 15 && !state.charging ? "low" : undefined;
  return <span class="status-battery" data-tone={tone}><svg viewBox="0 0 28 16" aria-hidden="true"><rect x="1" y="2" width="22" height="12" rx="3" /><path d="M26 6v4" /><rect class="battery-level" x="3" y="4" width={18 * battery / 100} height="8" rx="1" /></svg>{state.charging && <Mark kind="charging" />}<span>{battery}%</span></span>;
}

/** A host without "system.status" (desktop, an older APK): ChromeState's own network kind and VPN. */
function Indicators({ state, battery }: { state: ChromeState; battery: number | null }) {
  return <>
      {state.vpn && <span title="VPN connected"><Mark kind="vpn" /></span>}
      {state.network && <span title={state.network}><Mark kind={state.network} /></span>}
      {battery != null && <Battery state={state} battery={battery} />}
      {state.network == null && battery == null && <span>Controls</span>}
  </>;
}
