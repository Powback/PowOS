/**
 * The control center: PowOS's in place of OnePlus's (a pull on the status bar's right half, or "controls" on the
 * notification panel). Everything the phone's own one has, in its order (QuickState.tiles is SystemUI's tile list): Wi-Fi
 * and mobile data as the two big cards, the brightness and volume sliders, then the tiles. A tap switches a tile (or
 * runs it: screenshot, lock), a long press opens its page in Settings. It lives in the notification panel's place, so the
 * pull, the finger following it and the swipe up to shut it are the panel's own (gesture.ts).
 */
import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";
import type { ComponentChildren } from "preact";
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import { notif, panel } from "../state.ts";
import { notifOpen } from "./gesture.ts";
import { Icon, type IconName } from "./icons.tsx";
import { openRemote } from "../remote.ts";
import { openGlasses } from "../glasses/open.ts";
import { useMinuteClock } from "./time.ts";
import type { GlassesState, MediaState, QuickState, QuickTile, RemoteState, RemoteTarget } from "../types.ts";

/** The phone's quick settings, kept up to date ("qs.changed"): the control center's and the notification panel's row. */
export const quick = signal<QuickState>({
  torch: null,
  dnd: null,
  tiles: [],
  brightness: { value: 0.5, auto: false },
  volume: { value: 0.5, ringer: 2 },
});
powos.on("qs.changed", (q: QuickState) => (quick.value = { ...q }));
// A host without quick settings (the desktop's powos-shell, for now) rejects: no state, not an uncaught error.
powos.qs.state().then((q) => (quick.value = q), () => {});

/** PowOS's own tile, not one of the phone's: Remote input (ui/remote.tsx). */
const REMOTE_ID = "powos.remote";
/** PowOS's own tile too: the smart glasses (ui/glasses.tsx). */
const GLASSES_ID = "powos.glasses";

/** Held this long (ms), a tile opens its page instead. */
const HOLD = 450;

/** Tiles that leave the panel (a page, an app, a screenshot of what's under it): it shuts first. */
const LEAVES = new Set([
  "screenshot",
  "screenrecord",
  "calculator",
  "qr_code_scanner",
  "controls",
  "wallet",
  "hotspot",
  "lockscreen",
]);

/** Tiles that are only an action: nothing to open on a hold. */
const NO_PAGE = new Set(["lockscreen", "screenshot"]);

const RINGER = ["silent", "vibrate", "ring"];

/** Each tile's icon, off and on (one name: the same both ways). */
const TILE_ICONS: Record<string, IconName | [IconName, IconName]> = {
  wifi: ["wifiOff", "wifi"],
  bt: ["bluetoothOff", "bluetooth"],
  cell: "swapVertical",
  flashlight: ["flashlightOff", "flashlight"],
  location: ["mapMarkerOff", "mapMarker"],
  airplane: "airplane",
  controls: "homeAutomation",
  wallet: "walletOutline",
  rotation: ["screenRotationLock", "screenRotation"],
  dnd: "minusCircleOutline",
  darkmode: "themeLightDark",
  screenshot: "cellphoneScreenshot",
  screenrecord: "recordRec",
  hotspot: "accessPoint",
  calculator: "calculatorVariantOutline",
  nfc: "nfcVariant",
  battery: "leaf",
  lockscreen: "lockOutline",
  qr_code_scanner: "qrcodeScan",
  [REMOTE_ID]: "keyboardOutline",
  [GLASSES_ID]: "glasses",
};

/** Other apps' tiles by their app: the icon that says what they do. */
const APP_ICONS: Record<string, IconName> = {
  "com.oplus.eyeprotect": "eyeOutline",
  "com.oneplus.oshare": "shareVariantOutline",
  "com.google.android.gms": "shareVariant",
  "com.oplus.linker": "cast",
  "com.microsoft.appmanager": "microsoftWindows",
};

function tileIcon(t: QuickTile): IconName {
  const i = TILE_ICONS[t.id];
  if (Array.isArray(i)) return t.on === false ? i[0] : i[1];
  return i ?? (t.app && APP_ICONS[t.app]) ?? "apps";
}

export const update = (s: QuickState) => (quick.value = { ...s });

/** What "shut" means on this page: the panel goes (the shade, home); Quick Tools (ui/quicktools.tsx) sets its own. */
let shutHook = () => {
  notif.value = false;
};
export function onShut(f: () => void) {
  shutHook = f;
}
function shut() {
  shutHook();
}

