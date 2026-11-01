import { useEffect, useState } from "preact/hooks";

/** "now", "5m", "3h", "2d": how long ago [time] (Unix seconds) was, as a notification shade shows it. */
export function ago(time: number) {
  const s = Date.now() / 1000 - time;
  if (s < 60) return "now";
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86400) return `${Math.floor(s / 3600)}h`;
  return `${Math.floor(s / 86400)}d`;
}

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const hm = (d: Date) => `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
const dayOf = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();

/**
 * When [ms] (Unix ms) was, as a day's clock reads it: "16:36" today, "yesterday 21:10", "29 Oct 21:10" this year, else
 * "29 Oct 2025". Unlike ago() it names the moment itself, so it doesn't drift with the time the page was drawn.
 */
export function clockAt(ms: number, now = new Date()) {
  const d = new Date(ms);
  const days = Math.round((dayOf(now) - dayOf(d)) / 86_400_000);
  if (days <= 0) return hm(d);
  if (days === 1) return `yesterday ${hm(d)}`;
  const date = `${d.getDate()} ${MONTHS[d.getMonth()]}`;
  return d.getFullYear() === now.getFullYear() ? `${date} ${hm(d)}` : `${date} ${d.getFullYear()}`;
}

/**
 * The time, for a clock that shows hours and minutes: changes on each minute's turn (not a poll every few seconds),
 * and not at all while the page is hidden (a window put away, the screen off) - read again as it shows.
 */
export function useMinuteClock(): Date {
  const [now, setNow] = useState(() => new Date());
  useEffect(() => {
    let timer = 0;
    const next = () => {
      clearTimeout(timer);
      if (document.hidden) return;
      setNow(new Date());
      timer = window.setTimeout(next, 60_000 - (Date.now() % 60_000) + 50);
    };
    next();
    document.addEventListener("visibilitychange", next);
    return () => {
      clearTimeout(timer);
      document.removeEventListener("visibilitychange", next);
    };
  }, []);
  return now;
}
