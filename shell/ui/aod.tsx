/**
 * The screen-off display (index.html?mode=aod; the PowOS doze component, PowosDozeService): the time and date, the
 * battery, and an icon for each app with something new - on black, dim, in the theme's colors. It moves a few pixels
 * every minute so nothing stays lit in one place (an OLED panel keeps what it shows too long).
 *
 * What's playing is one line under the date (title · artist), while it plays: display only while dozing (the doze window takes no
 * touch - a touch wakes the phone), with previous / play-pause / next when it does take them ([controls]: StandBy
 * upright). The host tells a track or play/pause change while the screen is off (ShellMedia.whileOff), never the
 * position. An in-display fingerprint sensor's spot (lock.sensor, the lock face's geometry) is drawn where the sensor
 * is, outline only and dim, and doesn't wander (it marks the sensor); a side sensor (the OnePlus Open) has none.
 */
import { useEffect, useState } from "preact/hooks";
import { powos } from "../bridge.ts";
import type { LockSensor, MediaState, NotificationList } from "../types.ts";
import { askMedia, media, refreshMedia, sessionsOf, usePlaying } from "./media.tsx";
import { Icon } from "./icons.tsx";
import { clockVars, loadLockFace, lockFace } from "./lockstyle.ts";

/** How far it wanders from the middle, px. */
const DRIFT = 18;

const two = (n: number) => String(n).padStart(2, "0");

/** The now-playing line: title · artist, and the transport when the window takes touches. */
function AodMedia({ m, controls }: { m: MediaState; controls: boolean }) {
  const [playing, toggle] = usePlaying(m);
  const who = m.artist ?? m.app ?? "";
  const stop = (e: Event) => e.stopPropagation();
  return (
    <div class="aod-media" data-playing={playing ? "1" : "0"}>
      <div class="aod-track">
        {!controls && <Icon name="play" />}
        <span class="aod-title">{m.title}</span>
        {who && <span class="aod-artist"> · {who}</span>}
      </div>
      {controls && (
        <div class="aod-transport" onClick={stop}>
          <button type="button" aria-label="Previous" onClick={() => void powos.media.control("previous", m.package).catch(() => {})}>
            <Icon name="skipPrevious" />
          </button>
          <button type="button" aria-label={playing ? "Pause" : "Play"} onClick={toggle}>
            <Icon name={playing ? "pause" : "play"} />
          </button>
          <button type="button" aria-label="Next" onClick={() => void powos.media.control("next", m.package).catch(() => {})}>
            <Icon name="skipNext" />
          </button>
        </div>
      )}
    </div>
  );
}

/** The in-display fingerprint sensor's spot, at the sensor (CSS px from the host), outline only. */
function AodFingerprint({ s }: { s: LockSensor | null }) {
  const p = s?.enrolled && s.kind === "udfps" ? s.spot : null;
  if (!p) return null;
  return (
    <div class="aod-fp" aria-hidden="true" style={{ left: `${p.x - p.r}px`, top: `${p.y - p.r}px`, width: `${2 * p.r}px`, height: `${2 * p.r}px` }}>
      <Icon name="fingerprint" />
    </div>
  );
}

export function Aod({ controls = false }: { controls?: boolean }) {
  const [now, setNow] = useState(new Date());
  const [battery, setBattery] = useState<{ level: number | null; charging: boolean }>({ level: null, charging: false });
  const [list, setList] = useState<NotificationList>({ available: true, items: [] });
  const [drift, setDrift] = useState({ x: 0, y: 0 });
  /** The fingerprint sensor (lock.sensor): null until known, or an older APK (no spot). */
  const [sensor, setSensor] = useState<LockSensor | null>(null);
  useEffect(() => {
    askMedia();
    // The lock face's clock style (lockstyle.ts), read as it shows: one style for every clock face.
    loadLockFace();
    // Asked again each time it's shown: a finger enrolled meanwhile, the inner / outer screen (its own sensor place).
    const askSensor = () => void powos.lock.sensor().then(setSensor, () => setSensor(null));
    askSensor();
    const tick = () => {
      setNow(new Date());
      powos.system.battery().then(setBattery);
      setDrift({ x: Math.round((Math.random() * 2 - 1) * DRIFT), y: Math.round((Math.random() * 2 - 1) * DRIFT) });
    };
    tick();
    // A minute's turn reads it again too (a host older than ShellMedia.whileOff tells nothing while the screen is off).
    const tickMedia = () => (tick(), refreshMedia());
    powos.notifications.list().then(setList);
    const off = powos.on("notifications.changed", setList);
    // On the minute, so the clock turns over when the minute does.
    let timer = 0;
    const next = () => (timer = window.setTimeout(() => (tickMedia(), next()), 60_000 - (Date.now() % 60_000) + 50));
    next();
    const shown = () => document.visibilityState === "visible" && (askSensor(), tickMedia());
    document.addEventListener("visibilitychange", shown);
    return () => (clearTimeout(timer), off(), document.removeEventListener("visibilitychange", shown));
  }, []);
  // One icon per app, newest first.
  const apps = list.items.filter((n, i) => n.icon && list.items.findIndex((m) => m.app === n.app) === i).slice(0, 6);
  // Display only, it shows while playing (a paused session isn't news); with the transport a paused one too.
  const playing = sessionsOf(media.value, 1).find((m) => controls || m.playing);
  return (
    <>
      <div class="aod" style={{ transform: `translate(${drift.x}px, ${drift.y}px)` }}>
        <div class="aod-time" style={clockVars(lockFace.value)}>
          {two(now.getHours())}:{two(now.getMinutes())}
        </div>
        <div class="aod-date">{now.toLocaleDateString(undefined, { weekday: "long", day: "numeric", month: "long" }).toLowerCase()}</div>
        {playing && <AodMedia m={playing} controls={controls} />}
        {battery.level != null && (
          <div class="aod-battery">
            {battery.charging ? "⚡ " : ""}
            {battery.level}%
          </div>
        )}
        {apps.length > 0 && (
          <div class="aod-apps">
            {apps.map((n) => (
              <img key={n.key} src={n.icon!} alt="" />
            ))}
          </div>
        )}
      </div>
      <AodFingerprint s={sensor} />
    </>
  );
}
