/**
 * The phone's glasses screen (the control center's glasses tile): pair the Even G2/G1, connect, see how they are, and
 * what they show - a live preview of the glasses' screen (the same app the glasses run, with its own tap / double tap /
 * scroll buttons), which app that is, a line of text to send, and the unverified G2 picture path's switch.
 */
import { useEffect, useState } from "preact/hooks";
import { powos } from "../bridge.ts";
import { installedApps, manifestOf } from "../apps/pages.ts";
import type { GlassesState } from "../types.ts";
import { closeGlasses, glassesOpen } from "../glasses/open.ts";
import { useGlassesApp } from "../glasses/surface.tsx";
import { type GlassesApi, dispatchInput, useGlassesInput, view } from "../glasses/api.ts";
import { textGrid } from "../glasses/frame.ts";

export function GlassesScreen() {
  return glassesOpen.value ? <Glasses /> : null;
}

/** Its touches are its own: home's swipes under it don't see them. */
const own = {
  onTouchStart: (e: TouchEvent) => e.stopPropagation(),
  onTouchMove: (e: TouchEvent) => e.stopPropagation(),
  onPointerDown: (e: PointerEvent) => e.stopPropagation(),
};

function Glasses() {
  const [st, setSt] = useState<GlassesState | null>(null);
  const [failed, setFailed] = useState<string | null>(null);
  useEffect(() => {
    let live = true;
    powos.glasses.state().then(
      (s) => live && setSt(s),
      (e) => live && setFailed(String(e?.message ?? e)),
    );
    const off = powos.on("glasses.state", (s: GlassesState) => live && setSt(s));
    return () => {
      live = false;
      off();
    };
  }, []);
  return (
    <div class="remote-screen glasses-screen" {...own}>
      <header class="remote-top">
        <button type="button" class="session-back" onClick={closeGlasses}>
          ‹
        </button>
        <span class="ai-title">Glasses</span>
        <span class={`remote-dot ${st?.phase === "ready" ? "linked" : st?.phase === "connecting" ? "on" : ""}`} />
      </header>
      {failed ? <div class="remote-status tile error">Glasses aren't available here: {failed}</div> : st && <Status st={st} />}
      {st?.paired && <Preview st={st} />}
      {st?.paired && <Send st={st} />}
      {st?.paired && <AppPick />}
      {st?.paired?.model === "G2" && <RasterOption st={st} />}
    </div>
  );
}

function Status({ st }: { st: GlassesState }) {
  const act = (label: string, run: () => Promise<unknown>) => (
    <button type="button" class="remote-action" onClick={() => run().catch(() => {})}>
      {label}
    </button>
  );
  let text: string;
  if (!st.available) text = "This phone has no Bluetooth.";
  else if (!st.enabled) text = "Bluetooth is off: turn it on to use the glasses.";
  else if (!st.paired)
    text = "Pair your Even Realities G2 or G1: take them out of the case (or put them on), then Pair - Android shows the arms it finds, one at a time.";
  else {
    const arms = [st.left && `L ${st.left.phase}`, st.right && `R ${st.right.phase}`].filter(Boolean).join(", ");
    const battery = Object.entries(st.battery)
      .map(([k, v]) => `${k} ${v}%`)
      .join(", ");
    text =
      st.phase === "ready"
        ? `${st.paired.model} connected (${arms})${st.mic ? ", mic on" : ""}${st.worn === false ? ", off the face" : ""}${battery ? ` - ${battery}` : ""}`
        : st.phase === "connecting"
          ? `${st.paired.model} connecting (${arms})…`
          : st.wanted
            ? `${st.paired.model}: waiting for them to be in range (${arms})`
            : `${st.paired.model} ${st.paired.pairId}: not connected`;
  }
  return (
    <div class={`remote-status tile ${st.error ? "error" : ""}`}>
      <span class="remote-status-text">
        {text}
        {st.error && <div class="glasses-note">{st.error}</div>}
      </span>
      <div class="glasses-actions">
        {st.available && st.enabled && act(st.paired ? "pair again" : "pair", () => powos.glasses.pair())}
        {st.paired && (st.wanted ? act("disconnect", () => powos.glasses.disconnect()) : act("connect", () => powos.glasses.connect()))}
        {st.paired && act("forget", () => powos.glasses.forget())}
      </div>
    </div>
  );
}

/** The preview's side of the glasses API: the same view, its own buttons for input, nothing done for the wearer. */
const previewApi: GlassesApi = {
  get view() {
    return view.value;
  },
  live: false,
  useInput: useGlassesInput,
};

/** What the glasses show, live: their app rendered here at the canvas's size, scaled to the screen. */
function Preview({ st }: { st: GlassesState }) {
  const App = useGlassesApp();
  const c = st.canvas ?? { width: 576, height: 288, bits: 4 };
  const mode = st.image.usable ? "image" : "text";
  const grid = textGrid(c);
  useEffect(() => {
    view.value = { model: st.paired?.model ?? null, width: c.width, height: c.height, bits: c.bits, mode, cols: grid.cols, rows: grid.rows };
  }, [st.paired?.model, c.width, c.height, c.bits, mode]);
  const scale = Math.min(1, (innerWidth - 32) / c.width);
  const M = App?.c;
  const key = (input: string) => (
    <button type="button" class="remote-chip" onClick={() => dispatchInput(input)}>
      {input}
    </button>
  );
  return (
    <>
      <div class="glasses-preview" style={{ width: `${c.width * scale}px`, height: `${c.height * scale}px` }}>
        <div class="glasses-root" style={{ width: `${c.width}px`, height: `${c.height}px`, transform: `scale(${scale})` }}>
          {M && <M glasses={previewApi} host={App?.host} />}
        </div>
      </div>
      <div class="glasses-keys">
        {key("click")}
        {key("double")}
        {key("up")}
        {key("down")}
      </div>
      <p class="glasses-note">
        {mode === "text"
          ? `Sent as text (the glasses' own font, about ${grid.cols} x ${grid.rows} characters).`
          : `Sent as a ${c.bits === 1 ? "black and white" : "16-grey"} picture, ${c.width} x ${c.height}.`}{" "}
        These buttons only move this preview; the glasses' own taps move theirs.
      </p>
    </>
  );
}

/** A line of text straight to the glasses (until their screen changes). */
function Send({ st }: { st: GlassesState }) {
  const [text, setText] = useState("");
  const send = () => text.trim() && powos.glasses.showText(text.trim()).catch(() => {});
  return (
    <div class="glasses-send">
      <input value={text} placeholder="Show on the glasses…" onInput={(e) => setText((e.target as HTMLInputElement).value)} onKeyDown={(e) => e.key === "Enter" && send()} />
      <button type="button" class="remote-action" disabled={st.phase !== "ready"} onClick={send}>
        show
      </button>
      <button type="button" class="remote-action" disabled={st.phase !== "ready"} onClick={() => powos.glasses.clear().catch(() => {})}>
        clear
      </button>
    </div>
  );
}

/** Which app the glasses show: the HUD, or a PowOS app that has a glasses screen (its manifest's "glasses" entry). */
function AppPick() {
  const [picked, setPicked] = useState<string>("");
  useEffect(() => {
    powos.store.get<{ app?: string }>("glasses").then((p) => setPicked(p?.app ?? ""), () => {});
  }, []);
  const apps = installedApps.value.filter((a) => manifestOf(a).glasses?.entry);
  if (!apps.length) return null;
  const pick = (id: string) => {
    const a = apps.find((x) => x.id === id);
    setPicked(id);
    const value = a ? { app: a.id, entry: manifestOf(a).glasses!.entry, version: a.version } : {};
    powos.store.set("glasses", value).then(() => powos.glasses.reload(), () => {});
  };
  return (
    <div class="glasses-actions">
      <span class="glasses-note">On the glasses:</span>
      <button type="button" class={`remote-target ${picked ? "" : "picked"}`} onClick={() => pick("")}>
        HUD
      </button>
      {apps.map((a) => (
        <button key={a.id} type="button" class={`remote-target ${picked === a.id ? "picked" : ""}`} onClick={() => pick(a.id)}>
          {a.name}
        </button>
      ))}
    </div>
  );
}

/** The G2's picture path: its render-channel framing is a guess (docs/GLASSES.md) - off unless asked for. */
function RasterOption({ st }: { st: GlassesState }) {
  const on = !!st.options.g2Raster;
  return (
    <label class="glasses-option">
      <input type="checkbox" checked={on} onChange={() => powos.glasses.option("g2Raster", !on).catch(() => {})} />
      <span>
        Send pictures to the G2 (experimental: its picture protocol isn't confirmed on real glasses; text is used
        otherwise)
      </span>
    </label>
  );
}
