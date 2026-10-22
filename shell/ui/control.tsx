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
import { ccV3, notif, panel } from "../state.ts";
import { held, notifOpen } from "./gesture.ts";
import { ccEditing, ccExpanded } from "./ccexpand.ts";
import { useReorder } from "./reorder.ts";
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
  const from = useRef<[number, number]>([0, 0]);
  return {
    onPointerDown: (e: PointerEvent) => {
      held.current = false;
      from.current = [e.clientX, e.clientY];
      // In a reorderable row the long press is the pickup's (useReorder); its page opens from a still hold there.
      if (hold) timer.current = window.setTimeout(open, HOLD);
    },
    // Moved: a pull or a scroll that started on it (the further pull down from the row), not a long press - a drag
    // from the row held long enough opened Wi-Fi's settings.
    onPointerMove: (e: PointerEvent) => {
      if (Math.hypot(e.clientX - from.current[0], e.clientY - from.current[1]) > 10) clearTimeout(timer.current);
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
/** The arrangement from the store: at start, and each time the control center opens - the shade, home and Quick
 * Tools are separate pages, and one's rearranging must show in the others (nor be written over by their stale copy). */
const loadLayout = () => powos.store.get<Layout>("controls.layout").then((l) => l && (layout.value = l)).catch(() => {});
loadLayout();

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
function MediaCard({ i = 0 }: { i?: number }) {
  useEffect(askMedia, []);
  const m = media.value;
  if (!m?.available || !m.title) return null;
  const progress = m.duration ? Math.min(1, (m.position ?? 0) / m.duration) : 0;
  return (
    <div class="cc-media cascade" style={{ "--p": String(progress), "--i": i }}>
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
/** Edit mode's selected item (a category or a member, by key): its actions over it, as a selected tile's on home. */
const chosen = signal<string | null>(null);

/** A selected item's actions in edit mode (home's .tile-actions): its own settings page, when it has one. */
function Chosen({ id, page }: { id: string; page: string | null }) {
  if (!ccEditing.value || chosen.value !== id || !page || NO_PAGE.has(page)) return null;
  return (
    <div class="tile-actions tile" data-edit-ok data-no-lift onPointerDown={(e) => e.stopPropagation()}>
      <button type="button" onClick={() => (chosen.value = null, shut(), powos.qs.open(page).catch(() => {}))}>
        settings
      </button>
    </div>
  );
}

function GroupTile({ g, ts }: { g: Group; ts: QuickTile[] }) {
  const first = ts[0];
  const press = usePress(first, false);
  const st = groupState(g, ts);
  const several = ts.length > 1;
  const open = opened.value === g.id;
  const toggle = () => (opened.value = open ? null : g.id);
  // The whole view (ccexpand.ts): its members inside it, under its name - small round toggles, no surface of their own.
  const all = several && ccExpanded.value;
  return (
    <div class={`cc-cell ${all ? "all" : ""} ${ccEditing.value && chosen.value === g.id ? "chosen" : ""}`} data-key={g.id}>
      <Chosen id={g.id} page={several ? null : first.id} />
    <button
      type="button"
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
        {several && !all && (
          <span
            class="cc-more"
            role="button"
            data-edit-ok
            data-no-lift
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
      {all && <CellMembers g={g} ts={ts} />}
    </div>
  );
}

/** A member under an open category: a small round toggle over its name (remote input and the glasses their own). */
function Sub({ t, class: c = "cc-sub" }: { t: QuickTile; class?: string }) {
  return (
    <div class={`${c} ${ccEditing.value && chosen.value === t.id ? "chosen" : ""}`} data-key={t.id}>
      <Chosen id={t.id} page={t.id} />
      <Face t={t} />
    </div>
  );
}

/** The members a category's tile shows in the whole view: reordered as its row's are (the first is its tap). */
function CellMembers({ g, ts }: { g: Group; ts: QuickTile[] }) {
  const byId = new Map(ts.map((t) => [t.id, t]));
  const r = useReorder(ts.map((t) => t.id), (ids) => reorderMembers.current(g.id, ids), ccEditing, editHooks);
  return (
    <div class="cc-cell-subs" {...r.handlers}>
      {r.order.map((id) => byId.get(id) && <Sub key={id} t={byId.get(id)!} class="cc-mini" />)}
    </div>
  );
}

/** Edit mode's hooks for every container in it: while one is carried the shade's own gestures hold off. */
const editHooks = {
  onLift: () => {
    held.value = true;
    chosen.value = null;
  },
  onLand: () => (held.value = false),
  onSelect: (k: string) => (chosen.value = chosen.value === k ? null : k),
};
/** The current arrangement's member reorder (ControlCenter sets it each render; the cells' reorders call it). */
const reorderMembers = { current: (_gid: string, _ids: string[]) => {} };

/** A member's toggle (an open category's row, or inside its tile in the whole view). */
function Face({ t }: { t: QuickTile }) {
  if (t.id === REMOTE_ID) return <RemoteTile t={t} />;
  if (t.id === GLASSES_ID) return <GlassesTile t={t} />;
  // OnePlus Share and Google's Quick Share are one member: "quick share".
  if (t.app === "com.oneplus.oshare" || t.app === "com.google.android.gms") return <Tile t={{ ...t, label: "quick share" }} hold={false} />;
  return <Tile t={t} hold={false} />;
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
  const { order, handlers, carrying } = useReorder(group.ts.map((t) => t.id), (ids) => reorder(group.g.id, ids), ccEditing, editHooks);
  return (
    <div class={`cc-subs ${carrying ? "dragging" : ""}`} {...handlers}>
      {order.map((id) => byId.get(id) && <Sub key={id} t={byId.get(id)!} />)}
    </div>
  );
}

/** The control center: the v3 layout (state.ts ccV3), or the eight category tiles. */
export function ControlCenter() {
  return ccV3.value === "v3" ? <Controls /> : <Categories />;
}

function Categories() {
  // Shown: other apps' tiles listen (their state kept current), until it's shut or turned back to notifications.
  const open = notifOpen.value;
  useEffect(() => {
    if (!open) return;
    loadLayout();
    powos.qs.listening(true);
    askRemote();
    // The cable's state has no event: asked while the panel shows - not while its window is put away.
    const timer = window.setInterval(() => document.hidden || askRemote(), 3000);
    return () => {
      powos.qs.listening(false);
      clearInterval(timer);
      picking.value = false;
      opened.value = null;
      ccExpanded.value = false;
      ccEditing.value = false;
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
    ccEditing,
    // Lifted: no category open (the rows move as one grid).
    { ...editHooks, onLift: () => (editHooks.onLift(), (opened.value = null)) },
  );
  const ordered = grid.order.map((id) => byGid.get(id)).filter((x): x is (typeof live)[number] => !!x);
  reorderMembers.current = (gid: string, ids: string[]) =>
    saveArrangement(ordered.map((x) => (x.g.id === gid ? { ...x, ts: ids.map((id) => x.ts.find((t) => t.id === id)!).filter(Boolean) } : x)));
  const rows: (typeof live)[] = [];
  for (let i = 0; i < ordered.length; i += 4) rows.push(ordered.slice(i, i + 4));
  return (
    <div class={`cc ${ccEditing.value ? "cc-editing" : ""}`}>
      <div class="notif-bar cascade" style={{ "--i": 0 }}>
        <Clock />
        {ccEditing.value ? (
          // Edit mode's way out, as home's edit bar's.
          <button type="button" class="edit-act done" data-edit-ok onClick={() => (ccEditing.value = false)}>
            done
          </button>
        ) : (
          <span class="notif-actions icons">
            <button type="button" aria-label="settings" onClick={() => (shut(), powos.qs.open("settings"))}>
              <Icon name="cogOutline" />
            </button>
          </span>
        )}
      </div>
      <div class="cc-sliders cascade" style={{ "--i": 1 }}>
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
      <MediaCard i={2} />
      <div class={`cc-main ${grid.carrying ? "dragging" : ""}`} {...grid.handlers}>
        {rows.map((row, r) => (
          <Fragment key={r}>
            <div class="cc-grid cascade" style={{ "--i": 3 + r }}>
              {row.map(({ g, ts }) => (
                <GroupTile key={g.id} g={g} ts={ts} />
              ))}
            </div>
            <Unfold group={ccExpanded.value ? undefined : row.find((x) => x.g.id === opened.value)} reorder={reorderMembers.current} />
          </Fragment>
        ))}
      </div>
      <RemotePick />
    </div>
  );
}

/*
 * The v3 layout (state.ts ccV3): the header, the two sliders, the media; one row of the most-used toggles - one tap
 * each, labelled; pulled further (ccexpand.ts), every control in one uniform labelled grid under quiet section names,
 * no category tiles and nothing hanging under them. A long press is a toggle's own page; rearranging is edit mode's
 * (the header's pencil, then a long press lifts - ui/reorder.ts), within a section or the row.
 */

/** The row the first pull shows: the most used, in this order unless rearranged. */
const QUICK = ["wifi", "cell", "bt", "dnd", "app:com.oplus.eyeprotect", "rotation"];
/** Every control by section, on a further pull; what none names goes under Tools. */
const SECTIONS: { id: string; label: string; members: string[] }[] = [
  {
    id: "connect",
    label: "connect",
    members: ["wifi", "cell", "airplane", "hotspot", "bt", "nfc", "app:com.google.android.gms|app:com.oneplus.oshare", "app:com.oplus.linker", GLASSES_ID, "location"],
  },
  // Focus with the screen's own (no sound-mode tiles to make a section of: the volume slider's icon is the ringer).
  { id: "display", label: "display & focus", members: ["rotation", "darkmode", "app:com.oplus.eyeprotect", "dnd", "battery"] },
  { id: "tools", label: "tools", members: ["flashlight", "screenshot", "screenrecord", "calculator", "qr_code_scanner", "wallet", "controls"] },
];
/** Each control's one word. */
const WORD: Record<string, string> = {
  wifi: "wi-fi",
  cell: "data",
  airplane: "airplane",
  hotspot: "hotspot",
  bt: "bluetooth",
  nfc: "nfc",
  location: "location",
  rotation: "rotate",
  darkmode: "dark",
  battery: "saver",
  dnd: "focus",
  flashlight: "torch",
  screenshot: "screenshot",
  screenrecord: "record",
  calculator: "calculator",
  qr_code_scanner: "scan",
  wallet: "wallet",
  controls: "devices",
  [GLASSES_ID]: "glasses",
  [REMOTE_ID]: "remote",
};
const WORD_APP: Record<string, string> = { "com.oplus.eyeprotect": "eye", "com.google.android.gms": "share", "com.oneplus.oshare": "share", "com.oplus.linker": "cast" };
const word = (t: QuickTile) => WORD[t.id] ?? (t.app && WORD_APP[t.app]) ?? t.label.toLowerCase().split(/\s+/)[0];

/** One control: its icon on a chip (the accent when on), its word under it. A long press opens its page. */
function Toggle({ t }: { t: QuickTile }) {
  const press = usePress(t, !ccEditing.value);
  const special = t.id === GLASSES_ID ? openGlasses : t.id === REMOTE_ID ? openRemote : null;
  return (
    <div class={`cc3-cell ${ccEditing.value && chosen.value === t.id ? "chosen" : ""}`} data-key={t.id}>
      <Chosen id={t.id} page={t.id} />
      <button
        type="button"
        class={`cc3-t ${t.on ? "on" : ""}`}
        aria-label={`${t.label}${t.on == null ? "" : t.on ? ": on" : ": off"}`}
        aria-pressed={t.on == null ? undefined : t.on}
        {...press}
        onClick={special ? () => (shut(), special()) : press.onClick}
      >
        <span class="cc3-chip">
          <Icon name={tileIcon(t)} />
        </span>
        <span class="cc3-word">{word(t)}</span>
      </button>
    </div>
  );
}

/** A row or a section of toggles, rearranged in edit mode; [save] gets its new order. */
function ToggleGrid({ ts, save, class: c = "" }: { ts: QuickTile[]; save: (ids: string[]) => void; class?: string }) {
  const byId = new Map(ts.map((t) => [t.id, t]));
  const r = useReorder(ts.map((t) => t.id), save, ccEditing, { ...editHooks, onlyEditing: true });
  return (
    <div class={`cc3-grid ${c}`} {...r.handlers}>
      {r.order.map((id) => byId.get(id) && <Toggle key={id} t={byId.get(id)!} />)}
    </div>
  );
}

/** Saves a group's new order into the arrangement: the group's places in the whole order kept, filled in its new order. */
function saveOrder(all: string[], ids: string[]) {
  const pos = (id: string) => {
    const i = layout.value.order.indexOf(id);
    return i < 0 ? 1e6 + all.indexOf(id) : i;
  };
  const order = [...all].sort((a, b) => pos(a) - pos(b));
  let k = 0;
  const l = { order: order.map((id) => (ids.includes(id) ? ids[k++] : id)), hidden: layout.value.hidden };
  layout.value = l;
  powos.store.set("controls.layout", l);
}

function Controls() {
  const open = notifOpen.value;
  useEffect(() => {
    if (!open) return;
    loadLayout();
    powos.qs.listening(true);
    askRemote();
    const timer = window.setInterval(() => document.hidden || askRemote(), 3000);
    return () => {
      powos.qs.listening(false);
      clearInterval(timer);
      picking.value = false;
      ccExpanded.value = false;
      ccEditing.value = false;
      chosen.value = null;
    };
  }, [open]);
  const q = quick.value;
  const every = [...(q.tiles ?? []), ...(glasses.value ? [glassesTile()] : [])].filter((t) => !leftOut(t));
  const b = q.brightness ?? { value: 0.5, auto: false };
  const v = q.volume ?? { value: 0.5, ringer: 2 };
  // The user's order (controls.layout) within each group; the curated order after.
  const pos = (id: string) => {
    const i = layout.value.order.indexOf(id);
    return i < 0 ? 1e6 : i;
  };
  const ordered = (ts: QuickTile[]) => ts.map((t, i) => ({ t, i })).sort((a, c) => pos(a.t.id) - pos(c.t.id) || a.i - c.i).map((x) => x.t);
  const pick = (ms: string[]) => ms.map((m) => member(every, m)).filter((t): t is QuickTile => !!t);
  const placed = new Set<QuickTile>();
  const sections = SECTIONS.map((sec) => {
    sec.members.forEach((m) => named(every, m).forEach((t) => placed.add(t)));
    return { sec, ts: pick(sec.members) };
  });
  sections[sections.length - 1].ts.push(...every.filter((t) => !placed.has(t)));
  const all = every.map((t) => t.id);
  // The curated default: the most used first, then every other control by kind; the user's order over it.
  const quickTs = pick(QUICK);
  const list = ordered([...quickTs, ...sections.flatMap((x) => x.ts).filter((t) => !quickTs.includes(t))]);
  const whole = ccExpanded.value;
  return (
    <div class={`cc v3 ${ccEditing.value ? "cc-editing" : ""} ${whole ? "whole" : ""}`}>
      <div class="notif-bar cascade" style={{ "--i": 0 }}>
        <Clock />
        {ccEditing.value ? (
          <button type="button" class="edit-act done" data-edit-ok onClick={() => (ccEditing.value = false)}>
            done
          </button>
        ) : (
          <span class="notif-actions icons">
            <button type="button" aria-label="rearrange" onClick={() => (ccEditing.value = true)}>
              <Icon name="pencilOutline" />
            </button>
            <button type="button" aria-label="settings" onClick={() => (shut(), powos.qs.open("settings"))}>
              <Icon name="cogOutline" />
            </button>
          </span>
        )}
      </div>
      <div class="cc-sliders cascade" style={{ "--i": 1 }}>
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
      <MediaCard i={2} />
      {/*
        * One ordered list (the user's order; edit mode rearranges it): the first six are the first pull's row, and a
        * further pull only reveals the rest under them - the row never moves (the user: icons mustn't reorganize).
        */}
      <div class={`cc3-list cascade ${whole ? "whole" : ""}`} style={{ "--i": 3 }}>
        <ToggleGrid ts={list} save={(ids) => saveOrder(all, ids)} />
      </div>
    </div>
  );
}
