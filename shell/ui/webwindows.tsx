// Web windows: an Android app's window as an element of home (unfolded; off unless Settings.Global
// powos_web_windows = 1). The user, 2026-10-29: "the powos home typescript should deal with the windows and their
// content", "it should be pinned to a page properly natively". So the window is this page's: its page, position,
// size, z-order (DOM order) and title bar live here; the host (WebWindows.kt) composites the app's own display (its
// mirror: the app's buffers) under the page at the window, from the geometry this file sends over the native port
// every frame it changes ("w.f", frame-synced: content and chrome move on the same frame). The body is an unpainted
// hole: whatever home paints over it (drawer, panels, another window's title bar) covers the app, as DOM does.
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
    update(open.id, { page });
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

function update(id: number, change: Partial<WebWin>) {
  webWins.value = webWins.value.map((w) => (w.id === id ? { ...w, ...change } : w));
}

function raise(id: number) {
  const list = webWins.value;
  if (list[list.length - 1]?.id === id) return;
  const win = list.find((w) => w.id === id);
  if (!win) return;
  webWins.value = [...list.filter((w) => w.id !== id), win];
}

powos.on("webwindows.closed", (id: number) => {
  webWins.value = webWins.value.filter((w) => w.id !== id);
});

// ---- the page's content cut out under the windows ------------------------------------------------------------------

/**
 * The app's content is composited UNDER home's own pixels (WebWindows.kt: a child layer below home's buffer - the
 * zero-copy mirror, and everything home draws over a window covers it, as DOM does). So whatever the page paints where
 * a body is - a widget, an icon, a lower window's title bar - would paint over the app (the user, 2026-10-30: the
 * weather card and the "Mats's room" chip over Chrome). The page element is masked instead: transparent over every
 * window body, except where a higher window's title bar is (that's DOM over the lower app, as it should be). The dock,
 * bar, drawer and panels are outside the page element: never cut, always over the windows.
 *
 * The mask is a fold of layers (CSS mask-composite, bottom layer first): H = the holes, built bottom window up as
 * H = (H ∩ not-title-bar(i)) ∪ body(i); the page = everything minus H. Page-local CSS px from the windows' own state
 * (no measuring): it changes in the same render as the windows, on the same frame as their "w.f".
 */
const svg = (body: string) => `url("data:image/svg+xml,${encodeURIComponent(`<svg xmlns='http://www.w3.org/2000/svg' ${body}</svg>`)}")`;
const FAR = 20000;
/** A body: square top (the title bar is on it), rounded bottom corners as the window's. */
function bodyLayer(w: WebWin): string {
  const bh = Math.max(1, w.h - TITLE);
  const r = Math.min(RADIUS, w.w / 2, bh / 2);
  const path = `M0 0H${w.w}V${bh - r}A${r} ${r} 0 0 1 ${w.w - r} ${bh}H${r}A${r} ${r} 0 0 1 0 ${bh - r}Z`;
  return `${svg(`width='${w.w}' height='${bh}'><path d='${path}'/>`)} ${w.x}px ${w.y + TITLE}px / ${w.w}px ${bh}px no-repeat`;
}
/** Everything but a title bar (a big square with the bar cut out, from the page's top left). */
function notTitleLayer(w: WebWin): string {
  const path = `M0 0H${FAR}V${FAR}H0Z M${w.x} ${w.y}H${w.x + w.w}V${w.y + TITLE}H${w.x}Z`;
  return `${svg(`width='${FAR}' height='${FAR}'><path fill-rule='evenodd' d='${path}'/>`)} 0 0 / ${FAR}px ${FAR}px no-repeat`;
}

/** Page [page]'s element style: masked over its windows' bodies, or nothing (no windows there). */
export function pageMask(page: number): Record<string, string> | undefined {
  const here = webWins.value.filter((w) => w.page === page);
  if (!here.length) return undefined;
  // Bottom window first; listed top layer first, so built from the top window down.
  const layers: string[] = [];
  const ops: string[] = [];
  here.forEach((w, i) => {
    layers.unshift(bodyLayer(w));
    ops.unshift("add");
    if (i > 0) {
      layers.splice(1, 0, notTitleLayer(w));
      ops.splice(1, 0, "intersect");
    }
  });
  // The whole page (any opaque image: a mask reads only its alpha).
  const mask = [`linear-gradient(black, black)`, ...layers].join(", ");
  const composite = ["subtract", ...ops].join(", ");
  return { mask, maskComposite: composite };
}

