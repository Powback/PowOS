/**
 * The glasses' screen (index.html?mode=glasses): a page the app loads off screen while the glasses are up
 * (glasses/Glasses.kt), drawing what they show - the glasses app picked (the built-in HUD, glasses/hud.tsx, or a
 * PowOS app's "glasses" entry) at the glasses' canvas size - and pushing it to them when it changed:
 *
 * - text mode (the G2, unless its unverified picture path is on): the page's text, through the glasses' own text
 *   rendering;
 * - image mode (the G1; the G2 with "g2Raster"): the page's pixels (frame.ts), sent only when they differ at the
 *   glasses' depth;
 * - at most one frame per the glasses' own pace (frame.ts Pacer), the newest winning; nothing sent while unchanged.
 *
 * Input from the glasses goes to the app (api.ts). `powos glasses show` messages show over it until a tap or their
 * time is up. In a desktop browser (the mock) it shows the frame on screen, keys standing in for the touch bars;
 * ?preview=1 (the phone's glasses screen shows it in a frame) draws without pushing.
 */
import { signal } from "@preact/signals";
import type { ComponentType } from "preact";
import { useEffect, useRef, useState } from "preact/hooks";
import { powos } from "../bridge.ts";
import type { GlassesState } from "../types.ts";
import { appRev } from "../apps/pages.ts";
import { type GlassesApi, type GlassesInputName, dispatchInput, useGlassesInput, view, wrap } from "./api.ts";
import { type Canvas, type FrameMode, Pacer, gapFor, rasterize, sameLevels, textGrid, textOf } from "./frame.ts";
import Hud from "./hud.tsx";

declare function importShim(url: string): Promise<{ default: ComponentType<any>; prefers?: FrameMode }>;

const preview = new URLSearchParams(location.search).has("preview");
const state = signal<GlassesState | null>(null);

/** The glasses app to show (store "glasses": { app, entry, version } - picked on the phone's glasses screen). */
interface Pick {
  app?: string;
  entry?: string;
  version?: string;
}

function canvasOf(s: GlassesState | null): Canvas {
  return s?.canvas ?? { width: 576, height: 288, bits: 4 };
}

function modeOf(s: GlassesState | null, prefers?: FrameMode): FrameMode {
  if (prefers === "text") return "text";
  return s?.image.usable ? "image" : "text";
}

export const api: GlassesApi = {
  get view() {
    return view.value;
  },
  live: !preview,
  useInput: useGlassesInput,
};

export function GlassesSurface() {
  const root = useRef<HTMLDivElement>(null);
  const [message, setMessage] = useState<{ text: string; until: number } | null>(null);

  // The host's state, and this page as the glasses' screen.
  useEffect(() => {
    const set = (s: GlassesState) => (state.value = s);
    powos.glasses.state().then(set, () => {});
    if (!preview) powos.glasses.surface(true).catch(() => {});
    const offs = [
      powos.on("glasses.state", set),
      powos.on("glasses.input", ({ input }: { input: GlassesInputName }) => {
        // A tap takes a message away first.
        if (input === "click" && messageRef.current) return setMessage(null);
        dispatchInput(input);
      }),
      powos.on("glasses.message", ({ text, seconds }: { text: string; seconds: number }) =>
        setMessage({ text, until: Date.now() + (seconds || 30) * 1000 }),
      ),
    ];
    // A desktop browser: keys for the touch bars.
    const key = (e: KeyboardEvent) => {
      const i = { Enter: "click", " ": "double", ArrowUp: "up", ArrowDown: "down" }[e.key];
      if (i) {
        e.preventDefault();
        if (i === "click" && messageRef.current) return setMessage(null);
        dispatchInput(i);
      }
    };
    addEventListener("keydown", key);
    return () => {
      offs.forEach((o) => o());
      removeEventListener("keydown", key);
      if (!preview) powos.glasses.surface(false).catch(() => {});
    };
  }, []);

  const messageRef = useRef(message);
  messageRef.current = message;
  useEffect(() => {
    if (!message) return;
    const t = window.setTimeout(() => setMessage(null), Math.max(0, message.until - Date.now()));
    return () => clearTimeout(t);
  }, [message]);

  const App = useGlassesApp();

  // The view the app draws for.
  const s = state.value;
  const c = canvasOf(s);
  const mode = modeOf(s, App?.prefers);
  const grid = textGrid(c);
  useEffect(() => {
    view.value = { model: s?.paired?.model ?? null, width: c.width, height: c.height, bits: c.bits, mode, cols: grid.cols, rows: grid.rows };
  }, [s?.paired?.model, c.width, c.height, c.bits, mode]);

  // Frames: on every change of what's drawn, the newest goes out at the glasses' pace.
  usePush(root, c, mode, s);

  const M = App?.c;
  return (
    <div class={`glasses-surface ${preview ? "preview" : ""}`}>
      <div ref={root} class="glasses-root" style={{ width: `${c.width}px`, height: `${c.height}px` }}>
        {message ? <Message text={message.text} /> : M ? <M glasses={api} host={App?.host} /> : null}
      </div>
      {!preview && powos.host === "mock" && (
        <p class="glasses-dev">
          {s?.paired?.model ?? "?"} {c.width}x{c.height} {mode} - Enter: tap, Space: double tap, arrows: scroll
        </p>
      )}
    </div>
  );
}

