/**
 * StandBy (index.html?mode=standby; the "when charging" screensaver, PowosDozeService): the phone on its side on a
 * charger as a bedside / desk clock. Landscape: a big clock (date and charge under it) and two stacks of cards beside
 * it, each swiped up and down on its own (CSS scroll-snap, a dot per card) - the lock face's glance (LockGlance.kt:
 * weather, next alarm, next event; "lock.glance") and what's playing (media.tsx; play/pause right there). Upright it is
 * the screen-off display (aod.tsx). In the dark ("standby.dark", the dream's light sensor; until it says, 22-07 h) it
 * turns dim red, as stock's night mode: nothing bright or blue by the bed. A tap anywhere but a card's button ends the
 * dream (powos.standby.exit): the lock screen under it shows. It wanders a few px a minute (an OLED keeps a still image).
 */
import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";
import { powos } from "../bridge.ts";
import type { LockGlanceState, MediaState } from "../types.ts";
import { Aod } from "./aod.tsx";
import { glanceTime } from "./lockglance.tsx";
import { askMedia, media, sessionsOf, usePlaying } from "./media.tsx";
import { Icon } from "./icons.tsx";
import { PageDots, paintDots } from "./pagedots.tsx";

const two = (n: number) => String(n).padStart(2, "0");
/** How far it wanders from its place, px. */
const DRIFT = 8;
/** Night by the clock, until the light sensor says (or where there is none): 22:00-07:00. */
export const nightByClock = (d: Date) => d.getHours() >= 22 || d.getHours() < 7;

export type StandbyCard =
  | { kind: "weather"; temp: string; icon: string; place: string }
  | { kind: "alarm"; at: number }
  | { kind: "event"; title: string; at: number }
  | { kind: "media"; m: MediaState }
  | { kind: "battery"; level: number | null; charging: boolean }
  | { kind: "date" };

/**
 * The two stacks: the left one the day (alarm, event, weather; the date at its end), the right one what's playing first,
 * then the charge. Only what is there; each stack always keeps its last card, so neither is ever empty.
 */
export function standbyStacks(g: LockGlanceState | null, m: MediaState | null, battery: { level: number | null; charging: boolean }): [StandbyCard[], StandbyCard[]] {
  const left: StandbyCard[] = [];
  if (g?.alarm != null) left.push({ kind: "alarm", at: g.alarm });
  if (g?.event?.title) left.push({ kind: "event", title: g.event.title, at: g.event.at });
  if (g?.weather?.temp) left.push({ kind: "weather", ...g.weather });
  left.push({ kind: "date" });
  const right: StandbyCard[] = sessionsOf(m, 1).map((s) => ({ kind: "media", m: s }) as StandbyCard);
  right.push({ kind: "battery", ...battery });
  return [left, right];
}

function MediaBody({ m }: { m: MediaState }) {
  const [playing, toggle] = usePlaying(m);
  return (
    <>
      {m.art && <img class="standby-art" src={m.art} alt="" />}
      <div class="standby-big standby-cut">{m.title}</div>
      <div class="standby-small standby-cut">{m.artist ?? m.app ?? ""}</div>
      <button type="button" class="standby-play" aria-label={playing ? "Pause" : "Play"} onClick={(e) => (e.stopPropagation(), toggle())}>
        <Icon name={playing ? "pause" : "play"} />
      </button>
    </>
  );
}

function CardBody({ c, now }: { c: StandbyCard; now: Date }) {
  switch (c.kind) {
    case "weather":
      return (
        <>
          <i class="standby-wx" aria-hidden="true">{c.icon}</i>
          <div class="standby-big">{c.temp}</div>
          <div class="standby-small">{c.place.toLowerCase()}</div>
        </>
      );
    case "alarm":
      return (
        <>
          <div class="standby-small">alarm</div>
          <div class="standby-big">{glanceTime(c.at, now.getTime())}</div>
        </>
      );
    case "event":
      return (
        <>
          <div class="standby-small">{glanceTime(c.at, now.getTime())}</div>
          <div class="standby-big standby-cut2">{c.title}</div>
        </>
      );
    case "media":
      return <MediaBody m={c.m} />;
    case "battery":
      return (
        <>
          <div class="standby-small">{c.charging ? "charging" : "battery"}</div>
          <div class="standby-big">{c.level != null ? `${c.level}%` : "-"}</div>
        </>
      );
    case "date":
      return (
        <>
          <div class="standby-small">{now.toLocaleDateString(undefined, { month: "long" }).toLowerCase()}</div>
          <div class="standby-big standby-day">{now.getDate()}</div>
          <div class="standby-small">{now.toLocaleDateString(undefined, { weekday: "long" }).toLowerCase()}</div>
        </>
      );
  }
}

