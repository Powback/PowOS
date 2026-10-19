/**
 * The control center: PowOS's in place of OnePlus's (a pull on the status bar's right half, or "controls" on the
 * notification panel). Everything the phone's own one has, in its order (QuickState.tiles is SystemUI's tile list): Wi-Fi
 * and mobile data as the two big cards, the brightness and volume sliders, then the tiles. A tap switches a tile (or
 * runs it: screenshot, lock), a long press opens its page in Settings. It lives in the notification panel's place, so the
 * pull, the finger following it and the swipe up to shut it are the panel's own (gesture.ts).
 */
import { useEffect, useRef, useState } from "preact/hooks";
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import { notif, panel } from "../state.ts";
import { notifOpen } from "./gesture.ts";
import { Icon, type IconName } from "./icons.tsx";
import type { MediaState, QuickState, QuickTile } from "../types.ts";

/** The phone's quick settings, kept up to date ("qs.changed"): the control center's and the notification panel's row. */
export const quick = signal<QuickState>({
  torch: null,
  dnd: null,
  tiles: [],
  brightness: { value: 0.5, auto: false },
  volume: { value: 0.5, ringer: 2 },
});
powos.on("qs.changed", (q: QuickState) => (quick.value = { ...q }));
powos.qs.state().then((q) => (quick.value = q));

/** Held this long (ms), a tile opens its page instead. */
const HOLD = 450;

/** The big cards on top, as OnePlus's. */
const CARDS = ["wifi", "cell"];

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

const RINGER = ["silent", "vibrate", "ring"];
const RINGER_ICON: IconName[] = ["bellOffOutline", "vibrate", "bellRingOutline"];

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

const update = (s: QuickState) => (quick.value = { ...s });

function shut() {
  notif.value = false;
}

