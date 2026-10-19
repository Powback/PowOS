/** "now", "5m", "3h", "2d": how long ago [time] (Unix seconds) was, as a notification shade shows it. */
export function ago(time: number) {
  const s = Date.now() / 1000 - time;
  if (s < 60) return "now";
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86400) return `${Math.floor(s / 3600)}h`;
  return `${Math.floor(s / 86400)}d`;
}