/** The windows pinned to home page [page]: rendered inside that page's element, so they move with it. */
export function WebWindowsOn({ page }: { page: number }) {
  const here = webWins.value.filter((w) => w.page === page);
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
let raf = 0;

/**
 * This frame's windows, bottom first (DOM order = z): "<dpr> <n> [<id> <frame x y w h> <body x y w h> <radius>
 * <visible>]*n", CSS px of the viewport after transforms (a page swipe moves them). A window whose page isn't in the
 * DOM is left out: the host hides it (its layer, never its app).
 */
const onScreen = (b: DOMRect) => b.width > 0 && b.height > 0 && b.right > 0 && b.left < innerWidth && b.bottom > 0 && b.top < innerHeight;
const rect = (r: DOMRect) => `${px(r.left)} ${px(r.top)} ${px(r.width)} ${px(r.height)}`;

/** One window's entry, or null: its page isn't in the DOM. */
function entry(w: WebWin): string | null {
  const frame = document.querySelector<HTMLElement>(`.webwindow[data-wwid="${w.id}"]`);
  const body = frame?.querySelector<HTMLElement>(".webwindow-body");
  if (!frame || !body) return null;
  const b = body.getBoundingClientRect();
  return `${w.id} ${rect(frame.getBoundingClientRect())} ${rect(b)} ${RADIUS} ${onScreen(b) ? 1 : 0}`;
}

function geometry(): string {
  const parts = webWins.value.map(entry).filter((e): e is string => e != null);
  return [devicePixelRatio, parts.length, ...parts].join(" ");
}

/** Each frame while there are windows: their geometry, tagged with the page frame it was measured on, when it changed. */
function tick() {
  raf = 0;
  if (!native.value) return;
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
  lastGeometry = "";
  kick();
});

const titleStyle = {
  height: `${TITLE}px`,
  flex: `0 0 ${TITLE}px`,
  display: "flex",
  alignItems: "center",
  gap: "8px",
  padding: "0 6px 0 12px",
  background: "var(--color-surface)",
  color: "var(--color-foreground)",
  font: "var(--text-item) var(--font)",
  touchAction: "none",
};

/** Its title bar: the app's label and a close button; dragging it moves the frame in its page. */
function TitleBar({ win }: { win: WebWin }) {
  const drag = useRef<{ px: number; py: number; x: number; y: number } | null>(null);
  const up = (e: PointerEvent) => {
    e.stopPropagation();
    drag.current = null;
  };
  return (
    <div
      class="webwindow-title"
      style={titleStyle}
      onPointerDown={(e) => {
        e.stopPropagation();
        raise(win.id);
        capture(e);
        drag.current = { px: e.clientX, py: e.clientY, x: win.x, y: win.y };
      }}
      onPointerMove={(e) => {
        const d = drag.current;
        if (!d) return;
        e.stopPropagation();
        update(win.id, { x: d.x + e.clientX - d.px, y: Math.max(0, d.y + e.clientY - d.py) });
      }}
      onPointerUp={up}
      onPointerCancel={up}
    >
      <span style={{ flex: 1, overflow: "hidden", whiteSpace: "nowrap", textOverflow: "ellipsis" }}>{win.label}</span>
      <button
        class="webwindow-close"
        aria-label={`Close ${win.label}`}
        style={{ width: "28px", height: "28px", border: "none", borderRadius: "14px", background: "var(--soft-fill)", color: "inherit" }}
        onPointerDown={(e) => e.stopPropagation()}
        onClick={(e) => {
          e.stopPropagation();
          void powos.webwindows?.close(win.id);
        }}
      >
        ✕
      </button>
    </div>
  );
}

/** The hole: nothing painted, the app's display shows through from behind the WebView; its touches go to the app. */
function Body({ win, body }: { win: WebWin; body: { current: HTMLDivElement | null } }) {
  const pressed = useRef(false);
  const send = (e: PointerEvent, action: "down" | "move" | "up" | "cancel") => {
    e.stopPropagation();
    const r = body.current?.getBoundingClientRect();
    if (r) void powos.webwindows?.input(win.id, action, e.clientX - r.left, e.clientY - r.top);
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

function WebWindowEl({ win, z }: { win: WebWin; z: number }) {
  const body = useRef<HTMLDivElement>(null);
  const frame = {
    position: "absolute",
    left: `${win.x}px`,
    top: `${win.y}px`,
    width: `${win.w}px`,
    height: `${win.h}px`,
    zIndex: 20 + z,
    display: "flex",
    flexDirection: "column",
    borderRadius: `${RADIUS}px`,
    overflow: "hidden",
    boxShadow: "0 0 0 1px var(--color-border)",
  } as const;
  return (
    <div class="webwindow" data-wwid={win.id} style={frame}>
      <TitleBar win={win} />
      <Body win={win} body={body} />
    </div>
  );
}
