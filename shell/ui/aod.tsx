/**
 * The screen-off display (index.html?mode=aod; the PowOS doze component, PowosDozeService): the time and date, the
 * battery, and an icon for each app with something new - on black, dim, in the theme's colors. It moves a few pixels
 * every minute so nothing stays lit in one place (an OLED panel keeps what it shows too long).
 */
import { useEffect, useState } from "preact/hooks";
import { powos } from "../bridge.ts";
import type { NotificationList } from "../types.ts";

/** How far it wanders from the middle, px. */
const DRIFT = 18;

const two = (n: number) => String(n).padStart(2, "0");

export function Aod() {
  const [now, setNow] = useState(new Date());
  const [battery, setBattery] = useState<{ level: number | null; charging: boolean }>({ level: null, charging: false });
  const [list, setList] = useState<NotificationList>({ available: true, items: [] });
  const [drift, setDrift] = useState({ x: 0, y: 0 });
  useEffect(() => {
    const tick = () => {
      setNow(new Date());
      powos.system.battery().then(setBattery);
      setDrift({ x: Math.round((Math.random() * 2 - 1) * DRIFT), y: Math.round((Math.random() * 2 - 1) * DRIFT) });
    };
    tick();
    powos.notifications.list().then(setList);
    const off = powos.on("notifications.changed", setList);
    // On the minute, so the clock turns over when the minute does.
    let timer = 0;
    const next = () => (timer = window.setTimeout(() => (tick(), next()), 60_000 - (Date.now() % 60_000) + 50));
    next();
    return () => (clearTimeout(timer), off());
  }, []);
  // One icon per app, newest first.
  const apps = list.items.filter((n, i) => n.icon && list.items.findIndex((m) => m.app === n.app) === i).slice(0, 6);
  return (
    <div class="aod" style={{ transform: `translate(${drift.x}px, ${drift.y}px)` }}>
      <div class="aod-time">
        {two(now.getHours())}:{two(now.getMinutes())}
      </div>
      <div class="aod-date">{now.toLocaleDateString(undefined, { weekday: "long", day: "numeric", month: "long" }).toLowerCase()}</div>
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
  );
}
