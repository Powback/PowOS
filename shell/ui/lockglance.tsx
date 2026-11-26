/**
 * The lock face's glance under the date (LockGlance.kt): the next alarm, the next event of the next 12 hours and the
 * weather now, as small chips on one line - what isn't there (no alarm, no event or no calendar permission, no weather
 * yet) simply isn't shown. The page never polls: the state comes once as the face mounts and then on every change the
 * native side pushes ("lock.glance": an alarm or calendar change, the weather's 30 minutes).
 */
import { useEffect, useState } from "preact/hooks";
import { powos } from "../bridge.ts";
import type { LockGlanceState } from "../types.ts";

const two = (n: number) => String(n).padStart(2, "0");
const DAY = 24 * 60 * 60 * 1000;

/** A time on the face: "07:30"; a day or more ahead, its weekday first ("tue 07:30"). */
export function glanceTime(at: number, now: number): string {
  const d = new Date(at);
  const hm = `${two(d.getHours())}:${two(d.getMinutes())}`;
  return at - now >= DAY - 60_000 ? `${d.toLocaleDateString(undefined, { weekday: "short" }).toLowerCase()} ${hm}` : hm;
}

export type GlanceChip = { kind: "alarm" | "event" | "weather"; label: string; text: string; icon?: string };

/** The chips to show, in order: alarm, event, weather; only the parts that are there. */
export function glanceChips(g: LockGlanceState | null, now: number): GlanceChip[] {
  if (!g) return [];
  const out: GlanceChip[] = [];
  if (g.alarm != null) {
    const t = glanceTime(g.alarm, now);
    out.push({ kind: "alarm", label: `Alarm ${t}`, text: t });
  }
  if (g.event?.title) {
    const t = glanceTime(g.event.at, now);
    out.push({ kind: "event", label: `${g.event.title} at ${t}`, text: `${t} ${g.event.title}` });
  }
  if (g.weather?.temp) {
    const place = g.weather.place ? ` ${g.weather.place.toLowerCase()}` : "";
    out.push({ kind: "weather", label: `${g.weather.temp}${place}`, text: `${g.weather.temp}${place}`, icon: g.weather.icon });
  }
  return out;
}

/** The alarm's and the event's line glyphs (the status bar's stroke style). */
const PATHS = {
  alarm: "M12 21a8 8 0 1 0 0-16 8 8 0 0 0 0 16zM12 9v4l2.5 2M4 5l3-2.5M20 5l-3-2.5",
  event: "M4 6h16v14H4zM4 10h16M8 3v4M16 3v4",
};

function ChipIcon({ c }: { c: GlanceChip }) {
  if (c.kind === "weather") return <i class="lock-glance-wx" aria-hidden="true">{c.icon}</i>;
  return <svg viewBox="0 0 24 24" aria-hidden="true"><path d={PATHS[c.kind]} /></svg>;
}

export function LockGlance({ now }: { now: Date }) {
  const [g, setG] = useState<LockGlanceState | null>(null);
  useEffect(() => {
    // An older APK has no glance: nothing shown.
    powos.lock.glance().then(setG, () => {});
    return powos.on("lock.glance", setG);
  }, []);
  const chips = glanceChips(g, now.getTime());
  if (!chips.length) return null;
  return (
    <div class="lock-glance">
      {chips.map((c) => (
        <span key={c.kind} class={`lock-glance-chip lock-glance-${c.kind}`} data-kind={c.kind} aria-label={c.label} title={c.label}>
          <ChipIcon c={c} />
          <span class="lock-glance-text">{c.text}</span>
        </span>
      ))}
    </div>
  );
}
