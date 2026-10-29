// Web windows: an Android app's window as an element of home (unfolded; off unless Settings.Global
// powos_web_windows = 1). The user, 2026-10-29: "the powos home typescript should deal with the windows and their
// content", "it should be pinned to a page properly natively". So the window is this page's: its page, position,
// size, z-order (DOM order) and title bar live here; the host (WebWindows.kt) only draws the app's own display behind
// the WebView at the body's rect, which this file reports every frame it changes. The body is an unpainted hole:
// whatever home paints over it (drawer, panels, another window's title bar) covers the app, as DOM does.
import { signal } from "@preact/signals";
import { useEffect, useRef } from "preact/hooks";
import { powos } from "../bridge.ts";
import { wideHome } from "../hosts/wide.ts";
import type { WebWindowRect } from "../types.ts";

const TITLE = 36;

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

function update(id: number, change: Partial<WebWin>) {
  webWins.value = webWins.value.map((w) => (w.id === id ? { ...w, ...change } : w));
}

function raise(id: number) {
  const list = webWins.value;
  if (list[list.length - 1]?.id === id) return;
  const win = list.find((w) => w.id === id);
  if (!win) return;
  webWins.value = [...list.filter((w) => w.id !== id), win];
  void powos.webwindows?.raise(id);
}

powos.on("webwindows.closed", (id: number) => {
  webWins.value = webWins.value.filter((w) => w.id !== id);
});

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

/** The body's rect to the host each frame it changed (a drag, a page swipe, a resize, out of sight). */
function usePlace(win: WebWin, body: { current: HTMLDivElement | null }) {
  useEffect(() => {
    let last = "";
    let raf = 0;
    const tick = () => {
      const el = body.current;
      if (el) {
        const r = el.getBoundingClientRect();
        const visible = r.width > 0 && r.right > 0 && r.left < innerWidth && r.bottom > 0 && r.top < innerHeight;
        const rect: WebWindowRect = { left: Math.round(r.left), top: Math.round(r.top), width: Math.round(r.width), height: Math.round(r.height) };
        const s = `${rect.left},${rect.top},${rect.width},${rect.height},${visible}`;
        if (s !== last) {
          last = s;
          void powos.webwindows?.place(win.id, rect, visible);
        }
      }
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => {
      cancelAnimationFrame(raf);
      // Its page gone from the DOM: out of sight until it's shown again.
      void powos.webwindows?.place(win.id, { left: 0, top: 0, width: win.w, height: win.h - TITLE }, false);
    };
  }, [win.id]);
}

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
        (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
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
        (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
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
  usePlace(win, body);
  const frame = {
    position: "absolute",
    left: `${win.x}px`,
    top: `${win.y}px`,
    width: `${win.w}px`,
    height: `${win.h}px`,
    zIndex: 20 + z,
    display: "flex",
    flexDirection: "column",
    borderRadius: "12px",
    overflow: "hidden",
    boxShadow: "0 0 0 1px var(--color-border)",
  } as const;
  return (
    <div class="webwindow" style={frame}>
      <TitleBar win={win} />
      <Body win={win} body={body} />
    </div>
  );
}
