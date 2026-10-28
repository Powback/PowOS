/**
 * What widgets read: today's totals and the last 7 days per type, per source, from the `daily` table (the module keeps
 * it from the samples). Pure functions over rows - the same for the page and the widget.
 */
import type { HealthType } from "./app";

export interface DailyRow {
  kind: HealthType;
  source: string;
  day: bigint;
  sum: number;
  count: number;
  min: number;
  max: number;
  last: number;
  lastAt: bigint;
}

export const KINDS: HealthType[] = ["steps", "heart_rate", "sleep", "exercise", "weight", "active_calories"];

export const LABEL: Record<HealthType, string> = {
  steps: "Steps",
  heart_rate: "Heart rate",
  sleep: "Sleep",
  exercise: "Exercise",
  weight: "Weight",
  active_calories: "Active calories",
};

export const UNIT: Record<HealthType, string> = { steps: "", heart_rate: "bpm", sleep: "h", exercise: "min", weight: "kg", active_calories: "kcal" };

/** The device behind a package, for the ones that write Health Connect; anything else shows its last name part. */
const APPS: Record<string, string> = {
  "com.garmin.android.apps.connectmobile": "Garmin",
  "com.fitbit.FitbitMobile": "Fitbit",
  "com.ouraring.oura": "Oura",
  "com.sec.android.app.shealth": "Samsung Health",
  "com.google.android.apps.fitness": "Google Fit",
  "com.google.android.apps.healthdata": "Health Connect",
  "com.withings.wiscale2": "Withings",
  "com.xiaomi.wearable": "Xiaomi",
  "com.huawei.health": "Huawei Health",
  "com.polar.polarflow": "Polar",
  "com.whoop.android": "Whoop",
};
export const sourceName = (pkg: string) => APPS[pkg] ?? pkg.split(".").slice(-1)[0];

/** How a type's day figure comes from a row: sums add up, heart rate averages, weight is the latest. */
export function figure(kind: HealthType, r: DailyRow): number {
  switch (kind) {
    case "heart_rate":
      return r.count ? r.sum / r.count : 0;
    case "weight":
      return r.last;
    case "sleep":
      return r.sum / 60;
    default:
      return r.sum;
  }
}

export const show = (kind: HealthType, v: number) =>
  kind === "steps" || kind === "active_calories" || kind === "exercise" || kind === "heart_rate"
    ? Math.round(v).toLocaleString()
    : v.toFixed(1);

export interface PerSource {
  source: string;
  value: number;
}
export interface Day {
  /** Local midnight, ms. */
  day: number;
  /** The headline figure (the source with the most, never summed across sources: two apps often see the same steps). */
  value: number | null;
  sources: PerSource[];
}

/** Local midnights of the last [n] days, today last. */
export function dayStarts(now = Date.now(), n = 7): number[] {
  const out: number[] = [];
  for (let i = n - 1; i >= 0; i--) {
    const d = new Date(now);
    d.setHours(0, 0, 0, 0);
    d.setDate(d.getDate() - i);
    out.push(d.getTime());
  }
  return out;
}

export function week(rows: DailyRow[], kind: HealthType, now = Date.now()): Day[] {
  return dayStarts(now).map((day) => {
    const sources = rows
      .filter((r) => r.kind === kind && Math.abs(Number(r.day) - day) < 2 * 3_600_000)
      .map((r) => ({ source: r.source, value: figure(kind, r) }))
      .sort((a, b) => b.value - a.value);
    return { day, value: sources.length ? sources[0].value : null, sources };
  });
}

/** Today's figure per type, with its sources. */
export const today = (rows: DailyRow[], now = Date.now()) =>
  KINDS.map((kind) => ({ kind, day: week(rows, kind, now)[6] })).filter((t) => t.day.value != null);

/** The query both surfaces subscribe to: this week's day rows (a few dozen). */
export const weekQuery = (now = Date.now()) => `SELECT * FROM daily WHERE day >= ${dayStarts(now)[0] - 2 * 3_600_000}`;
