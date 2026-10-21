/**
 * The control center: PowOS's in place of OnePlus's (a pull on the status bar's right half, or "controls" on the
 * notification panel). Everything the phone's own one has, in its order (QuickState.tiles is SystemUI's tile list): Wi-Fi
 * and mobile data as the two big cards, the brightness and volume sliders, then the tiles. A tap switches a tile (or
 * runs it: screenshot, lock), a long press opens its page in Settings. It lives in the notification panel's place, so the
 * pull, the finger following it and the swipe up to shut it are the panel's own (gesture.ts).
 */
import { useEffect, useRef, useState } from "preact/hooks";
import { Fragment, type ComponentChildren } from "preact";
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
 * The user's arrangement of the tiles (kept from the earlier edit mode): their order and the ones taken out, in the store. Tiles it
 * doesn't name yet (a new app's tile) come after, in the phone's own order.
 */
type Layout = { order: string[]; hidden: string[] };
const layout = signal<Layout>({ order: [], hidden: [] });
powos.store.get<Layout>("controls.layout").then((l) => l && (layout.value = l));

function arranged(tiles: QuickTile[]) {
  const { order, hidden } = layout.value;
  const byId = new Map(tiles.map((t) => [t.id, t]));
  const shown = [...order.filter((id) => byId.has(id)), ...tiles.map((t) => t.id).filter((id) => !order.includes(id))]
    .filter((id) => !hidden.includes(id))
    .map((id) => byId.get(id)!);
  return { shown, hidden: hidden.filter((id) => byId.has(id)).map((id) => byId.get(id)!) };
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
 * The control center's eight category tiles: every control the phone has lives under one of them - nothing hidden on
 * a page of its own. A tap does the category's primary action (its first member: wi-fi, bluetooth, dark mode,
 * screenshot, do not disturb, battery saver, the torch, location); the chevron or a long press opens the category in
 * place - the row under it unfolds (its height animates, the grid below moves down) into its members as small round
 * toggles; one category open at a time. A tile the phone has that no category names goes under Tools.
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
    members: ["bt", "nfc", "app:com.oneplus.oshare", "app:com.google.android.gms", "app:com.oplus.linker", "app:com.microsoft.appmanager", GLASSES_ID, REMOTE_ID],
  },
  { id: "display", label: "display", icon: "themeLightDark", members: ["darkmode", "app:com.oplus.eyeprotect", "rotation"] },
  { id: "capture", label: "capture", icon: "cellphoneScreenshot", members: ["screenshot", "screenrecord", "qr_code_scanner"] },
  { id: "focus", label: "focus", icon: "minusCircleOutline", members: ["dnd"] },
  { id: "power", label: "power", icon: "leaf", members: ["battery", "lockscreen"] },
  { id: "tools", label: "tools", icon: "flashlight", members: ["flashlight", "calculator", "wallet", "controls"] },
  { id: "location", label: "location", icon: "mapMarker", members: ["location"] },
];

const member = (tiles: QuickTile[], m: string) => (m.startsWith("app:") ? tiles.find((t) => t.app === m.slice(4)) : tiles.find((t) => t.id === m));

/** A short name for a member in a category's state line ("wi-fi · 5G", "bt · nfc"). */
const SHORT: Record<string, string> = { bt: "bt", nfc: "nfc", darkmode: "dark", rotation: "rotate", battery: "saver", flashlight: "torch", dnd: "on", location: "on", lockscreen: "lock" };

/** What a category's tile says under its name: what's on inside it. */
function groupState(g: Group, ts: QuickTile[]): { on: boolean; detail: string } {
  const by = (id: string) => ts.find((t) => t.id === id);
  const first = ts[0];
  if (g.id === "internet") {
    if (by("airplane")?.on) return { on: true, detail: "airplane" };
    const wifi = by("wifi");
    const cell = by("cell");
    const parts = [wifi?.on ? wifi.detail || "wi-fi" : null, cell?.on ? cell.detail || "data" : null].filter(Boolean);
    return { on: !!wifi?.on, detail: parts.length ? parts.join(" · ") : "off" };
  }
  if (g.id === "capture") return { on: false, detail: "" };
  const on = ts.filter((t) => t.on);
  const name = (t: QuickTile) => SHORT[t.id] ?? t.label.toLowerCase();
  return { on: !!first.on, detail: on.length ? on.map(name).join(" · ") : "off" };
}

/** The category open in place (its members unfolded under its row). */
const opened = signal<string | null>(null);

