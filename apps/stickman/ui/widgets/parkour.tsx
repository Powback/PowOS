// The stickman's home widget: an island in the shell's one shared page (shell/ui/island.tsx) showing only the stage -
// robotsupremacy's trained stick figure running its parkour lessons, on the tile's own (themed) background. A tap opens
// the full page (http://robotsupremacy.pow/stickman) in the browser; a tap on the top-right corner cycles the frame rate
// (10 / 15 / 30, 15 by default). On battery saver, or a low battery not charging, it rests on its last frame.
//
// The simulation and the drawing run in a worker (workers/sim.ts) on an OffscreenCanvas, so home's own thread does
// nothing per frame. The worker draws at most 30 frames a second, and only while this side says the tile is on screen
// (host.useOnScreen: the tile in the viewport, home's page shown, nothing of the shell's over it) and its heartbeat
// - a requestAnimationFrame a second, which a WebView that isn't drawn never gets, whatever it says about being
// visible - keeps coming. Off screen there's no timer, no physics step and no draw at all.
import { useEffect, useRef, useState } from "preact/hooks";

type Host = import("../../../../shell/apps/stdb.ts").IslandHost;

const FULL_PAGE = "http://robotsupremacy.pow/stickman";
// Frame rate: a widget setting (a tap on the tile's top-right corner cycles it), 15 by default - the WebView redraws
// home for every frame the canvas commits, so this is most of what the tile costs (see the report in git: ~2% of a core
// per fps on the OnePlus Open).
const RATES = [10, 15, 30];
const FPS_KEY = "dev.powos.stickman.fps";
const loadFps = () => {
  try {
    const n = Number(localStorage.getItem(FPS_KEY));
    return RATES.includes(n) ? n : 15;
  } catch {
    return 15;
  }
};
const CORNER = 44; // px: the top-right corner that cycles the rate instead of opening the page
// Battery: it rests (the last frame stays) on battery saver, or under LOW % while not charging. Read when the tile comes
// on screen and every POWER_MS while it stays there - nothing at all while it's off screen.
const LOW = 20;
const POWER_MS = 60_000;
const TAP_MS = 400;
const SLOP = 10;

/** A CSS colour as #rrggbb (what the native surface's Color.parseColor reads, and canvas too). */
let probe: CanvasRenderingContext2D | null = null;
function hex(c: string) {
  probe ??= document.createElement("canvas").getContext("2d");
  if (!probe) return c;
  probe.fillStyle = "#000";
  probe.fillStyle = c;
  const v = String(probe.fillStyle);
  const m = v.match(/^rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?\)$/);
  if (!m) return v;
  const h = (n: number) => Math.round(n).toString(16).padStart(2, "0");
  return `#${h(+m[1])}${h(+m[2])}${h(+m[3])}`; // (opaque: every ink is drawn solid; the card's alpha is its own)
}
function themeColors(el: Element) {
  const s = getComputedStyle(el);
  const v = (name: string, fallback: string) => hex(s.getPropertyValue(name).trim() || fallback);
  // the card's own fill (the home tiles' glass: the background at --glass), for the native surface to draw itself
  const glass = parseFloat(s.getPropertyValue("--glass")) / 100;
  return {
    fg: v("--color-foreground", "#ddd"),
    muted: v("--color-muted", "#888"),
    accent: v("--color-accent", "#e8a33d"),
    card: v("--color-background", "#1e1e2e"),
    cardAlpha: Number.isFinite(glass) ? glass : 0.72,
  };
}

/** On screen: the tile in the viewport and the page visible (the host's own signal adds home's covers). */
function useOnScreenFallback(ref: { current: Element | null }) {
  const [inView, setInView] = useState(false);
  const [shown, setShown] = useState(!document.hidden);
  useEffect(() => {
    const io = new IntersectionObserver((e) => setInView(e[e.length - 1].isIntersecting));
    if (ref.current) io.observe(ref.current);
    const vis = () => setShown(!document.hidden);
    document.addEventListener("visibilitychange", vis);
    return () => {
      io.disconnect();
      document.removeEventListener("visibilitychange", vis);
    };
  }, []);
  return inView && shown;
}

