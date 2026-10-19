// The stickman's home widget: an island in the shell's one shared page (shell/ui/island.tsx) showing only the stage -
// robotsupremacy's trained stick figure running its parkour lessons, on the tile's own (themed) background. A tap opens
// the full page (http://robotsupremacy.pow/stickman) in the browser.
//
// The simulation and the drawing run in a worker (workers/sim.ts) on an OffscreenCanvas, so home's own thread does
// nothing per frame. The worker draws at most 30 frames a second, and only while this side says the tile is on screen
// (host.useOnScreen: the tile in the viewport, home's page shown, nothing of the shell's over it) and its heartbeat
// - a requestAnimationFrame a second, which a WebView that isn't drawn never gets, whatever it says about being
// visible - keeps coming. Off screen there's no timer, no physics step and no draw at all.
import { useEffect, useRef, useState } from "preact/hooks";

type Host = import("../../../../shell/apps/stdb.ts").IslandHost;

const FULL_PAGE = "http://robotsupremacy.pow/stickman";
const FPS = 30;
const TAP_MS = 400;
const SLOP = 10;

function themeColors(el: Element) {
  const s = getComputedStyle(el);
  const v = (name: string, fallback: string) => s.getPropertyValue(name).trim() || fallback;
  return { fg: v("--color-foreground", "#ddd"), muted: v("--color-muted", "#888"), accent: v("--color-accent", "#e8a33d") };
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

export default function Parkour({ host, base }: { host: Host; base: string; cells: [number, number] }) {
  const box = useRef<HTMLDivElement>(null);
  const canvas = useRef<HTMLCanvasElement>(null);
  const worker = useRef<Worker | null>(null);
  const [state, setState] = useState<{ status: "idle" | "loading" | "ready" | "error"; text?: string }>({ status: "idle" });
  // (a shell without the host's signal: the tile's own view of it)
  const onScreen = host.useOnScreen ? host.useOnScreen(box) : useOnScreenFallback(box);

  // The worker, made the first time the tile is on screen (its 11 MB of MuJoCo isn't loaded for a tile never seen) and
  // kept while the tile is on home.
  useEffect(() => {
    if (!onScreen || worker.current || !canvas.current || !box.current) return;
    const r = box.current.getBoundingClientRect();
    const w = new Worker(new URL(`${base}workers/sim.js`, location.href), { type: "module" });
    worker.current = w;
    (globalThis as any).__stickman = w; // for checks over CDP (postMessage({ type: "stats" }))
    setState({ status: "loading" });
    w.addEventListener("message", (e) => {
      if (e.data.type === "ready") setState({ status: "ready", text: e.data.brain });
      else if (e.data.type === "error") setState({ status: "error", text: e.data.message });
    });
    w.addEventListener("error", (e) => setState({ status: "error", text: e.message || "the simulation failed to start" }));
    const off = canvas.current.transferControlToOffscreen();
    w.postMessage(
      { type: "init", canvas: off, base: new URL(base, location.href).href, colors: themeColors(box.current), width: r.width, height: r.height, dpr: devicePixelRatio, fps: FPS },
      [off],
    );
  }, [onScreen]);
  useEffect(() => () => worker.current?.terminate(), []);

  // The tile's size, and the theme's colours as they change (the shell sets them on the root's style).
  useEffect(() => {
    const el = box.current!;
    const ro = new ResizeObserver(([e]) => worker.current?.postMessage({ type: "size", width: e.contentRect.width, height: e.contentRect.height, dpr: devicePixelRatio }));
    ro.observe(el);
    let last = "";
    const mo = new MutationObserver(() => {
      const c = themeColors(el);
      const k = JSON.stringify(c);
      if (k !== last) worker.current?.postMessage({ type: "colors", colors: c });
      last = k;
    });
    mo.observe(document.documentElement, { attributes: true, attributeFilter: ["style", "class"] });
    return () => {
      ro.disconnect();
      mo.disconnect();
    };
  }, []);

  // Frames on while the tile is on screen, off otherwise. The worker paces itself (at most FPS, on a timer) and
  // schedules nothing at all while off; while on, a heartbeat from this page's requestAnimationFrame - once a second -
  // tells it the WebView is really being drawn (a hidden one can say it's visible, but gets no frames).
  useEffect(() => {
    const w = worker.current;
    if (!w) return;
    w.postMessage({ type: "run", on: onScreen });
    if (!onScreen) return;
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
  }, [onScreen, state.status]);

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
        if (d && performance.now() - d.t < TAP_MS && Math.hypot(e.clientX - d.x, e.clientY - d.y) < SLOP) open();
      }}
      onPointerCancel={() => (down.current = null)}
    >
      <canvas ref={canvas} style={{ position: "absolute", inset: 0, width: "100%", height: "100%", display: "block" }} />
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
