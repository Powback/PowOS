/**
 * The control center: PowOS's in place of OnePlus's (a pull on the status bar's right half, or "controls" on the
 * notification panel). Everything the phone's own one has, in its order (QuickState.tiles is SystemUI's tile list): Wi-Fi
 * and mobile data as the two big cards, the brightness and volume sliders, then the tiles. A tap switches a tile (or
 * runs it: screenshot, lock), a long press opens its page in Settings. It lives in the notification panel's place, so the
 * pull, the finger following it and the swipe up to shut it are the panel's own (gesture.ts).
 */
import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";
import { Fragment, type ComponentChildren } from "preact";
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import { notif, panel } from "../state.ts";
import { held, notifOpen } from "./gesture.ts";
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
function usePress(t: QuickTile, hold = true) {
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
      // In a reorderable row the long press is the pickup's (useReorder); its page opens from a still hold there.
      if (hold) timer.current = window.setTimeout(open, HOLD);
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

export function Tile({ t, big = false, hold = true }: { t: QuickTile; big?: boolean; hold?: boolean }) {
  return (
    <button type="button" class={`cc-tile ${big ? "big" : ""} ${t.on ? "on" : ""}`} {...usePress(t, hold)}>
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
    // Quick share: Google's, else OnePlus Share (the same thing twice: one of them, "a|b").
    members: ["bt", "nfc", "app:com.google.android.gms|app:com.oneplus.oshare", "app:com.oplus.linker", GLASSES_ID, "location"],
  },
  // Auto-rotate first: the tile's tap.
  { id: "display", label: "display", icon: "screenRotation", members: ["rotation", "darkmode"] },
  { id: "eye", label: "eye comfort", icon: "eyeOutline", members: ["app:com.oplus.eyeprotect"] },
  { id: "focus", label: "focus", icon: "minusCircleOutline", members: ["dnd"] },
  { id: "battery", label: "battery", icon: "leaf", members: ["battery"] },
  { id: "capture", label: "capture", icon: "cellphoneScreenshot", members: ["screenshot", "screenrecord"] },
  // The torch first (one tap); then every utility tile the phone has (and anything no category names).
  { id: "tools", label: "tools", icon: "flashlight", members: ["flashlight", "calculator", "qr_code_scanner", "wallet", "controls"] },
];
/**
 * Left out of the control center altogether (the user's curation, 2026-10-21): lock, link to windows, remote input -
 * and OnePlus Share where Google's quick share is there. Settings is where they'd come back from, never a page here.
 */
const LEFT_OUT = new Set(["lockscreen", REMOTE_ID, "app:com.microsoft.appmanager"]);
const leftOut = (t: QuickTile) => LEFT_OUT.has(t.id) || (!!t.app && LEFT_OUT.has(`app:${t.app}`));

const one = (tiles: QuickTile[], m: string) => (m.startsWith("app:") ? tiles.find((t) => t.app === m.slice(4)) : tiles.find((t) => t.id === m));
/** A member's tile ("a|b": the first of them present). */
const member = (tiles: QuickTile[], m: string) => m.split("|").map((x) => one(tiles, x)).find((t) => t != null);
/** Every tile a member names, the ones it didn't pick too (so a skipped Google quick share isn't put under Tools). */
const named = (tiles: QuickTile[], m: string) => m.split("|").map((x) => one(tiles, x)).filter((t): t is QuickTile => t != null);

/** A short name for a member in a category's state line ("wi-fi · 5G", "bt · nfc"). */
const SHORT_APP: Record<string, string> = {
  "com.oneplus.oshare": "share",
  "com.google.android.gms": "share",
  "com.oplus.linker": "cast",
  "com.microsoft.appmanager": "windows",
  "com.oplus.eyeprotect": "eye",
};
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
  if (g.id === "battery") return { on: !!first.on, detail: first.on ? "saver on" : "saver off" };
  if (ts.length === 1) return { on: !!first.on, detail: first.on == null ? "" : first.on ? "on" : "off" };
  const on = ts.filter((t) => t.on);
  const name = (t: QuickTile) => (t.app && SHORT_APP[t.app]) || SHORT[t.id] || t.label.toLowerCase();
  return { on: !!first.on, detail: on.length ? on.map(name).join(" · ") : "off" };
}

/** The category open in place (its members unfolded under its row). */
const opened = signal<string | null>(null);