/** Laid-out size (no transforms), for a shell without host.useLayoutSize. */
function useLayoutSizeFallback(ref: { current: HTMLElement | null }) {
  const [size, setSize] = useState({ width: 0, height: 0 });
  useEffect(() => {
    const el = ref.current!;
    const m = () => setSize((s) => (s.width === el.clientWidth && s.height === el.clientHeight ? s : { width: el.clientWidth, height: el.clientHeight }));
    const ro = new ResizeObserver(m);
    ro.observe(el);
    m();
    return () => ro.disconnect();
  }, []);
  return size;
}

export default function Parkour({ host, base }: { host: Host; base: string; cells: [number, number] }) {
  const box = useRef<HTMLDivElement>(null);
  const canvas = useRef<HTMLCanvasElement>(null);
  const worker = useRef<Worker | null>(null);
  const [state, setState] = useState<{ status: "idle" | "loading" | "ready" | "error"; text?: string }>({ status: "idle" });
  // (a shell without the host's signal: the tile's own view of it)
  const onScreen = host.useOnScreen ? host.useOnScreen(box) : useOnScreenFallback(box);
  const size = host.useLayoutSize ? host.useLayoutSize(box) : useLayoutSizeFallback(box);
  const [fps, setFps] = useState(loadFps);
  const [flash, setFlash] = useState<string | null>(null);
  const [resting, setResting] = useState<string | null>(null);

  // The battery, while on screen.
  useEffect(() => {
    if (!onScreen || !host.power) return;
    let live = true;
    const check = () =>
      host.power!().then(
        (p) => {
          if (!live) return;
          const why = p.saver ? "battery saver" : p.level != null && p.level < LOW && !p.charging ? `battery ${p.level}%` : null;
          setResting(why);
        },
        () => {},
      );
    check();
    const t = window.setInterval(check, POWER_MS);
    return () => {
      live = false;
      clearInterval(t);
    };
  }, [onScreen]);
  const running = onScreen && !resting;
  // A native surface under the page while the tile is on screen and home is still (a shell/APK without one: null, and
  // the worker draws on its canvas as before). It keeps its last frame while resting on a low battery.
  // The surface covers the whole card (the tile around this island), and draws the card's fill itself: the page's card
  // goes see-through over it while it's up - otherwise the page's glass would tint everything under it.
  const cardEl = useRef<HTMLElement | null>(null);
  useEffect(() => void (cardEl.current = box.current?.parentElement ?? null), []);
  const surface = host.useSurface ? host.useSurface(cardEl, onScreen && state.status === "ready") : null;
  const toNative = !!surface?.native;
  const surfaceRef = useRef(surface);
  surfaceRef.current = surface;
  useEffect(() => {
    const w = worker.current, c = cardEl.current, b = box.current;
    if (!w || !c || !b) return;
    if (toNative) {
      const cr = c.getBoundingClientRect(), br = b.getBoundingClientRect();
      w.postMessage({
        type: "card",
        card: { w: cr.width, h: cr.height, x: br.left - cr.left, y: br.top - cr.top, r: parseFloat(getComputedStyle(c).borderTopLeftRadius) || 0 },
      });
      c.style.background = "transparent";
    }
    w.postMessage({ type: "target", native: toNative });
    return () => void (c.style.background = "");
  }, [toNative, state.status, size.width, size.height]);

  // The worker, made the first time the tile is on screen (its 11 MB of MuJoCo isn't loaded for a tile never seen) and
  // kept while the tile is on home.
  useEffect(() => {
    if (!onScreen || worker.current || !canvas.current || !box.current || !size.width || !size.height) return;
    const w = new Worker(new URL(`${base}workers/sim.js`, location.href), { type: "module" });
    worker.current = w;
    (globalThis as any).__stickman = w; // for checks over CDP (postMessage({ type: "stats" }))
    setState({ status: "loading" });
    w.addEventListener("message", (e) => {
      if (e.data.type === "frame") surfaceRef.current?.draw(e.data.frame);
      else if (e.data.type === "ready") setState({ status: "ready", text: e.data.brain });
      else if (e.data.type === "error") setState({ status: "error", text: e.data.message });
    });
    w.addEventListener("error", (e) => setState({ status: "error", text: e.message || "the simulation failed to start" }));
    const off = canvas.current.transferControlToOffscreen();
    w.postMessage(
      { type: "init", canvas: off, base: new URL(base, location.href).href, colors: themeColors(box.current), width: size.width, height: size.height, dpr: devicePixelRatio, fps },
      [off],
    );
  }, [onScreen, size.width, size.height]);
  useEffect(() => () => worker.current?.terminate(), []);

  // Its size to the worker whenever the layout gives it a new one, and again each time it comes on screen (after a
  // reload or a clear-all home comes back mid-animation): the bitmap is resized and redrawn whole, from transparent.
  useEffect(() => {
    if (size.width && size.height) worker.current?.postMessage({ type: "size", width: size.width, height: size.height, dpr: devicePixelRatio });
  }, [size.width, size.height, onScreen, state.status]);

  // The theme's colours as they change (the shell sets them on the root's style).
  useEffect(() => {
    const el = box.current!;
    let last = "";
    const mo = new MutationObserver(() => {
      const c = themeColors(el);
      const k = JSON.stringify(c);
      if (k !== last) worker.current?.postMessage({ type: "colors", colors: c });
      last = k;
    });
    mo.observe(document.documentElement, { attributes: true, attributeFilter: ["style", "class"] });
    return () => mo.disconnect();
  }, []);

  // Frames on while the tile is on screen, off otherwise. The worker paces itself (at most FPS, on a timer) and
  // schedules nothing at all while off; while on, a heartbeat from this page's requestAnimationFrame - once a second -
  // tells it the WebView is really being drawn (a hidden one can say it's visible, but gets no frames).
  useEffect(() => {
    const w = worker.current;
    if (!w) return;
    w.postMessage({ type: "run", on: running, fps });
    if (!running) return;
    w.postMessage({ type: "colors", colors: themeColors(box.current!) });
    let timer = 0, raf = 0;
    const beat = () => {
      raf = 0;
      w.postMessage({ type: "alive" });
      timer = window.setTimeout(() => (raf = requestAnimationFrame(beat)), 1000);
    };
    beat();
    return () => {
      clearTimeout(timer);
      if (raf) cancelAnimationFrame(raf);
    };
  }, [running, fps, state.status]);

  const cycleFps = () => {
    const next = RATES[(RATES.indexOf(fps) + 1) % RATES.length];
    try {
      localStorage.setItem(FPS_KEY, String(next));
    } catch {}
    setFps(next);
    setFlash(`${next} fps`);
    window.setTimeout(() => setFlash(null), 1500);
  };

  // A tap (not the long press that lifts the tile, not a swipe) opens the full page.
  const down = useRef<{ x: number; y: number; t: number } | null>(null);
  const open = () => (host.openUrl ? host.openUrl(FULL_PAGE) : window.open(FULL_PAGE, "_blank"));
  return (
    <div
      ref={box}
      style={{ position: "relative", width: "100%", height: "100%", cursor: "pointer" }}
      onPointerDown={(e) => (down.current = { x: e.clientX, y: e.clientY, t: performance.now() })}
      onPointerUp={(e) => {
        const d = down.current;
        down.current = null;
        if (!d || performance.now() - d.t >= TAP_MS || Math.hypot(e.clientX - d.x, e.clientY - d.y) >= SLOP) return;
        const r = box.current!.getBoundingClientRect();
        if (e.clientX > r.right - CORNER && e.clientY < r.top + CORNER) cycleFps();
        else open();
      }}
      onPointerCancel={() => (down.current = null)}
    >
      <canvas ref={canvas} style={{ position: "absolute", inset: 0, width: "100%", height: "100%", display: "block" }} />
      {state.status === "ready" && (flash || resting) && (
        <div style={{ position: "absolute", right: "8px", bottom: "6px", fontSize: "0.7em", opacity: 0.55, pointerEvents: "none" }}>
          {flash ?? `paused: ${resting}`}
        </div>
      )}
      {state.status !== "ready" && (
        <div
          style={{
            position: "absolute",
            inset: 0,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            padding: "8px 12px",
            textAlign: "center",
            fontSize: "0.8em",
            opacity: 0.6,
          }}
        >
          {state.status === "error" ? `stickman: ${state.text}` : "stickman…"}
        </div>
      )}
    </div>
  );
}
