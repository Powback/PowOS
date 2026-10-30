// Web windows: an Android app's window over home (unfolded; off unless Settings.Global powos_web_windows = 1).
// The user, 2026-10-29: "the powos home typescript should deal with the windows and their content", "it should be
// pinned to a page properly natively". This file is the windows' MODEL: page, position, size, scale, z-order (list
// order), minimised/maximised. The host (WebWindows.kt) draws each window natively ABOVE home's surface: the app's own
// buffers (the display's mirror) plus a native frame and title bar (icon, title, minimise, full screen, close), as one
// layer stack - the user, 2026-10-30: "nobody asked for the cutoff" (the old page mask), widgets under a window are
// never altered. The page renders each window as an INVISIBLE element at its place (gesture exclusions, the body's
// touches to the app); the host moves, resizes and scales the window itself under the finger (title bar, edges, two
// fingers) and tells this file where it ended ("webwindows.moved"), so the bar and the content can't lag each other.
import { signal } from "@preact/signals";
import { useRef } from "preact/hooks";
import { native, nextFrameId, send } from "../apps/port.ts";
import { powos } from "../bridge.ts";
import { wideHome } from "../hosts/wide.ts";

const TITLE = 36;
const RADIUS = 12;

export interface WebWin {
  id: number;
  key: string;
  label: string;
  /** The home page (its number, as pages lists them) it's pinned to. */
  page: number;
  /** Its frame in the page, CSS px. */
  x: number;
  y: number;
  w: number;
  h: number;
  /** Two fingers on its bar or edge zoom the whole window (the host's layer matrix; the app keeps its resolution). */
  scale?: number;
  /** Off its page, in the dock (a tap on the dock icon brings it back: openWebWindow). */
  minimised?: boolean;
  /** Filling the work area (above the dock); the frame to go back to. */
  restore?: { x: number; y: number; w: number; h: number };
}

/** Bottom first: the last one is on top. */
export const webWins = signal<WebWin[]>([]);

let checkedAt = 0;
let on = false;

async function enabled(): Promise<boolean> {
  const ww = powos.webwindows;
  if (!ww) return false;
  if (Date.now() - checkedAt > 5000) {
    on = await ww.enabled().catch(() => false);
    checkedAt = Date.now();
  }
  return on;
}

/** Opens an Android app as a home element on [page] (unfolded, the setting on): false leaves the launch to the caller. */
export async function openWebWindow(key: string, label: string, page: number): Promise<boolean> {
  if (!wideHome.value || !key.startsWith("a:") || !(await enabled())) return false;
  // Already a window: it comes to this page, on top - never a second display for the same app (its task would move).
  const open = webWins.value.find((w) => w.key === key);
  if (open) {
    update(open.id, { page, minimised: false });
    raise(open.id);
    return true;
  }
  const n = webWins.value.length;
  const w = Math.round(innerWidth * 0.5);
  const h = Math.round(innerHeight * 0.6);
  const x = 48 + 32 * (n % 6);
  const y = 72 + 32 * (n % 6);
  // Its first rect is a guess; the element reports its real one on its first frame.
  const id = await powos.webwindows!.open(key, { left: x, top: y + TITLE, width: w, height: h - TITLE }).catch(() => -1);
  if (id < 0) return false;
  webWins.value = [...webWins.value, { id, key, label, page, x, y, w, h }];
  return true;
}

/** The pointer kept by its element (a synthetic or already-ended pointer can't be: the drag still works). */
function capture(e: PointerEvent) {
  try {
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
  } catch {}
}

export function update(id: number, change: Partial<WebWin>) {
  webWins.value = webWins.value.map((w) => (w.id === id ? { ...w, ...change } : w));
}

export function raise(id: number) {
  const list = webWins.value;
  if (list[list.length - 1]?.id === id) return;
  const win = list.find((w) => w.id === id);
  if (!win) return;
  webWins.value = [...list.filter((w) => w.id !== id), win];
}

powos.on("webwindows.closed", (id: number) => {
  webWins.value = webWins.value.filter((w) => w.id !== id);
});

// ---- the work area, and the host's events ----------------------------------------------------------------------------

/**
 * Where windows may be, viewport CSS px: the screen above home's foot (the dock and the bar - windows never cover
 * them, a desktop's reserved dock strip). Maximise fills it; the host clamps moves and resizes to it and crops a window
 * at its bottom.
 */
export function workArea(): { left: number; top: number; right: number; bottom: number } {
  let bottom = innerHeight;
  for (const el of document.querySelectorAll<HTMLElement>(".home > .dock, .home > .bar")) {
    const r = el.getBoundingClientRect();
    if (r.height > 0 && r.top > innerHeight / 2) bottom = Math.min(bottom, r.top);
  }
  return { left: 0, top: 0, right: innerWidth, bottom };
}