function GroupTile({ g, ts }: { g: Group; ts: QuickTile[] }) {
  const first = ts[0];
  const press = usePress(first);
  const timer = useRef(0);
  const held = useRef(false);
  const st = groupState(g, ts);
  const several = ts.length > 1;
  const open = opened.value === g.id;
  const toggle = () => (opened.value = open ? null : g.id);
  return (
    <button
      type="button"
      class={`cc-tile ${st.on ? "on" : ""} ${open ? "opened" : ""}`}
      aria-label={`${g.label}: ${st.detail}`}
      aria-expanded={several ? open : undefined}
      onPointerDown={() => {
        held.current = false;
        timer.current = window.setTimeout(() => {
          held.current = true;
          if (several) toggle();
          else press.onPointerDown();
        }, HOLD);
      }}
      onPointerUp={() => clearTimeout(timer.current)}
      onPointerCancel={() => clearTimeout(timer.current)}
      onPointerLeave={() => clearTimeout(timer.current)}
      onContextMenu={(e: Event) => e.preventDefault()}
      onClick={() => {
        if (held.current) return;
        // Remote input and the glasses open their own screens; the rest switch or run.
        if (first.id === REMOTE_ID) return (shut(), openRemote());
        if (first.id === GLASSES_ID) return (shut(), openGlasses());
        press.onClick();
      }}
    >
      <span class="cc-icon">
        <Icon name={g.id === "internet" && !st.on ? "wifiOff" : g.id === "tools" && !st.on ? "flashlightOff" : g.icon} />
        {several && (
          <span
            class="cc-more"
            role="button"
            aria-label={`${g.label}: ${open ? "close" : "open"}`}
            onPointerDown={(e) => e.stopPropagation()}
            onClick={(e) => {
              e.stopPropagation();
              toggle();
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

/** A member under an open category: a small round toggle over its name (remote input and the glasses their own). */
function Sub({ t }: { t: QuickTile }) {
  if (t.id === REMOTE_ID) return <RemoteTile t={t} />;
  if (t.id === GLASSES_ID) return <GlassesTile t={t} />;
  return <Tile t={t} />;
}

/**
 * A row's unfolding: under each row of four, the open category's members when it's in that row. The height animates
 * (a grid row from 0fr to 1fr); closing, the members stay drawn while it folds away.
 */
function Unfold({ group }: { group: { g: Group; ts: QuickTile[] } | undefined }) {
  const last = useRef(group);
  if (group) last.current = group;
  const shown = group ?? last.current;
  return (
    <div class={`cc-unfold ${group ? "open" : ""}`} aria-hidden={!group}>
      <div>
        {shown && (
          <div class="cc-subs">
            {shown.ts.map((t) => (
              <Sub key={t.id} t={t} />
            ))}
          </div>
        )}
      </div>
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
      opened.value = null;
    };
  }, [open]);
  const q = quick.value;
  const tiles = q.tiles ?? [];
  // Remote input's and the glasses' tiles join the phone's.
  const every = [...tiles, remoteTile(), ...(glasses.value ? [glassesTile()] : [])];
  const { shown } = arranged(every);
  const b = q.brightness ?? { value: 0.5, auto: false };
  const v = q.volume ?? { value: 0.5, ringer: 2 };
  const named = new Set<QuickTile>();
  const groups = GROUPS.map((g) => {
    const ts = g.members.map((m) => member(every, m)).filter((t): t is QuickTile => !!t);
    ts.forEach((t) => named.add(t));
    return { g, ts };
  });
  // Nothing is lost: a tile no category names (another app's, a new one) goes under Tools.
  const tools = groups.find((x) => x.g.id === "tools");
  if (tools) tools.ts.push(...every.filter((t) => !named.has(t)));
  const live = groups.filter((x) => x.ts.length > 0);
  // The user's arrangement orders the eight, by where their primary tiles are in it.
  const pos = (id: string) => {
    const i = shown.findIndex((t) => t.id === id);
    return i < 0 ? 999 : i;
  };
  if (layout.value.order.length) live.sort((a, b2) => pos(a.ts[0].id) - pos(b2.ts[0].id));
  const rows: (typeof live)[] = [];
  for (let i = 0; i < live.length; i += 4) rows.push(live.slice(i, i + 4));
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
      <div class="cc-main">
        {rows.map((row, r) => (
          <Fragment key={r}>
            <div class="cc-grid">
              {row.map(({ g, ts }) => (
                <GroupTile key={g.id} g={g} ts={ts} />
              ))}
            </div>
            <Unfold group={row.find((x) => x.g.id === opened.value)} />
          </Fragment>
        ))}
      </div>
      <RemotePick />
    </div>
  );
}