function GroupTile({ g, ts }: { g: Group; ts: QuickTile[] }) {
  const first = ts[0];
  const press = usePress(first, false);
  const st = groupState(g, ts);
  const several = ts.length > 1;
  const open = opened.value === g.id;
  const toggle = () => (opened.value = open ? null : g.id);
  return (
    <button
      type="button"
      data-key={g.id}
      class={`cc-tile ${st.on ? "on" : ""} ${open ? "opened" : ""}`}
      aria-label={`${g.label}: ${st.detail}`}
      aria-expanded={several ? open : undefined}
      onContextMenu={(e: Event) => e.preventDefault()}
      onClick={() => {
        // Remote input and the glasses open their own screens; the rest switch or run.
        if (first.id === REMOTE_ID) return (shut(), openRemote());
        if (first.id === GLASSES_ID) return (shut(), openGlasses());
        press.onClick();
      }}
    >
      <span class="cc-icon">
        <Icon name={g.id === "internet" && !st.on ? "wifiOff" : g.id === "tools" && !st.on ? "flashlightOff" : g.id === "display" && !st.on ? "screenRotationLock" : g.icon} />
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
  let face;
  if (t.id === REMOTE_ID) face = <RemoteTile t={t} />;
  else if (t.id === GLASSES_ID) face = <GlassesTile t={t} />;
  // OnePlus Share and Google's Quick Share are one member: "quick share".
  else if (t.app === "com.oneplus.oshare" || t.app === "com.google.android.gms") face = <Tile t={{ ...t, label: "quick share" }} hold={false} />;
  else face = <Tile t={t} hold={false} />;
  return (
    <div class="cc-sub" data-key={t.id}>
      {face}
    </div>
  );
}

/** Dragged this far (px) before the long press, it's a scroll or a swipe, not a pickup. */
const PICK_SLOP = 8;

/**
 * Long-press-drag reordering of a container's items (children with data-key, direct or in rows): held still for HOLD
 * a tile is picked up (a light haptic) and follows the finger; the others make room live - each eased from where it
 * was (a FLIP: its old place as a transform, played to none), nothing laid out by hand. Let go: the new order to
 * [done]. Held and let go without moving: [still] (a category's open/close, a member's page). While one is held the
 * finger is the control center's (gesture.ts held: the shade's close lets go), and the page doesn't scroll under it.
 */
function useReorder(keys: string[], done: (keys: string[]) => void, still: (key: string) => void, onPick?: () => void) {
  const box = useRef<HTMLDivElement>(null);
  const [live, setLive] = useState<string[] | null>(null);
  const d = useRef<{
    key: string;
    x0: number;
    y0: number;
    x: number;
    y: number;
    gx: number;
    gy: number;
    picked: boolean;
    moved: boolean;
    timer: number;
  } | null>(null);
  const swallowClick = useRef(false);
  const order = live ?? keys;
  const item = (k: string) => box.current?.querySelector<HTMLElement>(`[data-key="${CSS.escape(k)}"]`) ?? null;
  const own = (el: Element | null) => el && el.closest("[data-reorder]") === box.current;
  /** The held one under the finger: its offset from its slot (which moves as the order does). */
  const place = () => {
    const c = d.current;
    const el = c?.picked ? item(c.key) : null;
    if (!c || !el) return;
    el.style.transform = "none";
    const r = el.getBoundingClientRect();
    el.style.transform = `translate(${c.x - c.gx - r.left}px, ${c.y - c.gy - r.top}px) scale(1.06)`;
  };
  // FLIP: every item that moved since the last order eases from its old place.
  const rects = useRef(new Map<string, DOMRect>());
  useLayoutEffect(() => {
    const next = new Map<string, DOMRect>();
    for (const k of order) {
      const el = item(k);
      if (!el) continue;
      if (d.current?.picked && d.current.key === k) continue;
      const r = el.getBoundingClientRect();
      next.set(k, r);
      const was = rects.current.get(k);
      if (live && was && (Math.abs(was.left - r.left) > 0.5 || Math.abs(was.top - r.top) > 0.5))
        el.animate([{ transform: `translate(${was.left - r.left}px, ${was.top - r.top}px)` }, { transform: "none" }], {
          duration: 180,
          easing: "cubic-bezier(0.2, 0.9, 0.3, 1)",
        });
    }
    rects.current = next;
    place();
  }, [order.join()]);
  const end = () => {
    const c = d.current;
    d.current = null;
    if (!c) return;
    clearTimeout(c.timer);
    if (!c.picked) return;
    held.value = false;
    swallowClick.current = true;
    const el = item(c.key);
    el?.classList.remove("held");
    if (el) el.style.transform = "";
    if (!c.moved) still(c.key);
    else if (live) done(live);
    setLive(null);
  };
  const handlers = {
    ref: box,
    "data-reorder": "",
    onPointerDown: (e: PointerEvent) => {
      const el = (e.target as Element).closest<HTMLElement>("[data-key]");
      if (!el || !own(el) || (e.target as Element).closest(".cc-more")) return;
      const key = el.dataset.key!;
      swallowClick.current = false;
      const r = el.getBoundingClientRect();
      const c = { key, x0: e.clientX, y0: e.clientY, x: e.clientX, y: e.clientY, gx: e.clientX - r.left, gy: e.clientY - r.top, picked: false, moved: false, timer: 0 };
      c.timer = window.setTimeout(() => {
        if (d.current !== c) return;
        c.picked = true;
        held.value = true;
        onPick?.();
        navigator.vibrate?.(8);
        try {
          box.current?.setPointerCapture(e.pointerId);
        } catch {}
        item(key)?.classList.add("held");
        rects.current = new Map(order.map((k) => [k, item(k)?.getBoundingClientRect()]).filter((x): x is [string, DOMRect] => !!x[1]));
        setLive([...order]);
      }, HOLD);
      d.current = c;
    },
    onPointerMove: (e: PointerEvent) => {
      const c = d.current;
      if (!c) return;
      c.x = e.clientX;
      c.y = e.clientY;
      const far = Math.hypot(c.x - c.x0, c.y - c.y0) > PICK_SLOP;
      if (!c.picked) {
        // Moving before the hold: a scroll, a swipe, a tap that slid - not a pickup.
        if (far) {
          clearTimeout(c.timer);
          d.current = null;
        }
        return;
      }
      if (far) c.moved = true;
      // The slot whose middle is nearest the finger is where it goes.
      const now = live ?? order;
      let best = -1;
      let dist = Infinity;
      now.forEach((k, i) => {
        if (k === c.key) return;
        const r = item(k)?.getBoundingClientRect();
        if (!r) return;
        const dd = Math.hypot(r.left + r.width / 2 - c.x, r.top + r.height / 2 - c.y);
        if (dd < dist) ((dist = dd), (best = i));
      });
      const from = now.indexOf(c.key);
      const r0 = item(now[best])?.getBoundingClientRect();
      if (best >= 0 && best !== from && r0 && dist < Math.max(r0.width, r0.height) * 0.6) {
        const next = now.filter((k) => k !== c.key);
        next.splice(best, 0, c.key);
        setLive(next);
      } else place();
    },
    onPointerUp: end,
    onPointerCancel: end,
    // Held: the page under it doesn't scroll (and so doesn't cancel the pointer).
    onTouchMove: (e: TouchEvent) => d.current?.picked && e.cancelable && e.preventDefault(),
    // A pickup's release isn't also a tap on what was held.
    onClickCapture: (e: Event) => {
      if (!swallowClick.current) return;
      swallowClick.current = false;
      e.stopPropagation();
      e.preventDefault();
    },
    onContextMenu: (e: Event) => e.preventDefault(),
  };
  return { order, handlers, dragging: live != null };
}

/**
 * Saves an order of the eight and their members as the control center's arrangement (controls.layout's order): the
 * categories one after another, each with its members in their order - so a category's first member (its tap) is the
 * one put first.
 */
function saveArrangement(groups: { g: Group; ts: QuickTile[] }[]) {
  const ids = groups.flatMap((x) => x.ts.map((t) => t.id));
  const l = { order: [...ids, ...layout.value.order.filter((id) => !ids.includes(id))], hidden: layout.value.hidden };
  layout.value = l;
  powos.store.set("controls.layout", l);
}

/**
 * A row's unfolding: under each row of four, the open category's members when it's in that row. The height animates
 * (a grid row from 0fr to 1fr); closing, the members stay drawn while it folds away.
 */
function Unfold({ group, reorder }: { group: { g: Group; ts: QuickTile[] } | undefined; reorder: (gid: string, ids: string[]) => void }) {
  const last = useRef(group);
  if (group) last.current = group;
  const shown = group ?? last.current;
  return (
    <div class={`cc-unfold ${group ? "open" : ""}`} aria-hidden={!group}>
      <div>{shown && <Members key={shown.g.id} group={shown} reorder={reorder} />}</div>
    </div>
  );
}

/** An open category's members: one sideways row; held and dragged, a member moves (first = the category's tap). */
function Members({ group, reorder }: { group: { g: Group; ts: QuickTile[] }; reorder: (gid: string, ids: string[]) => void }) {
  const byId = new Map(group.ts.map((t) => [t.id, t]));
  const { order, handlers, dragging } = useReorder(
    group.ts.map((t) => t.id),
    (ids) => reorder(group.g.id, ids),
    // Held still: the member's own page, as its long press did.
    (id) => !NO_PAGE.has(id) && (shut(), powos.qs.open(id).catch(() => {})),
  );
  return (
    <div class={`cc-subs ${dragging ? "dragging" : ""}`} {...handlers}>
      {order.map((id) => byId.get(id) && <Sub key={id} t={byId.get(id)!} />)}
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
  const placed = new Set<QuickTile>();
  const groups = GROUPS.map((g) => {
    const ts = g.members.map((m) => member(every, m)).filter((t): t is QuickTile => !!t);
    g.members.forEach((m) => named(every, m).forEach((t) => placed.add(t)));
    return { g, ts };
  });
  // Nothing is lost: a tile no category names (another app's, a new one) goes under Tools.
  const tools = groups.find((x) => x.g.id === "tools");
  if (tools) tools.ts.push(...every.filter((t) => !placed.has(t) && !leftOut(t)));
  const live = groups.filter((x) => x.ts.length > 0);
  // The user's arrangement (controls.layout: dragged into place here) orders the eight and each one's members - the
  // first member is the category's tap; what it doesn't name keeps the curated order, after.
  const saved = layout.value.order;
  if (saved.length) {
    const pos = (id: string) => {
      const i = saved.indexOf(id);
      return i < 0 ? 1e6 : i;
    };
    for (const x of live) x.ts = x.ts.map((t, i) => ({ t, i })).sort((a, b2) => pos(a.t.id) - pos(b2.t.id) || a.i - b2.i).map((x2) => x2.t);
    live.sort((a, b2) => Math.min(...a.ts.map((t) => pos(t.id))) - Math.min(...b2.ts.map((t) => pos(t.id))));
  }
  const byGid = new Map(live.map((x) => [x.g.id, x]));
  const grid = useReorder(
    live.map((x) => x.g.id),
    (gids) => saveArrangement(gids.map((id) => byGid.get(id)!).filter(Boolean)),
    // Held still: a category with members opens or closes (its long press); a single one opens its page.
    (gid) => {
      const x = byGid.get(gid);
      if (!x) return;
      if (x.ts.length > 1) opened.value = opened.value === gid ? null : gid;
      else if (!NO_PAGE.has(x.ts[0].id)) (shut(), powos.qs.open(x.ts[0].id).catch(() => {}));
    },
    // Picked up: no category open (the rows move as one grid).
    () => (opened.value = null),
  );
  const ordered = grid.order.map((id) => byGid.get(id)).filter((x): x is (typeof live)[number] => !!x);
  const reorderMembers = (gid: string, ids: string[]) =>
    saveArrangement(ordered.map((x) => (x.g.id === gid ? { ...x, ts: ids.map((id) => x.ts.find((t) => t.id === id)!).filter(Boolean) } : x)));
  const rows: (typeof live)[] = [];
  for (let i = 0; i < ordered.length; i += 4) rows.push(ordered.slice(i, i + 4));
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
      <div class={`cc-main ${grid.dragging ? "dragging" : ""}`} {...grid.handlers}>
        {rows.map((row, r) => (
          <Fragment key={r}>
            <div class="cc-grid">
              {row.map(({ g, ts }) => (
                <GroupTile key={g.id} g={g} ts={ts} />
              ))}
            </div>
            <Unfold group={row.find((x) => x.g.id === opened.value)} reorder={reorderMembers} />
          </Fragment>
        ))}
      </div>
      <RemotePick />
    </div>
  );
}
