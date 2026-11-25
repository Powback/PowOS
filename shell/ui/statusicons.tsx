/**
 * The status bar's system icons and notification icons, the stock set (StatusSignals.kt -> "system.status"): each SIM's
 * signal with its network type, roaming and data arrows, Wi-Fi strength, airplane, hotspot, VPN, Bluetooth (and a
 * headset's battery), NFC, location in use, do not disturb, vibrate/silent, the next alarm, data saver, casting.
 *
 * Their own state ([useSystemStatus]): a change redraws these icons only, never the clock or the rest of the strip.
 * Order and overflow as stock: [SystemIcons] lists them by priority, the first sits rightmost (flex row-reverse), and a
 * row that doesn't fit wraps its lowest-priority icons out of sight (the cover screen beside its camera) - a dot says
 * some are hidden, as stock's does.
 */
import type { JSX } from "preact";
import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";
import { powos } from "../bridge.ts";
import type { StatusCell, SystemStatus } from "../types.ts";

/** The page's one copy of the host's status icons and who draws from it (one subscription for both icon groups). */
let current: SystemStatus | null = null;
const readers = new Set<(s: SystemStatus | null) => void>();
let started = false;
function set(s: SystemStatus | null) {
  current = s;
  readers.forEach((r) => r(s));
}
function start() {
  if (started) return;
  started = true;
  powos.on("system.status", (s: SystemStatus) => set(s));
  powos.system.status?.().then((s) => { if (current == null && s) set(s); }).catch(() => {});
}

/** The host's status icons, kept fresh by "system.status"; null on a host that has none (desktop, an older APK). */
export function useSystemStatus(): SystemStatus | null {
  const [status, setStatus] = useState<SystemStatus | null>(current);
  useEffect(() => {
    start();
    readers.add(setStatus);
    setStatus(current);
    return () => { readers.delete(setStatus); };
  }, []);
  return status;
}

/** Marks overflow on [ref]'s row: a child wrapped out of its first line. Measured after each draw and on resize only. */
function useOverflow<T extends HTMLElement>(deps: unknown[]) {
  const ref = useRef<T>(null);
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const mark = () => {
      const first = el.firstElementChild as HTMLElement | null;
      const top = first?.offsetTop ?? 0;
      const over = [...el.children].some((c) => (c as HTMLElement).offsetTop > top + 2);
      el.parentElement?.classList.toggle("status-over", over);
    };
    mark();
    const ro = new ResizeObserver(mark);
    ro.observe(el);
    return () => ro.disconnect();
  }, deps);
  return ref;
}

const svg = (body: JSX.Element | JSX.Element[], box = "0 0 24 24") => <svg viewBox={box} aria-hidden="true">{body}</svg>;

/** Signal bars 0-4: lit ones full ink, the rest faint; out of service / emergency only: a cross over faint bars. */
function Bars({ bars, cross }: { bars: number; cross: boolean }) {
  const lit = cross ? 0 : bars;
  return svg(<>
    {[0, 1, 2, 3].map((i) => <rect key={i} class={i < lit ? "lit" : "dim"} x={3 + i * 5} y={18 - (i + 1) * 4} width="3.4" height={(i + 1) * 4 + 2} rx="1" />)}
    {cross && <path class="mark" d="M15 3l6 6M21 3l-6 6" />}
  </>);
}

const SIM_WORDS: Partial<Record<StatusCell["sim"], string>> = { locked: "locked", error: "error" };
const SERVICE_WORDS: Partial<Record<StatusCell["service"], string>> = { emergency: "emergency calls only", none: "no service", off: "radio off" };

function cellLabel(c: StatusCell, dual: boolean) {
  const sim = dual ? `SIM ${c.slot + 1}` : "SIM";
  if (c.sim === "absent") return "No SIM";
  if (SIM_WORDS[c.sim]) return `${sim} ${SIM_WORDS[c.sim]}`;
  const service = SERVICE_WORDS[c.service] ?? `${c.bars ?? 0} of 4 bars`;
  return [c.carrier ?? sim, service, c.type, c.roaming ? "roaming" : null].filter(Boolean).join(", ");
}

/** A SIM with a slash (none) or a "!" (locked, error). */
function SimMark({ state }: { state: StatusCell["sim"] }) {
  return svg(<>
    <path d="M8 3h6l4 4v14H8z" />
    {state === "absent" ? <path class="mark" d="M5 5l14 14" /> : <path class="mark" d="M13 10v5M13 18v.01" />}
  </>);
}