/** A tile's tap and long press. */
function usePress(t: QuickTile) {
  const timer = useRef(0);
  const held = useRef(false);
  const open = () => {
    held.current = true;
    // An action with no page of its own (Lock, Screenshot): a hold is nothing - the host has no page to open
    // ("no quick setting lockscreen", 2026-10-21 home rejection).
    if (NO_PAGE.has(t.id)) return;
    shut();
    powos.qs.open(t.id).catch((e) => console.warn("qs: no page for", t.id, e));
  };
  return {
    onPointerDown: () => {
      held.current = false;
      timer.current = window.setTimeout(open, HOLD);
    },
    onPointerUp: () => clearTimeout(timer.current),
    onPointerCancel: () => clearTimeout(timer.current),
    onPointerLeave: () => clearTimeout(timer.current),
    onContextMenu: (e: Event) => e.preventDefault(),
    onClick: () => {
      if (held.current) return;
      // Another app's tile not hosted yet (no state from it): its own settings, or its app. Hosted, it switches here.
      if (t.app && t.on == null) return (shut(), powos.qs.open(t.id));
      if (LEAVES.has(t.id) || t.on == null) shut();
      powos.qs.toggle(t.id).then(update);
    },
  };
}

/**
 * Remote input's side and its computer, asked for while the control center shows ("remote.state" brings changes; the
 * cable has no event, so it's asked again now and then).
 */
const remote = signal<RemoteState | null>(null);
powos.on("remote.state", (s: RemoteState) => (remote.value = s));
const askRemote = () =>
  powos.remote.state().then(
    (s) => (remote.value = s),
    () => {},
  );
/** The glasses' state ("glasses.state"), for their tile; a host without glasses (the desktop) has none. */
const glasses = signal<GlassesState | null>(null);
powos.on("glasses.state", (s: GlassesState) => (glasses.value = s));
powos.glasses.state().then(
  (s) => (glasses.value = s),
  () => {},
);

/** The glasses as a tile: on while connected; a tap opens their screen (pairing, connecting, what they show). */
function glassesTile(): QuickTile {
  const s = glasses.value;
  const model = s?.paired?.model;
  return {
    id: GLASSES_ID,
    label: model ? `${model} glasses` : "glasses",
    on: s?.phase === "ready",
    detail: !s?.paired ? "not paired" : s.phase === "ready" ? "connected" : s.phase === "connecting" ? "connecting" : "not connected",
  };
}

function GlassesTile({ t }: { t: QuickTile }) {
  return (
    <button
      type="button"
      class={`cc-tile ${t.on ? "on" : ""}`}
      aria-label={`glasses: ${t.detail}`}
      onClick={() => {
        shut();
        openGlasses();
      }}
    >
      <span class="cc-icon">
        <Icon name="glasses" />
      </span>
      <span class="cc-label">{t.label}</span>
    </button>
  );
}

/** The long press's picker (USB or Bluetooth) showing. */
const picking = signal(false);

/** Whom remote input's picked side is with: a Bluetooth computer's name, "computer" for a USB one, null for none. */
function remoteHost(s: RemoteState | null): string | null {
  if (s?.target === "usb") return s.usb.state === "configured" ? "computer (USB)" : null;
  if (s?.target === "bluetooth") return s.bluetooth.host?.name ?? null;
  return null;
}

/** Remote input as a tile: on with a computer connected (its name the label); a tap opens it, a long press picks the side. */
function remoteTile(): QuickTile {
  const s = remote.value;
  const host = remoteHost(s);
  return {
    id: REMOTE_ID,
    label: host ?? "remote input",
    on: !!host,
    detail: host ? `connected to ${host}` : s?.target ? `${s.target === "usb" ? "USB" : "Bluetooth"}, not connected` : "off",
  };
}

function RemoteTile({ t }: { t: QuickTile }) {
  const timer = useRef(0);
  const held = useRef(false);
  const side = remote.value?.target;
  const clear = () => clearTimeout(timer.current);
  return (
    <button
      type="button"
      class={`cc-tile ${t.on ? "on" : ""} ${picking.value ? "picking" : ""}`}
      aria-label={`remote input: ${t.detail}`}
      onPointerDown={() => {
        held.current = false;
        timer.current = window.setTimeout(() => {
          held.current = true;
          picking.value = !picking.value;
        }, HOLD);
      }}
      onPointerUp={clear}
      onPointerCancel={clear}
      onPointerLeave={clear}
      onContextMenu={(e: Event) => e.preventDefault()}
      onClick={() => {
        if (held.current) return;
        picking.value = false;
        shut();
        openRemote();
      }}
    >
      <span class="cc-icon">
        <Icon name={side === "usb" ? "usb" : side === "bluetooth" ? "bluetooth" : "keyboardOutline"} />
      </span>
      <span class="cc-label">{t.label}</span>
    </button>
  );
}

