/** The same title bar, resize grip and status bar in every host. Native code supplies data, never glyphs or labels. */
import { useEffect, useState } from "preact/hooks";
import type { ChromeState } from "../types.ts";
import { FpsMeter } from "./fpsmeter.tsx";

export type ChromeAction = (action: string) => void;

export function Mark({ kind }: { kind: string }) {
  const paths: Record<string, string> = {
    minimise: "M4 12h16", maximise: "M5 5h14v14H5z", restore: "M5 9h10v10H5z M9 5h10v10",
    close: "M5 5l14 14M5 19L19 5", tile: "M4 5h7v14H4z M13 5h7v14h-7z", resize: "M9 17l8-8M15 18l3-3",
    wifi: "M3 8a15 15 0 0 1 18 0M6 12a10 10 0 0 1 12 0M9 16a5 5 0 0 1 6 0M12 20h.01",
    cellular: "M4 20v-3M9 20v-7M14 20V9M19 20V4", ethernet: "M4 5h16v10H4zM12 15v5M8 20h8",
    charging: "M14 2L5 13h7l-2 9 9-13h-7z",
    offline: "M5 5l14 14M5 19L19 5", vpn: "M7 10V7a5 5 0 0 1 10 0v3M5 10h14v11H5z",
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

function statusLabel(state: ChromeState, battery: number | null) {
  const parts = ["System controls", state.network];
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
  return <div class={`status-chrome${hole != null ? " has-hole" : ""}${merged ? " merged" : ""}`} style={{ paddingLeft: `${left}px`, paddingRight: `${right}px`, ...(hole != null ? { "--hole-left": `${hole}px` } : {}) }}>
    {/* data-action: the host makes only these touchable on the strip (chrome.regions -> ShadeHost edgeRegion). */}
    <button class="status-clock" data-action="notifications" aria-label={`Notifications${state.notifications ? `, ${state.notifications} new` : ""}, ${time}`} onClick={() => action("notifications")}>
      <time dateTime={now.toISOString()}>{time}</time>
    </button>
    <FpsMeter />
    <button class="status-indicators" data-action="controls" aria-label={statusLabel(state, battery)} onClick={() => action("controls")}>
      <Indicators state={state} battery={battery} />
    </button>
    <RecordingLight state={state} action={action} />
  </div>;
}

const RECORDING_WORDS = { camera: "Camera", mic: "Microphone", screen: "Screen recording" } as const;
function recordingLabel(kind: NonNullable<ChromeState["recording"]>, apps?: string[]) {
  return `${RECORDING_WORDS[kind]} in use${apps?.length ? ` by ${apps.join(", ")}` : ""}`;
}

/** The recording light on the camera's cutout (none on this screen: [Indicators]' dot). */
function RecordingLight({ state, action }: { state: ChromeState; action: ChromeAction }) {
  return state.recording && state.camera ? <RecordingRing kind={state.recording} camera={state.camera} apps={state.recordingApps} action={action} /> : null;
}

/**
 * The recording light: a ring around the camera's cutout while an app uses the camera (green), captures the screen
 * (red) or records audio (orange) - StatusChrome.kt's AppOps watch. Drawn where the camera is on this screen (cover
 * folded, inner unfolded). A tap opens the control center, whose privacy row (ui/privacy.tsx) names who uses it
 * (data-action "privacy": the host makes it touchable on the strip, StatusChrome.action).
 */
export function RecordingRing({ kind, camera, apps, action }: { kind: NonNullable<ChromeState["recording"]>; camera: NonNullable<ChromeState["camera"]>; apps?: string[]; action?: ChromeAction }) {
  const size = Math.max(camera.width, camera.height) + 6;
  return <button type="button" class="status-rec-ring" data-kind={kind} data-action="privacy" aria-label={`${recordingLabel(kind, apps)}. Show who`}
    onClick={() => action?.("privacy")}
    style={{ left: `${camera.x + camera.width / 2 - size / 2}px`, top: `${camera.y + camera.height / 2 - size / 2}px`, width: `${size}px`, height: `${size}px` }} />;
}

/** No camera cutout on this screen (a desktop, a tablet without one): the light as a dot before the status icons. */
function RecordingDot({ kind, apps }: { kind: NonNullable<ChromeState["recording"]>; apps?: string[] }) {
  return <span class="status-rec-dot" data-kind={kind} role="img" aria-label={recordingLabel(kind, apps)} />;
}

function Indicators({ state, battery }: { state: ChromeState; battery: number | null }) {
  return <>
      {state.recording && !state.camera && <RecordingDot kind={state.recording} apps={state.recordingApps} />}
      {state.vpn && <span title="VPN connected"><Mark kind="vpn" /></span>}
      {state.network && <span title={state.network}><Mark kind={state.network} /></span>}
      {battery != null && <span class="status-battery"><svg viewBox="0 0 28 16" aria-hidden="true"><rect x="1" y="2" width="22" height="12" rx="3" /><path d="M26 6v4" /><rect class="battery-level" x="3" y="4" width={18 * battery / 100} height="8" rx="1" /></svg>{state.charging && <Mark kind="charging" />}<span>{battery}%</span></span>}
      {state.network == null && battery == null && <span>Controls</span>}
  </>;
}