/** One SIM: its network type (with data arrows), roaming "R" and bars - or the SIM card mark when it has none. */
function CellIcon({ cell, dual }: { cell: StatusCell; dual: boolean }) {
  if (cell.sim === "unknown") return null;
  const label = cellLabel(cell, dual);
  if (cell.sim !== "ready") return <span class="status-icon" role="img" aria-label={label} title={label}><SimMark state={cell.sim} /></span>;
  const cross = cell.service !== "in";
  return <span class={`status-icon status-cell${dual ? " dual" : ""}`} role="img" aria-label={label} title={label}>
    {cell.type && <span class="status-type">
      <span>{cell.type}</span>
      <span class="status-arrows" data-activity={cell.activity ?? "none"}><i class="up" /><i class="down" /></span>
    </span>}
    {cell.roaming && <span class="status-roam">R</span>}
    {dual && <span class="status-slot">{cell.slot + 1}</span>}
    <Bars bars={cell.bars ?? 0} cross={cross} />
  </span>;
}

/** Wi-Fi: lit arcs to its strength; a "!" without internet. */
function WifiIcon({ bars, internet }: { bars: number; internet: boolean }) {
  const arcs = ["M12 19.5h.01", "M9 16a4.2 4.2 0 0 1 6 0", "M6 12.5a8.5 8.5 0 0 1 12 0", "M3 9a13 13 0 0 1 18 0"];
  const label = `Wi-Fi, ${bars} of 4 bars${internet ? "" : ", no internet"}`;
  return <span class="status-icon" role="img" aria-label={label} title={label}>{svg(<>
    {arcs.map((d, i) => <path key={i} class={i < Math.max(1, bars) ? "lit" : "dim"} d={d} />)}
    {!internet && <path class="mark" d="M21 14v4M21 21v.01" />}
  </>)}</span>;
}

/** The glyphs of the plain on/off icons, one stroke each in the shell's line style. */
const GLYPHS: Record<string, string> = {
  airplane: "M12 2.5c.8 0 1.4.9 1.4 2v5l7.1 4.2v2l-7.1-2.2v4.6l2.2 1.7v1.7L12 20.6l-3.6 0.9v-1.7l2.2-1.7v-4.6l-7.1 2.2v-2l7.1-4.2v-5c0-1.1.6-2 1.4-2z",
  hotspot: "M12 13v.01M9.2 15.8a4 4 0 0 1 0-5.6M14.8 10.2a4 4 0 0 1 0 5.6M6.3 18.7a8 8 0 0 1 0-11.4M17.7 7.3a8 8 0 0 1 0 11.4",
  vpn: "M7 10V7a5 5 0 0 1 10 0v3M5 10h14v11H5z",
  bluetooth: "M7 7l10 10-5 5V2l5 5L7 17",
  nfc: "M5 4h14v16H5zM9 16V8l6 8V8",
  location: "M12 21s-6-5.6-6-11a6 6 0 0 1 12 0c0 5.4-6 11-6 11zM12 12.5a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5z",
  dnd: "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM7.5 12h9",
  vibrate: "M8 4h8v16H8zM4 8v8M20 8v8M2 10v4M22 10v4",
  silent: "M18 15V11a6 6 0 0 0-9.3-5M6.3 8.3A6 6 0 0 0 6 11v4l-2 2h13M10 20a2 2 0 0 0 4 0M3 3l18 18",
  alarm: "M12 21a8 8 0 1 0 0-16 8 8 0 0 0 0 16zM12 9v4l2.5 2M4 5l3-2.5M20 5l-3-2.5",
  dataSaver: "M12 3a9 9 0 1 0 9 9M16 3.9A9 9 0 0 1 20.1 8M12 8.5v7M8.5 12h7",
  cast: "M3 6V5h18v14h-7M3 10a9 9 0 0 1 9 9M3 14a5 5 0 0 1 5 5M3 18.5v.5",
};

function Glyph({ kind, label, extra }: { kind: string; label: string; extra?: JSX.Element }) {
  return <span class={`status-icon status-${kind}`} role="img" aria-label={label} title={label}>{svg(<path d={GLYPHS[kind]} />)}{extra}</span>;
}

function alarmLabel(at: number) {
  return `Alarm ${new Date(at).toLocaleTimeString([], { weekday: "short", hour: "2-digit", minute: "2-digit" })}`;
}

type Item = [key: string, node: JSX.Element];