/**
 * The glasses app to show: a PowOS app's "glasses" entry when one is picked (store "glasses"; re-imported when its
 * files change, or when the phone's glasses screen picks another: "glasses.reload"), else the built-in HUD. A PowOS app
 * gets the same host as its page (apps/stdb.ts), loaded only then - the HUD's page doesn't need SpacetimeDB.
 */
export function useGlassesApp() {
  const [app, setApp] = useState<{ c: ComponentType<any>; prefers?: FrameMode; host?: unknown } | null>(null);
  const [asked, setAsked] = useState(0);
  useEffect(() => powos.on("glasses.reload", () => setAsked((n) => n + 1)), []);
  const rev = appRev.value;
  useEffect(() => {
    let live = true;
    const hud = () => live && setApp({ c: Hud });
    powos.store.get<Pick>("glasses").then(async (p) => {
      if (!live) return;
      if (!p?.app || !p.entry) return hud();
      try {
        const url = `./_app/${p.app}/${p.entry}?v=${encodeURIComponent(p.version ?? "")}&r=${appRev.value[p.app] ?? 0}`;
        const [m, { host }] = await Promise.all([importShim(url), import("../apps/stdb.ts")]);
        if (live) setApp({ c: m.default, prefers: m.prefers, host });
      } catch (e) {
        console.error("[glasses] app didn't load, showing the HUD", e);
        hud();
      }
    }, hud);
    return () => void (live = false);
  }, [rev, asked]);
  return app;
}

function Message({ text }: { text: string }) {
  const v = view.value;
  const size = Math.floor((v.height / v.rows) * 0.78);
  return (
    <div class="glasses-hud" style={{ fontSize: `${size}px`, lineHeight: `${Math.floor(v.height / v.rows)}px`, padding: "0 6px" }}>
      {wrap(text, v.cols).map((l, i) => (
        <div key={i} class="glasses-line">
          {l || " "}
        </div>
      ))}
    </div>
  );
}

/** Watches [root] and pushes its frames: its text or its pixels, only when changed, paced. */
function usePush(root: { current: HTMLDivElement | null }, c: Canvas, mode: FrameMode, s: GlassesState | null) {
  const ref = useRef({ c, mode, ready: false });
  ref.current.c = c;
  ref.current.mode = mode;
  const last = useRef<{ text: string | null; levels: Uint8Array | null }>({ text: null, levels: null });
  const pacer = useRef(new Pacer(() => gapFor(ref.current.mode, ref.current.c)));
  const ready = s?.phase === "ready" && s.shown !== false;

  // Back (reconnected, on the face again) or a new mode: the next frame goes whether or not it changed.
  useEffect(() => {
    ref.current.ready = ready;
    last.current = { text: null, levels: null };
    if (ready) schedule();
  }, [ready, mode, c.width, c.height, c.bits]);

  const timer = useRef(0);
  const schedule = () => {
    clearTimeout(timer.current);
    timer.current = window.setTimeout(frame, 60);
  };

  const frame = async () => {
    const el = root.current;
    if (!el || preview || !ref.current.ready) return;
    const { c, mode } = ref.current;
    if (mode === "text") {
      const text = textOf(el) || " ";
      if (text === last.current.text) return;
      last.current.text = text;
      pacer.current.push(() => powos.glasses.showText(text));
    } else {
      const f = await rasterize(el, c);
      if (!f) {
        // Couldn't draw it: its text instead.
        const text = textOf(el) || " ";
        if (text === last.current.text) return;
        last.current.text = text;
        pacer.current.push(() => powos.glasses.showText(text));
        return;
      }
      if (sameLevels(f.levels, last.current.levels)) return;
      last.current.levels = f.levels;
      pacer.current.push(() => powos.glasses.showImage(f.png, c.bits === 1 ? false : true));
    }
  };

  useEffect(() => {
    const el = root.current;
    if (!el) return;
    const obs = new MutationObserver(schedule);
    obs.observe(el, { subtree: true, childList: true, characterData: true, attributes: true });
    schedule();
    return () => obs.disconnect();
  }, []);
}