/** The page element's top left on screen (windows are page-local): the page on screen's. */
function pageOrigin(): { x: number; y: number } {
  const r = document.querySelector(".page:not(.away)")?.getBoundingClientRect();
  return r ? { x: r.left, y: r.top } : { x: 0, y: 0 };
}

/** Fills the work area, or goes back to where it was. */
export function toggleMaximise(id: number) {
  const w = webWins.value.find((v) => v.id === id);
  if (!w) return;
  if (w.restore) return update(id, { ...w.restore, restore: undefined });
  const a = workArea();
  const o = pageOrigin();
  update(id, { x: a.left - o.x, y: a.top - o.y, w: a.right - a.left, h: a.bottom - a.top, scale: 1, restore: { x: w.x, y: w.y, w: w.w, h: w.h } });
  raise(id);
}

export function minimise(id: number) {
  update(id, { minimised: true });
}

/** The host's move/resize/zoom under the finger ended (CSS px deltas): the model takes the place it left the window at. */
powos.on("webwindows.moved", (m: { id: number; dx: number; dy: number; dw?: number; dh?: number; scale?: number }) => {
  const w = webWins.value.find((v) => v.id === m.id);
  if (!w) return;
  const moved = m.dx !== 0 || m.dy !== 0 || !!m.dw || !!m.dh;
  update(m.id, {
    x: w.x + m.dx,
    y: w.y + m.dy,
    w: w.w + (m.dw ?? 0),
    h: w.h + (m.dh ?? 0),
    scale: m.scale ?? w.scale,
    // Moved or resized out of its maximised frame: a free window again (its size kept), as Android's.
    restore: moved ? undefined : w.restore,
  });
});
/** A press on its native bar or edge: on top. */
powos.on("webwindows.raise", (id: number) => raise(id));
/** Its bar's minimise / full screen buttons, or a double tap on the bar. */
powos.on("webwindows.control", (m: { id: number; action: string }) => {
  if (m.action === "minimise") minimise(m.id);
  else if (m.action === "maximise") toggleMaximise(m.id);
});

/** The windows pinned to home page [page] (not minimised): invisible elements in that page, so they move with it. */
export function WebWindowsOn({ page }: { page: number }) {
  const here = webWins.value.filter((w) => w.page === page && !w.minimised);
  if (!here.length) return null;
  return (
    <>
      {here.map((w) => (
        <WebWindowEl key={w.id} win={w} z={webWins.value.indexOf(w)} />
      ))}
    </>
  );
}

// ---- geometry to the host ----------------------------------------------------------------------------------------------

const px = (v: number) => (Math.round(v * 100) / 100).toString();
let lastGeometry = "";
let lastArea = "";
let lastTheme = "";
let themeAt = 0;
let raf = 0;

const onScreen = (left: number, top: number, w: number, h: number) => w > 0 && h > 0 && left + w > 0 && left < innerWidth && top + h > 0 && top < innerHeight;

/**
 * One window's entry, or null (its page isn't in the DOM): "<id> <frame x y w h> <body x y w h> <radius> <visible>
 * <scale> <maximised>", viewport CSS px. The frame's place is measured (a page swipe moves it); its size is the
 * model's, unscaled (the host scales the layer; the app's display stays at the body's real size).
 */
function entry(w: WebWin): string | null {
  const el = document.querySelector<HTMLElement>(`.webwindow[data-wwid="${w.id}"]`);
  if (!el) return null;
  const r = el.getBoundingClientRect();
  const s = w.scale ?? 1;
  const frame = `${px(r.left)} ${px(r.top)} ${px(w.w)} ${px(w.h)}`;
  const body = `${px(r.left)} ${px(r.top + TITLE)} ${px(w.w)} ${px(Math.max(1, w.h - TITLE))}`;
  return `${w.id} ${frame} ${body} ${RADIUS} ${onScreen(r.left, r.top, w.w * s, w.h * s) ? 1 : 0} ${px(s)} ${w.restore ? 1 : 0}`;
}

function geometry(): string {
  const parts = webWins.value.map(entry).filter((e): e is string => e != null);
  return [devicePixelRatio, parts.length, ...parts].join(" ");
}

/** "r g b a" of a CSS colour, as the page resolves it. */
function rgba(css: string): string {
  const probe = document.createElement("i");
  probe.style.color = css;
  document.body.append(probe);
  const c = getComputedStyle(probe).color;
  probe.remove();
  const n = c.match(/[\d.]+/g)?.map(Number) ?? [0, 0, 0];
  return `${n[0]} ${n[1]} ${n[2]} ${n[3] ?? 1}`;
}