/** The connectivity icons, highest priority first (rightmost; the last to be hidden): airplane, SIMs, Wi-Fi, VPN. */
function connectivity(s: SystemStatus, vpn: boolean): Item[] {
  const dual = s.cells.filter((c) => c.sim === "ready").length > 1;
  // Airplane mode: stock shows the plane and no SIM icons (Wi-Fi may be on again over it).
  const cells: Item[] = s.airplane ? [] : [...s.cells].reverse().map((c) => [`cell${c.slot}`, <CellIcon cell={c} dual={dual} />]);
  return [
    ...(s.airplane ? [["airplane", <Glyph kind="airplane" label="Airplane mode" />] as Item] : []),
    ...cells,
    ...(s.wifi != null ? [["wifi", <WifiIcon bars={s.wifi} internet={s.wifiInternet} />] as Item] : []),
    ...(vpn ? [["vpn", <Glyph kind="vpn" label="VPN connected" />] as Item] : []),
  ];
}

/** The rest, in the order stock drops them last-to-first. */
function toggles(s: SystemStatus): Item[] {
  const bt = s.bluetooth !== "off" && <Glyph kind="bluetooth" label={s.bluetooth === "connected" ? `Bluetooth connected${s.bluetoothBattery != null ? `, headset battery ${s.bluetoothBattery}%` : ""}` : "Bluetooth on"}
    extra={s.bluetoothBattery != null ? <i class="status-btbat" style={{ "--level": `${s.bluetoothBattery}%` }} /> : undefined} />;
  const all: [unknown, string, () => JSX.Element][] = [
    [bt, "bluetooth", () => bt as JSX.Element],
    [s.dnd, "dnd", () => <Glyph kind="dnd" label="Do not disturb" />],
    [s.ringer !== "normal", "ringer", () => <Glyph kind={s.ringer} label={s.ringer === "vibrate" ? "Vibrate" : "Silent"} />],
    [s.alarm != null, "alarm", () => <Glyph kind="alarm" label={alarmLabel(s.alarm!)} />],
    [s.hotspot, "hotspot", () => <Glyph kind="hotspot" label="Hotspot on" />],
    [s.cast, "cast", () => <Glyph kind="cast" label="Casting screen" />],
    [s.dataSaver, "dataSaver", () => <Glyph kind="dataSaver" label="Data saver on" />],
    [s.location, "location", () => <Glyph kind="location" label="Location in use" />],
    [s.nfc, "nfc", () => <Glyph kind="nfc" label="NFC on" />],
  ];
  return all.filter(([on]) => on).map(([, key, draw]) => [key, draw()]);
}

/**
 * The system icons between the recording dot and the battery: [first] (the battery, drawn by the bar) stays rightmost,
 * then connectivity, then the toggles; the toggles go first when space runs out.
 */
export function SystemIcons({ status, vpn, first }: { status: SystemStatus; vpn: boolean; first: JSX.Element | null }) {
  const items = [...connectivity(status, vpn), ...toggles(status)];
  const ref = useOverflow<HTMLSpanElement>([status, vpn, first]);
  return <span class="status-sys">
    <i class="status-more" aria-hidden="true" />
    <span class="status-row" ref={ref}>
      {first}
      {items.map(([key, node]) => <span key={key} class="status-slotted">{node}</span>)}
    </span>
  </span>;
}

/** The notifications' icons after the clock, newest first, an overflow dot when they don't all fit. */
export function NotificationIcons({ status }: { status: SystemStatus | null }) {
  const list = status?.notifications ?? [];
  const ref = useOverflow<HTMLSpanElement>([list]);
  if (!list.length) return null;
  return <span class="status-notifs">
    <span class="status-row" ref={ref}>
      {list.slice(0, 8).map((n) => <i key={n.key} class="status-nicon" style={{ "--icon": `url("${n.url}")` }} />)}
    </span>
    <i class="status-more" aria-hidden="true" />
  </span>;
}

/** The spoken summary of what the icons show (the control button's label). */
export function statusWords(s: SystemStatus | null): string[] {
  if (!s) return [];
  const words: string[] = [];
  if (s.airplane) words.push("airplane mode");
  const dual = s.cells.filter((c) => c.sim === "ready").length > 1;
  if (!s.airplane) words.push(...s.cells.filter((c) => c.sim !== "unknown").map((c) => cellLabel(c, dual)));
  if (s.wifi != null) words.push(`Wi-Fi ${s.wifi} of 4 bars`);
  if (s.bluetooth === "connected") words.push("Bluetooth connected");
  if (s.dnd) words.push("do not disturb");
  if (s.ringer !== "normal") words.push(s.ringer);
  if (s.alarm != null) words.push(alarmLabel(s.alarm).toLowerCase());
  if (s.notifications.length) words.push(`${s.notifications.length} notification apps`);
  return words;
}
