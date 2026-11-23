/**
 * The lock face's charging line (lock.tsx), as the stock lock screen words it: "Super fast charging · 1 h until full".
 * The class comes from the host (system/Charging.kt: by the charger's power, never by vendor); the time is Android's
 * own estimate and is left out when Android can't tell. Nothing while on battery.
 */
import type { Battery } from "../types.ts";

/** "45 min", "1 h", "1 h 20 min" - rounded up to the minute (never "0 min" while still charging). */
export function untilFull(ms: number): string {
  const min = Math.max(1, Math.ceil(ms / 60000));
  const h = Math.floor(min / 60);
  const m = min % 60;
  return h === 0 ? `${m} min` : m === 0 ? `${h} h` : `${h} h ${m} min`;
}

/** What the charger is doing, in words; null on battery (or an older host that only says charging: plain "Charging"). */
export function chargeKind(b: Battery): string | null {
  if (b.full) return "Charged";
  if (b.held) return "Charging paused";
  if (!b.charging) return null;
  const wireless = b.plugged === "wireless";
  switch (b.speed) {
    case "superfast":
      return wireless ? "Super fast wireless charging" : "Super fast charging";
    case "fast":
      return wireless ? "Fast wireless charging" : "Fast charging";
    case "slow":
      return "Charging slowly";
    default:
      return wireless ? "Charging wirelessly" : "Charging";
  }
}

/** The whole line: the kind, then the time until full when Android gives one. */
export function chargeLine(b: Battery): string | null {
  const kind = chargeKind(b);
  if (!kind) return null;
  return b.charging && !b.full && b.fullInMs != null && b.fullInMs > 0 ? `${kind} · ${untilFull(b.fullInMs)} until full` : kind;
}