/** A tile's tap and long press. */
function usePress(t: QuickTile) {
  const timer = useRef(0);
  const held = useRef(false);
  const open = () => {
    held.current = true;
    shut();
    powos.qs.open(t.id);
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

function Tile({ t, big = false }: { t: QuickTile; big?: boolean }) {
  const press = usePress(t);
  // Editing: a tap picks the tile (to move or hide), it doesn't switch it.
  const edit = editing.value ? { onClick: () => (picked.value = picked.value === t.id ? null : t.id) } : press;
  return (
    <button
      type="button"
      class={`cc-tile ${big ? "big" : ""} ${t.on ? "on" : ""} ${picked.value === t.id ? "picked" : ""}`}
      {...edit}
    >
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

/** One of the notification panel's quick icons: the tile's icon only, switched (and long-pressed) as in here. */
function MiniTile({ t }: { t: QuickTile }) {
  return (
    <button type="button" class={`cc-mini ${t.on ? "on" : ""}`} aria-label={t.label} {...usePress(t)}>
      <Icon name={tileIcon(t)} />
    </button>
  );
}

/** The notification panel's row: the control center's first tiles, in the user's order, as icons. */
export function QuickStrip({ count = 6 }: { count?: number }) {
  const tiles = quick.value.tiles ?? [];
  const cards = CARDS.map((id) => tiles.find((t) => t.id === id)).filter((t): t is QuickTile => !!t);
  const { shown } = arranged(tiles.filter((t) => !CARDS.includes(t.id)));
  return (
    <div class="cc-strip">
      {[...cards, ...shown].slice(0, count).map((t) => (
        <MiniTile key={t.id} t={t} />
      ))}
    </div>
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
const picked = signal<string | null>(null);

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

/** The picked tile [by] places along (−1 earlier, +1 later), or out (hide) / back in. */
function rearrange(shown: QuickTile[], id: string, by: -1 | 1 | "hide" | "show") {
  const ids = shown.map((t) => t.id);
  const hidden = layout.value.hidden.filter((h) => h !== id);
  if (by === "hide")
    return (saveLayout({ order: ids.filter((x) => x !== id), hidden: [...hidden, id] }), (picked.value = null));
  if (by === "show") return saveLayout({ order: [...ids, id], hidden });
  const i = ids.indexOf(id);
  const j = i + by;
  if (i < 0 || j < 0 || j >= ids.length) return;
  [ids[i], ids[j]] = [ids[j], ids[i]];
  saveLayout({ order: ids, hidden });
}

/** Edit mode's tools for the picked tile, and the tiles taken out (a tap puts one back). */
function EditBar({ shown, hidden }: { shown: QuickTile[]; hidden: QuickTile[] }) {
  const id = picked.value;
  return (
    <div class="cc-edit">
      {id ? (
        <span class="cc-edit-tools">
          <button type="button" class="cc-chip" aria-label="earlier" onClick={() => rearrange(shown, id, -1)}>
            <Icon name="chevronLeft" />
          </button>
          <button type="button" class="cc-chip" aria-label="later" onClick={() => rearrange(shown, id, 1)}>
            <Icon name="chevronRight" />
          </button>
          <button type="button" class="cc-chip" aria-label="hide" onClick={() => rearrange(shown, id, "hide")}>
            <Icon name="eyeOffOutline" />
          </button>
        </span>
      ) : (
        <span class="muted">tap a tile to move or hide it</span>
      )}
      {hidden.length > 0 && (
        <>
          <span class="muted">hidden - tap to add back</span>
          <div class="cc-grid">
            {hidden.map((t) => (
              <button key={t.id} type="button" class="cc-tile off" onClick={() => rearrange(shown, t.id, "show")}>
                <span class="cc-icon">
                  <Icon name={tileIcon(t)} />
                </span>
                <span class="cc-label">{t.label}</span>
              </button>
            ))}
          </div>
        </>
      )}
    </div>
  );
}

/** A slider sending its value at most once a frame while it moves. */
function Slider({
  name,
  value,
  label,
  icon,
}: {
  name: "brightness" | "volume";
  value: number;
  label: string;
  icon: IconName;
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
    <label class="cc-slider" style={{ "--v": String(shown) }} aria-label={label}>
      <span class="cc-slider-icon">
        <Icon name={icon} />
      </span>
      <input
        type="range"
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
    </label>
  );
}

function Clock() {
  const [now, setNow] = useState(new Date());
  useEffect(() => {
    const t = window.setInterval(() => setNow(new Date()), 10_000);
    return () => clearInterval(t);
  }, []);
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

export function ControlCenter() {
  // Shown: other apps' tiles listen (their state kept current), until it's shut or turned back to notifications.
  const open = notifOpen.value;
  useEffect(() => {
    if (!open) return;
    powos.qs.listening(true);
    return () => void powos.qs.listening(false);
  }, [open]);
  const q = quick.value;
  const tiles = q.tiles ?? [];
  const cards = CARDS.map((id) => tiles.find((t) => t.id === id)).filter((t): t is QuickTile => !!t);
  const { shown, hidden } = arranged(tiles.filter((t) => !CARDS.includes(t.id)));
  const b = q.brightness ?? { value: 0.5, auto: false };
  const v = q.volume ?? { value: 0.5, ringer: 2 };
  return (
    <div class="cc">
      <div class="notif-bar">
        <Clock />
        <span class="notif-actions icons">
          <button
            type="button"
            aria-label={editing.value ? "done" : "edit"}
            class={editing.value ? "on" : ""}
            onClick={() => ((editing.value = !editing.value), (picked.value = null))}
          >
            <Icon name={editing.value ? "check" : "pencilOutline"} />
          </button>
          <button type="button" aria-label="notifications" onClick={() => (panel.value = "notifications")}>
            <Icon name="bellOutline" />
          </button>
          {/* OnePlus's own, for what PowOS's doesn't have yet. */}
          <button type="button" aria-label="system panel" onClick={() => powos.system.notifications(true)}>
            <Icon name="android" />
          </button>
          <button type="button" aria-label="settings" onClick={() => (shut(), powos.qs.open("settings"))}>
            <Icon name="cogOutline" />
          </button>
        </span>
      </div>
      <div class="cc-cards">
        {cards.map((t) => (
          <Tile key={t.id} t={t} big />
        ))}
      </div>
      <div class="cc-sliders">
        <Slider name="brightness" value={b.value} label="brightness" icon="brightness6" />
        <button
          type="button"
          aria-label="auto brightness"
          class={`cc-chip ${b.auto ? "on" : ""}`}
          onClick={() => powos.qs.set("auto-brightness", b.auto ? 0 : 1).then(update)}
        >
          <Icon name="brightnessAuto" />
        </button>
        <Slider name="volume" value={v.value} label="volume" icon={v.value > 0 ? "volumeHigh" : "volumeOff"} />
        <button
          type="button"
          aria-label={RINGER[v.ringer] ?? "ring"}
          class="cc-chip"
          onClick={() => powos.qs.set("ringer", ((v.ringer + 2) % 3) / 2).then(update)}
        >
          <Icon name={RINGER_ICON[v.ringer] ?? "bellRingOutline"} />
        </button>
      </div>
      <MediaCard />
      <div class="cc-grid">
        {shown.map((t) => (
          <Tile key={t.id} t={t} />
        ))}
      </div>
      {editing.value && <EditBar shown={shown} hidden={hidden} />}
    </div>
  );
}
