/**
 * The control center: PowOS's in place of OnePlus's (a pull on the status bar's right half, or "controls" on the
 * notification panel). Everything the phone's own one has, in its order (QuickState.tiles is SystemUI's tile list): Wi-Fi
 * and mobile data as the two big cards, the brightness and volume sliders, then the tiles. A tap switches a tile (or
 * runs it: screenshot, lock), a long press opens its page in Settings. It lives in the notification panel's place, so the
 * pull, the finger following it and the swipe up to shut it are the panel's own (gesture.ts).
 */
import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import { notif, panel } from "../state.ts";
import { notifOpen } from "./gesture.ts";
import { Icon, type IconName } from "./icons.tsx";
import { openRemote } from "../remote.ts";
import { useMinuteClock } from "./time.ts";
import type { MediaState, QuickState, QuickTile, RemoteState, RemoteTarget } from "../types.ts";

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
  [REMOTE_ID]: "keyboardOutline",
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

function Tile({ t, big = false }: { t: QuickTile; big?: boolean }) {
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
    };
  }, [open]);
  const q = quick.value;
  const tiles = q.tiles ?? [];
  const cards = CARDS.map((id) => tiles.find((t) => t.id === id)).filter((t): t is QuickTile => !!t);
  // Remote input's tile joins the phone's: a layout kept before it was there gets it at the end (arranged's new tiles).
  const { shown, hidden } = arranged([...tiles.filter((t) => !CARDS.includes(t.id)), remoteTile()]);
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
            onClick={() => (editing.value = !editing.value)}
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
      {editing.value ? (
        <EditGrid shown={shown} hidden={hidden} />
      ) : (
        <div class="cc-grid">
          {shown.map((t) => (t.id === REMOTE_ID ? <RemoteTile key={t.id} t={t} /> : <Tile key={t.id} t={t} />))}
        </div>
      )}
      {!editing.value && <RemotePick />}
    </div>
  );
}
