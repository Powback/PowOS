import { useEffect, useState } from "preact/hooks";

/** "now", "5m", "3h", "2d": how long ago [time] (Unix seconds) was, as a notification shade shows it. */
export function ago(time: number) {
  const s = Date.now() / 1000 - time;
  if (s < 60) return "now";
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86400) return `${Math.floor(s / 3600)}h`;
  return `${Math.floor(s / 86400)}d`;
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