/** The long press's picker: where remote input's keys and touchpad go (that side turned on), or nowhere. */
function RemotePick() {
  if (!picking.value) return null;
  const s = remote.value;
  const pick = (side: RemoteTarget | null) => {
    picking.value = false;
    powos.remote.target(side).then(
      (st) => (remote.value = st),
      () => {},
    );
  };
  const chip = (side: RemoteTarget, label: string, icon: IconName) => (
    <button type="button" class={`cc-chip ${s?.target === side ? "on" : ""}`} onClick={() => pick(side)}>
      <Icon name={icon} />
      <span>{label}</span>
    </button>
  );
  return (
    <div class="cc-pick">
      <span class="cc-pick-head muted">remote input: {remoteTile().detail}</span>
      <span class="cc-pick-row">
        {chip("usb", "USB", "usb")}
        {chip("bluetooth", "Bluetooth", "bluetooth")}
        <button type="button" class={`cc-chip ${s?.target ? "" : "on"}`} onClick={() => pick(null)}>
          <span>none</span>
        </button>
      </span>
    </div>
  );
}

export function Tile({ t, big = false }: { t: QuickTile; big?: boolean }) {
  return (
    <button type="button" class={`cc-tile ${big ? "big" : ""} ${t.on ? "on" : ""}`} {...usePress(t)}>
      <span class="cc-icon">
        <Icon name={tileIcon(t)} />
      </span>
      {big ? (
        <span class="cc-text">
          <span class="cc-label">{t.label}</span>
          <span class="cc-detail">{t.detail ?? (t.on == null ? "" : t.on ? "on" : "off")}</span>
        </span>
      ) : (
        <span class="cc-label">{t.label}</span>
      )}
    </button>
  );
}

/**
 * The user's arrangement of the tiles (edit mode): their order and the ones taken out, kept in the store. Tiles it
 * doesn't name yet (a new app's tile) come after, in the phone's own order.
 */
type Layout = { order: string[]; hidden: string[] };
const layout = signal<Layout>({ order: [], hidden: [] });
powos.store.get<Layout>("controls.layout").then((l) => l && (layout.value = l));
const editing = signal(false);

function arranged(tiles: QuickTile[]) {
  const { order, hidden } = layout.value;
  const byId = new Map(tiles.map((t) => [t.id, t]));
  const shown = [...order.filter((id) => byId.has(id)), ...tiles.map((t) => t.id).filter((id) => !order.includes(id))]
    .filter((id) => !hidden.includes(id))
    .map((id) => byId.get(id)!);
  return { shown, hidden: hidden.filter((id) => byId.has(id)).map((id) => byId.get(id)!) };
}

function saveLayout(l: Layout) {
  layout.value = l;
  powos.store.set("controls.layout", l);
}

/** Dragged this far (px) a tile is picked up; less is a tap. */
const DRAG_SLOP = 6;

/**
 * Edit mode: the tiles are dragged into place (the others make room as the finger passes over them), a − takes one
 * out, a + in the tray below puts it back at the end. Every change is kept at once; "done" (the header's check) ends it.
 * Its touches are its own (gesture.ts leaves .cc-editing alone), so a drag never pulls the panel shut.
 */