/** The host's bar in the page's colours ("w.theme <bg r g b a> <fg r g b a>"): checked at most once a second. */
function theme() {
  if (performance.now() - themeAt < 1000) return;
  themeAt = performance.now();
  const t = `${rgba("var(--color-surface)")} ${rgba("var(--color-foreground)")}`;
  if (t !== lastTheme) send(`w.theme ${(lastTheme = t)}`);
}

/** Each frame while there are windows: the work area, then their geometry tagged with this page frame, when changed. */
function tick() {
  raf = 0;
  if (!native.value) return;
  theme();
  const a = workArea();
  const area = `${devicePixelRatio} ${px(a.left)} ${px(a.top)} ${px(a.right)} ${px(a.bottom)}`;
  if (area !== lastArea) send(`w.area ${(lastArea = area)}`);
  const g = geometry();
  if (g !== lastGeometry) {
    lastGeometry = g;
    const id = nextFrameId();
    console.timeStamp(`ww f${id}`);
    send(`w.f ${id} ${g}`);
  }
  if (webWins.value.length) raf = requestAnimationFrame(tick);
}

function kick() {
  if (!raf) raf = requestAnimationFrame(tick);
}
webWins.subscribe(kick);
// A new port (the page reloaded or the host came back): its layers know nothing yet.
native.subscribe(() => {
  lastGeometry = lastArea = lastTheme = "";
  themeAt = 0;
  kick();
});

/**
 * Its title bar's place: invisible, the host draws the bar and takes its touches (moves, buttons). With no host (the
 * browser gate, a page without the native port) it moves the model itself.
 */
function TitleBar({ win }: { win: WebWin }) {
  const drag = useRef<{ px: number; py: number; x: number; y: number } | null>(null);
  const up = (e: PointerEvent) => {
    e.stopPropagation();
    drag.current = null;
  };
  return (
    <div
      class="webwindow-title"
      style={{ height: `${TITLE}px`, flex: `0 0 ${TITLE}px`, touchAction: "none" }}
      onPointerDown={(e) => {
        e.stopPropagation();
        raise(win.id);
        if (native.value) return;
        capture(e);
        drag.current = { px: e.clientX, py: e.clientY, x: win.x, y: win.y };
      }}
      onPointerMove={(e) => {
        const d = drag.current;
        if (!d) return;
        e.stopPropagation();
        update(win.id, { x: d.x + e.clientX - d.px, y: Math.max(0, d.y + e.clientY - d.py), restore: undefined });
      }}
      onPointerUp={up}
      onPointerCancel={up}
    />
  );
}

/** The app's place: its touches go to the app (mapped through the window's zoom). */
function Body({ win, body }: { win: WebWin; body: { current: HTMLDivElement | null } }) {
  const pressed = useRef(false);
  const send = (e: PointerEvent, action: "down" | "move" | "up" | "cancel") => {
    e.stopPropagation();
    const r = body.current?.getBoundingClientRect();
    const s = win.scale ?? 1;
    if (r) void powos.webwindows?.input(win.id, action, (e.clientX - r.left) / s, (e.clientY - r.top) / s);
  };
  const end = (e: PointerEvent, action: "up" | "cancel") => {
    pressed.current = false;
    send(e, action);
  };
  return (
    <div
      class="webwindow-body"
      ref={body}
      style={{ flex: 1, touchAction: "none" }}
      onPointerDown={(e) => {
        raise(win.id);
        capture(e);
        pressed.current = true;
        send(e, "down");
      }}
      onPointerMove={(e) => pressed.current && send(e, "move")}
      onPointerUp={(e) => end(e, "up")}
      onPointerCancel={(e) => end(e, "cancel")}
    />
  );
}

/** Invisible: the host draws the window above home; this keeps its place in the page (swipes, exclusions, touches). */
function WebWindowEl({ win, z }: { win: WebWin; z: number }) {
  const body = useRef<HTMLDivElement>(null);
  const s = win.scale ?? 1;
  const frame = {
    position: "absolute",
    left: `${win.x}px`,
    top: `${win.y}px`,
    width: `${win.w}px`,
    height: `${win.h}px`,
    transform: s === 1 ? undefined : `scale(${s})`,
    transformOrigin: "0 0",
    zIndex: 20 + z,
    display: "flex",
    flexDirection: "column",
  } as const;
  return (
    <div class="webwindow" data-wwid={win.id} style={frame}>
      <TitleBar win={win} />
      <Body win={win} body={body} />
    </div>
  );
}