/** One stack: its cards one under the other, snapped one per stop; the page dots follow the scroll (pagedots.tsx). */
function Stack({ cards, now, name }: { cards: StandbyCard[]; now: Date; name: string }) {
  const dots = useRef<HTMLDivElement>(null);
  const track = useRef<HTMLDivElement>(null);
  const paint = () => {
    const t = track.current;
    if (t) paintDots(dots.current, t.scrollTop / Math.max(1, t.clientHeight), false);
  };
  useLayoutEffect(paint, [cards.length]);
  return (
    <div class="standby-stack" data-stack={name}>
      <div class="standby-track" ref={track} onScroll={paint}>
        {cards.map((c) => (
          <div key={c.kind} class={`standby-card standby-${c.kind}`} data-kind={c.kind}>
            <CardBody c={c} now={now} />
          </div>
        ))}
      </div>
      {cards.length > 1 && <PageDots count={cards.length} dotsRef={dots} class="standby-dots" />}
    </div>
  );
}

const landscapeQuery = () => matchMedia("(orientation: landscape)");

export function Standby() {
  const [landscape, setLandscape] = useState(landscapeQuery().matches);
  useEffect(() => {
    const q = landscapeQuery();
    const on = () => setLandscape(q.matches);
    q.addEventListener("change", on);
    return () => q.removeEventListener("change", on);
  }, []);
  return landscape ? <StandbyFace /> : <Aod />;
}

function StandbyFace() {
  const [now, setNow] = useState(new Date());
  const [battery, setBattery] = useState<{ level: number | null; charging: boolean }>({ level: null, charging: true });
  const [g, setG] = useState<LockGlanceState | null>(null);
  const [dark, setDark] = useState<boolean | null>(null);
  const [drift, setDrift] = useState({ x: 0, y: 0 });
  useEffect(() => {
    askMedia();
    powos.lock.glance().then(setG, () => {});
    const offs = [powos.on("lock.glance", setG), powos.on("standby.dark", (d: boolean) => setDark(!!d))];
    const tick = () => {
      setNow(new Date());
      powos.system.battery().then(setBattery, () => {});
      setDrift({ x: Math.round((Math.random() * 2 - 1) * DRIFT), y: Math.round((Math.random() * 2 - 1) * DRIFT) });
    };
    tick();
    // On the minute, so the clock turns over when the minute does.
    let timer = 0;
    const next = () => (timer = window.setTimeout(() => (tick(), next()), 60_000 - (Date.now() % 60_000) + 50));
    next();
    return () => (clearTimeout(timer), offs.forEach((off) => off()));
  }, []);
  const night = dark ?? nightByClock(now);
  useEffect(() => {
    document.documentElement.dataset.night = night ? "1" : "0";
  }, [night]);
  const [left, right] = standbyStacks(g, media.value, battery);
  return (
    <div class="standby" data-night={night ? "1" : "0"} style={{ transform: `translate(${drift.x}px, ${drift.y}px)` }} onClick={() => void powos.standby.exit().catch(() => {})}>
      <div class="standby-clock">
        <div class="standby-time">
          {two(now.getHours())}:{two(now.getMinutes())}
        </div>
        <div class="standby-date">
          {now.toLocaleDateString(undefined, { weekday: "short", day: "numeric", month: "short" }).toLowerCase()}
          {battery.level != null && ` · ${battery.charging ? "⚡" : ""}${battery.level}%`}
        </div>
      </div>
      <Stack cards={left} now={now} name="left" />
      <Stack cards={right} now={now} name="right" />
    </div>
  );
}