function EditGrid({ shown, hidden }: { shown: QuickTile[]; hidden: QuickTile[] }) {
  const grid = useRef<HTMLDivElement>(null);
  // The order while a tile is being dragged (null: none is): shown live, kept when it's let go.
  const [order, setOrder] = useState<string[] | null>(null);
  const drag = useRef<{
    id: string;
    x0: number;
    y0: number;
    gx: number;
    gy: number;
    started: boolean;
    x: number;
    y: number;
  } | null>(null);
  const byId = new Map(shown.map((t) => [t.id, t]));
  const ids = order ?? shown.map((t) => t.id);

  /** The dragged tile under the finger: its offset from its slot (which moves as the order does). */
  const place = () => {
    const d = drag.current;
    const el = grid.current?.querySelector<HTMLElement>(`[data-id="${CSS.escape(d?.id ?? "")}"]`);
    if (!d || !el) return;
    el.style.transform = "none";
    const r = el.getBoundingClientRect();
    el.style.transform = `translate(${d.x - d.gx - r.left}px, ${d.y - d.gy - r.top}px) scale(1.08)`;
  };
  useLayoutEffect(place, [order]);

  const down = (e: PointerEvent, id: string) => {
    const el = e.currentTarget as HTMLElement;
    // The finger's moves come here even off the tile (a pointer the page doesn't track can't be captured).
    try {
      el.setPointerCapture(e.pointerId);
    } catch {}
    const r = el.getBoundingClientRect();
    drag.current = {
      id,
      x0: e.clientX,
      y0: e.clientY,
      gx: e.clientX - r.left,
      gy: e.clientY - r.top,
      started: false,
      x: e.clientX,
      y: e.clientY,
    };
  };
  const move = (e: PointerEvent) => {
    const d = drag.current;
    if (!d) return;
    d.x = e.clientX;
    d.y = e.clientY;
    if (!d.started) {
      if (Math.hypot(d.x - d.x0, d.y - d.y0) < DRAG_SLOP) return;
      d.started = true;
      setOrder(ids);
      return;
    }
    // The slot whose middle is nearest the finger is where it goes.
    let best = -1;
    let dist = Infinity;
    grid.current?.querySelectorAll<HTMLElement>("[data-id]").forEach((el, i) => {
      if (el.dataset.id === d.id) return;
      const r = el.getBoundingClientRect();
      const dd = Math.hypot(r.left + r.width / 2 - d.x, r.top + r.height / 2 - d.y);
      if (dd < dist) ((dist = dd), (best = i));
    });
    const from = ids.indexOf(d.id);
    if (best >= 0 && best !== from && dist < 48) {
      const next = ids.filter((x) => x !== d.id);
      next.splice(best, 0, d.id);
      setOrder(next);
    } else place();
  };
  const up = () => {
    const d = drag.current;
    drag.current = null;
    const el = d && grid.current?.querySelector<HTMLElement>(`[data-id="${CSS.escape(d.id)}"]`);
    if (el) el.style.transform = "";
    if (d?.started) saveLayout({ order: ids, hidden: layout.value.hidden });
    setOrder(null);
  };
  const remove = (id: string) =>
    saveLayout({ order: ids.filter((x) => x !== id), hidden: [...layout.value.hidden.filter((h) => h !== id), id] });
  const add = (id: string) => saveLayout({ order: [...ids, id], hidden: layout.value.hidden.filter((h) => h !== id) });

  return (
    <div class="cc-editing">
      <div class="cc-grid" ref={grid}>
        {ids.map((id) => {
          const t = byId.get(id)!;
          return (
            <div
              key={id}
              data-id={id}
              class={`cc-tile edit ${drag.current?.started && drag.current.id === id ? "dragging" : ""}`}
              onPointerDown={(e) => down(e, id)}
              onPointerMove={move}
              onPointerUp={up}
              onPointerCancel={up}
            >
              <span class="cc-icon">
                <Icon name={tileIcon(t)} />
              </span>
              <span class="cc-label">{t.label}</span>
              <button
                type="button"
                class="cc-badge"
                aria-label={`remove ${t.label}`}
                onPointerDown={(e) => e.stopPropagation()}
                onClick={() => remove(id)}
              >
                <Icon name="minusCircleOutline" />
              </button>
            </div>
          );
        })}
      </div>
      <span class="cc-tray-head muted">{hidden.length ? "more tiles" : "every tile is in"}</span>
      {hidden.length > 0 && (
        <div class="cc-grid cc-tray">
          {hidden.map((t) => (
            <button
              key={t.id}
              type="button"
              class="cc-tile edit"
              aria-label={`add ${t.label}`}
              onClick={() => add(t.id)}
            >
              <span class="cc-icon">
                <Icon name={tileIcon(t)} />
              </span>
              <span class="cc-label">{t.label}</span>
              <span class="cc-badge add">
                <Icon name="plus" />
              </span>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

/**
 * A slider sending its value at most once a frame while it moves. Its icon can be a button of its own ([onIcon]: the
 * volume's cycles silent / vibrate / ring), and something can sit at its end ([end]: the brightness's auto "A").
 */
export function Slider({
  name,
  value,
  label,
  icon,
  onIcon,
  end,
}: {
  name: "brightness" | "volume";
  value: number;
  label: string;
  icon: IconName;
  onIcon?: () => void;
  end?: ComponentChildren;
}) {
  const [local, setLocal] = useState<number | null>(null);
  const frame = useRef(0);
  const next = useRef(0);
  useEffect(() => () => cancelAnimationFrame(frame.current), []);
  const send = (v: number) => {
    next.current = v;
    if (frame.current) return;
    frame.current = requestAnimationFrame(() => {
      frame.current = 0;
      powos.qs.set(name, next.current).then(update);
    });
  };
  const shown = local ?? value;
  return (
    <div class="cc-slider" style={{ "--v": String(shown) }}>
      <input
        type="range"
        aria-label={label}
        min={0}
        max={1000}
        value={Math.round(shown * 1000)}
        onInput={(e) => {
          const v = Number((e.currentTarget as HTMLInputElement).value) / 1000;
          setLocal(v);
          send(v);
        }}
        onChange={() => setLocal(null)}
      />
      {onIcon ? (
        <button type="button" class="cc-slider-icon tap" aria-label={label} onClick={onIcon}>
          <Icon name={icon} />
        </button>
      ) : (
        <span class="cc-slider-icon">
          <Icon name={icon} />
        </span>
      )}
      {end}
    </div>
  );
}

function Clock() {
  const now = useMinuteClock();
  const two = (n: number) => String(n).padStart(2, "0");
  return (
    <span class="cc-clock">
      {two(now.getHours())}:{two(now.getMinutes())}
      <span class="muted">
        {" "}
        {now.toLocaleDateString(undefined, {
          weekday: "short",
          day: "numeric",
          month: "short",
        })}
      </span>
    </span>
  );
}

/** What's playing: asked for once a control center is shown, then kept up to date ("media.changed"). */
const media = signal<MediaState | null>(null);
let mediaAsked = false;
function askMedia() {
  if (mediaAsked) return;
  mediaAsked = true;
  powos.on("media.changed", (m: MediaState) => (media.value = m));
  powos.media.state().then((m) => (media.value = m));
}

/** The media card, as OnePlus's: the track, its art, play/pause and skip, the output picker. Nothing playing: none. */
function MediaCard() {
  useEffect(askMedia, []);
  const m = media.value;
  if (!m?.available || !m.title) return null;
  const progress = m.duration ? Math.min(1, (m.position ?? 0) / m.duration) : 0;
  return (
    <div class="cc-media" style={{ "--p": String(progress) }}>
      {m.art && <img class="cc-art" src={`/_media/${encodeURIComponent(m.art)}`} alt="" />}
      <button type="button" class="cc-track" onClick={() => (shut(), powos.media.control("open"))}>
        <span class="cc-label">{m.title}</span>
        <span class="cc-detail">{[m.artist, m.app].filter(Boolean).join(" · ")}</span>
      </button>
      <span class="cc-transport">
        <button type="button" aria-label="previous" onClick={() => powos.media.control("previous")}>
          <Icon name="skipPrevious" />
        </button>
        <button type="button" aria-label={m.playing ? "pause" : "play"} onClick={() => powos.media.control("toggle")}>
          <Icon name={m.playing ? "pause" : "play"} />
        </button>
        <button type="button" aria-label="next" onClick={() => powos.media.control("next")}>
          <Icon name="skipNext" />
        </button>
        <button type="button" aria-label="output" onClick={() => (shut(), powos.media.output(m.package))}>
          <Icon name="speakerWireless" />
        </button>
      </span>
    </div>
  );
}

// A tile opened its activity or dialog (TileHost): the panel goes, as SystemUI's does.
powos.on("qs.collapse", () => shut());

/**
 * The control center's eight tiles (the main view): each one shape - a rounded tile, the accent when on - for one thing
 * or a few that belong together. A tap does the first member's (switches it, or runs it); the chevron or a long press
 * opens the group's sheet with all of its members. A member the phone doesn't have is left out; a group with none, too.
 * Everything else is on the all-tiles page, never gone.
 */
interface Group {
  id: string;
  label: string;
  icon: IconName;
  /** Tile ids, or "app:<package>" for another app's tile. The first one present is the tap's. */
  members: string[];
}
const GROUPS: Group[] = [
  { id: "internet", label: "internet", icon: "wifi", members: ["wifi", "cell", "airplane", "hotspot"] },
  {
    id: "connect",
    label: "connect",
    icon: "bluetooth",
    members: ["bt", "nfc", "app:com.oneplus.oshare", "app:com.oplus.linker", "app:com.microsoft.appmanager"],
  },
  { id: "torch", label: "torch", icon: "flashlight", members: ["flashlight"] },
  { id: "focus", label: "focus", icon: "minusCircleOutline", members: ["dnd"] },
  { id: "display", label: "display", icon: "themeLightDark", members: ["darkmode", "app:com.oplus.eyeprotect", "rotation"] },
  { id: "battery", label: "battery", icon: "leaf", members: ["battery"] },
  { id: "location", label: "location", icon: "mapMarker", members: ["location"] },
  { id: "capture", label: "capture", icon: "cellphoneScreenshot", members: ["screenshot", "screenrecord"] },
];

const member = (tiles: QuickTile[], m: string) => (m.startsWith("app:") ? tiles.find((t) => t.app === m.slice(4)) : tiles.find((t) => t.id === m));

/** What a group's tile says under its name: Internet "Home-WiFi · 5G" / "airplane", the first member's otherwise. */
function groupState(g: Group, ts: QuickTile[]): { on: boolean; detail: string } {
  const by = (id: string) => ts.find((t) => t.id === id);
  if (g.id === "internet") {
    if (by("airplane")?.on) return { on: true, detail: "airplane" };
    const wifi = by("wifi");
    const cell = by("cell");
    const parts = [wifi?.on ? wifi.detail || "wi-fi" : null, cell?.on ? cell.detail || "data" : null].filter(Boolean);
    return { on: !!wifi?.on, detail: parts.length ? parts.join(" · ") : "off" };
  }
  const first = ts[0];
  const onCount = ts.filter((t) => t.on).length;
  if (g.id === "capture") return { on: false, detail: "" };
  if (g.id === "battery") return { on: !!first.on, detail: first.on ? "saver on" : "saver off" };
  if (ts.length > 1) return { on: !!first.on, detail: onCount ? ts.filter((t) => t.on).map((t) => t.label.toLowerCase()).join(" · ") : "off" };
  return { on: !!first.on, detail: first.on == null ? "" : first.on ? "on" : "off" };
}

/** The group whose sheet is open (its members as tiles, under the eight), and the all-tiles page. */
const sheet = signal<string | null>(null);
const allTiles = signal(false);

function GroupTile({ g, ts }: { g: Group; ts: QuickTile[] }) {
  const first = ts[0];
  const press = usePress(first);
  const timer = useRef(0);
  const held = useRef(false);
  const st = groupState(g, ts);
  const several = ts.length > 1;
  const open = sheet.value === g.id;
  return (
    <button
      type="button"
      class={`cc-tile ${st.on ? "on" : ""} ${open ? "sheet-open" : ""}`}
      aria-label={`${g.label}: ${st.detail}`}
      onPointerDown={() => {
        held.current = false;
        timer.current = window.setTimeout(() => {
          held.current = true;
          if (several) sheet.value = open ? null : g.id;
          else press.onPointerDown();
        }, HOLD);
      }}
      onPointerUp={() => clearTimeout(timer.current)}
      onPointerCancel={() => clearTimeout(timer.current)}
      onPointerLeave={() => clearTimeout(timer.current)}
      onContextMenu={(e: Event) => e.preventDefault()}
      onClick={() => {
        if (held.current) return;
        press.onClick();
      }}
    >
      <span class="cc-icon">
        <Icon name={g.id === "internet" && !st.on ? "wifiOff" : g.id === "torch" && !st.on ? "flashlightOff" : g.icon} />
        {several && (
          <span
            class="cc-more"
            role="button"
            aria-label={`${g.label}: all`}
            onPointerDown={(e) => e.stopPropagation()}
            onClick={(e) => {
              e.stopPropagation();
              sheet.value = open ? null : g.id;
            }}
          >
            <Icon name="chevronRight" />
          </span>
        )}
      </span>
      <span class="cc-label">{g.label}</span>
      {st.detail && <span class="cc-detail">{st.detail}</span>}
    </button>
  );
}

/** A group's sheet: its members, each its own tile (a tap switches it, a long press its page). */
function Sheet({ ts }: { ts: QuickTile[] }) {
  return (
    <div class="cc-sheet cc-grid">
      {ts.map((t) => (
        <Tile key={t.id} t={t} />
      ))}
    </div>
  );
}

export function ControlCenter() {
  // Shown: other apps' tiles listen (their state kept current), until it's shut or turned back to notifications.
  const open = notifOpen.value;
  useEffect(() => {
    if (!open) return;
    powos.qs.listening(true);
    askRemote();
    // The cable's state has no event: asked while the panel shows - not while its window is put away.
    const timer = window.setInterval(() => document.hidden || askRemote(), 3000);
    return () => {
      powos.qs.listening(false);
      clearInterval(timer);
      picking.value = false;
      sheet.value = null;
      allTiles.value = false;
      editing.value = false;
    };
  }, [open]);
  const q = quick.value;
  const tiles = q.tiles ?? [];
  // Remote input's and the glasses' tiles join the phone's: a layout kept before they were there gets them at the end.
  const every = [...tiles, remoteTile(), ...(glasses.value ? [glassesTile()] : [])];
  const { shown, hidden } = arranged(every);
  const b = q.brightness ?? { value: 0.5, auto: false };
  const v = q.volume ?? { value: 0.5, ringer: 2 };
  const groups = GROUPS.map((g) => ({ g, ts: g.members.map((m) => member(tiles, m)).filter((t): t is QuickTile => !!t) })).filter(
    (x) => x.ts.length > 0,
  );
  // The user's arrangement orders the eight too, by where their first members are in it.
  const pos = (id: string) => {
    const i = shown.findIndex((t) => t.id === id);
    return i < 0 ? 999 : i;
  };
  if (layout.value.order.length) groups.sort((a, b2) => pos(a.ts[0].id) - pos(b2.ts[0].id));
  const open$ = groups.find((x) => x.g.id === sheet.value);
  if (allTiles.value) {
    return (
      <div class="cc">
        <div class="notif-bar">
          <button type="button" class="cc-back" onClick={() => ((allTiles.value = false), (editing.value = false))}>
            <Icon name="chevronLeft" />
            <span>all tiles</span>
          </button>
          <span class="notif-actions icons">
            <button
              type="button"
              aria-label={editing.value ? "done" : "edit"}
              class={editing.value ? "on" : ""}
              onClick={() => (editing.value = !editing.value)}
            >
              <Icon name={editing.value ? "check" : "pencilOutline"} />
            </button>
          </span>
        </div>
        {editing.value ? (
          <EditGrid shown={shown} hidden={hidden} />
        ) : (
          <div class="cc-grid">
            {shown.map((t) =>
              t.id === REMOTE_ID ? <RemoteTile key={t.id} t={t} /> : t.id === GLASSES_ID ? <GlassesTile key={t.id} t={t} /> : <Tile key={t.id} t={t} />,
            )}
          </div>
        )}
        {!editing.value && <RemotePick />}
      </div>
    );
  }
  return (
    <div class="cc">
      <div class="notif-bar">
        <Clock />
        <span class="notif-actions icons">
          <button type="button" aria-label="settings" onClick={() => (shut(), powos.qs.open("settings"))}>
            <Icon name="cogOutline" />
          </button>
        </span>
      </div>
      <div class="cc-sliders">
        <Slider
          name="brightness"
          value={b.value}
          label="brightness"
          icon="brightness6"
          end={
            <button
              type="button"
              aria-label="auto brightness"
              class={`cc-auto ${b.auto ? "on" : ""}`}
              onClick={() => powos.qs.set("auto-brightness", b.auto ? 0 : 1).then(update)}
            >
              A
            </button>
          }
        />
        <Slider
          name="volume"
          value={v.value}
          label={`volume · ${RINGER[v.ringer] ?? "ring"}`}
          icon={v.ringer === 0 ? "bellOffOutline" : v.ringer === 1 ? "vibrate" : v.value <= 0 ? "volumeOff" : "volumeHigh"}
          onIcon={() => powos.qs.set("ringer", ((v.ringer + 2) % 3) / 2).then(update)}
        />
      </div>
      <MediaCard />
      <div class="cc-grid cc-main">
        {groups.map(({ g, ts }) => (
          <GroupTile key={g.id} g={g} ts={ts} />
        ))}
      </div>
      {open$ && <Sheet ts={open$.ts} />}
      <button type="button" class="cc-all" onClick={() => ((sheet.value = null), (allTiles.value = true))}>
        all tiles
        <Icon name="chevronRight" />
      </button>
    </div>
  );
}
