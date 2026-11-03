/**
 * Terminals: xterm.js over the host's ptys (types.ts `term`). The host runs the shell - the same one the Compose
 * launcher's tiles run (PowOS's tmux picker, or a widget's command) - and streams its raw bytes; xterm.js here draws
 * them and turns keys, pastes and mouse reports back into bytes.
 *
 * A terminal (a [Session]) is the page's by its id: views naming the same id (a widget's tile and its screen) show one
 * shell. It has one xterm, which the newest view shows (and sizes the pty to), as PtyTerminal's newest view does; it
 * lives on while no view shows it, as the host's pty does.
 *
 * A view is inert until tapped, so the home screen's swipes pass over it: tapping an interactive one focuses it - the
 * soft keyboard comes up with the extra keys over it (ExtraKeys.kt's), its touches are the terminal's (a drag
 * scrolls, a tap is tmux's click) - until a press elsewhere, Back, or the keyboard put away by the system. A view
 * that isn't interactive only shows: its taps go to the widget.
 */
import { render } from "preact";
import { useEffect, useLayoutEffect, useRef } from "preact/hooks";
import { effect, signal } from "@preact/signals";
import { Terminal, type ITheme } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebglAddon } from "@xterm/addon-webgl";
import { powos } from "../bridge.ts";
import { tick } from "./haptics.ts";
import { takeTap } from "./taps.ts";
import { page, screen } from "../state.ts";
import type { TermState, TermStyle } from "../types.ts";

/** As PtyTerminal's transcript; tmux keeps its own. */
const SCROLLBACK = 2000;
/** A tap: shorter than a home tile's long press (which lifts it), and about still. */
const TAP_MS = 400;
const SLOP = 10;
/** The least of a focused terminal the keyboard may leave when the tile is too tall to lift clear of it. */
const MIN_ROWS_PX = 96;
const REPEAT_DELAY_MS = 400;
const REPEAT_MS = 50;

const utf8 = new TextEncoder();
const b64 = (bytes: Uint8Array) => {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
};
const unb64 = (s: string) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));

// --- looks -----------------------------------------------------------------------------------------------------------

/** The theme's terminal colors: terminal.css's --term-* tokens (from the shell's --color-* ones). */
function theme(): ITheme {
  const css = getComputedStyle(document.documentElement);
  const v = (name: string) => css.getPropertyValue(name).trim() || undefined;
  const names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"] as const;
  const t: Record<string, string | undefined> = {
    // xterm parses colors itself: "transparent" as the hex it knows.
    background: v("--term-background") === "transparent" ? "#00000000" : v("--term-background"),
    foreground: v("--term-foreground"),
    cursor: v("--term-cursor"),
    // The letter under the block cursor: the theme's background (the terminal's own may be transparent).
    cursorAccent: v("--color-background"),
    selectionBackground: v("--term-selection"),
  };
  names.forEach((n, i) => {
    t[n] = v(`--term-color${i}`);
    t[`bright${n[0].toUpperCase()}${n.slice(1)}`] = v(`--term-color${i + 8}`);
  });
  return t as ITheme;
}

/** The host's style by text size (points; "" for the terminal text size), asked for once. */
const styles = new Map<string, Promise<TermStyle>>();
const styleFor = (points: number | null) => {
  const k = points == null ? "" : String(points);
  if (!styles.has(k)) styles.set(k, powos.term.style(points));
  return styles.get(k)!;
};

/**
 * The launcher's terminal font (PowOS's file, served by the host once it has a copy) then the Nerd Font symbols, as
 * PtyTerminal's typeface; the shell's monospace font until the file is there. The cells measure the first.
 */
const loadedFonts = new Map<string, Promise<boolean>>();
function loadFont(name: string, url: string) {
  if (!loadedFonts.has(url)) {
    const face = new FontFace(name, `url(${JSON.stringify(url)})`);
    loadedFonts.set(
      url,
      face.load().then(
        (f) => (document.fonts.add(f), true),
        () => false,
      ),
    );
  }
  return loadedFonts.get(url)!;
}
async function fontFamily(style: TermStyle) {
  const symbols = (await loadFont("PowOS Symbols", "/_font/symbols")) ? ', "PowOS Symbols"' : "";
  // PowTerm's face (Termux's TerminalView: Typeface.MONOSPACE, Droid Sans Mono on Android) unless the user chose a
  // family of their own: the system monospace, which Chromium resolves to the same face.
  if (style.own === false) return `monospace${symbols}`;
  const fallback = getComputedStyle(document.documentElement).getPropertyValue("--font").trim() || "monospace";
  const face = `PowOS Terminal ${style.family}`;
  const own = style.font && (await loadFont(face, `/_font/terminal/${encodeURIComponent(style.family)}`));
  // The symbols last: only the glyphs no monospace face has fall through to it. First in the list (before the
  // terminal file arrived, style.font false) it was the face xterm measured its cell with, and the text's own face
  // didn't fit that grid (letters spread apart, the columns off the width).
  return `${own ? JSON.stringify(face) + ", " : ""}${fallback}${symbols}`;
}

// --- sessions --------------------------------------------------------------------------------------------------------

type Status = "starting" | "running" | "exited";

/** What a mounted view is: its box, its props. */
interface View {
  el: HTMLDivElement;
  screen: HTMLDivElement;
  interactive: boolean;
  /** The widget's fontSize (points) and textSize (sp); either sizes this view's text. */
  fontSize: number | null;
  textSize: number | null;
  /** How much of its bottom the soft keyboard takes while it's focused (a tile too tall to lift clear). */
  cut: number;
}

class Session {
  readonly term: Terminal;
  readonly fit = new FitAddon();
  private resizeTimer = 0;
  /** The size the pty has ("cols x rows"): asking again for it would only redraw tmux. */
  private ptySize = "";

  private sizePty(cols: number, rows: number) {
    if (this.status.value !== "running" || this.ptySize === `${cols}x${rows}`) return;
    this.ptySize = `${cols}x${rows}`;
    powos.term.resize(this.id, cols, rows);
  }
  /** xterm's element's parent: moved into the view that shows it. */
  readonly holder = document.createElement("div");
  readonly views: View[] = [];
  readonly status = signal<Status>("starting");
  /** The host's run of it this shows, and the offset of its output shown so far. */
  private run = 0;
  private seen = 0;
  /** Events that came while it opened (their run isn't known yet), else null. */
  private queue: { exit: boolean; e: any }[] | null = null;
  private opening = false;
  private shown: View | null = null;
  /**
   * The scrollback line a drag left the view at (null: at the bottom, following the output). Held through output: a
   * view-only session's frames (powos terms attach) clear and redraw the scrollback about once a second, which put the
   * view back at the bottom under the finger.
   */
  held: number | null = null;
  /** "webgl" (PowTerm's canvas drawing: glyphs to a texture atlas, cells on the GPU) or "dom" (no WebGL, or it lost). */
  renderer: "webgl" | "dom" = "dom";
  /** Its WebGL context was lost (WebGL is there): a full-screen view showing it again asks for a new one ([show]). */
  webglLost = false;

  constructor(
    readonly id: string,
    public owner: string | null,
    public command: string | null,
  ) {
    this.holder.className = "term-holder";
    this.term = new Terminal({
      scrollback: SCROLLBACK,
      theme: theme(),
      allowTransparency: true,
      fontFamily: "monospace",
      // PowTerm's line: Termux's TerminalRenderer spaces rows by the font's own spacing (ascent + descent, rounded
      // up); xterm's cell at lineHeight 1 is the same measure (fontBoundingBox ascent + descent, ceiled to pixels).
      lineHeight: 1,
      letterSpacing: 0,
      // Box drawing and blocks drawn to the cell (the WebGL renderer's), so tmux's borders and htop's bars join up
      // row to row as PowTerm's do, whatever the face's own glyphs measure.
      customGlyphs: true,
      cursorBlink: false,
      allowProposedApi: false,
    });
    this.term.loadAddon(this.fit);
    this.term.open(this.holder);
    this.renderer = webgl(this.term);
    this.term.onData((d) => this.send(modify(d)));
    // Mouse reports in the X10 encoding: bytes, not text.
    this.term.onBinary((d) => this.sendBytes(Uint8Array.from(d, (c) => c.charCodeAt(0) & 0xff)));
    // The pty follows once the size settles: a screen opening or closing passes through a few (the keys docking, the
    // keyboard sliding), and every one was a full tmux redraw over the bridge. xterm itself refits at once.
    this.term.onResize(({ cols, rows }) => {
      clearTimeout(this.resizeTimer);
      this.resizeTimer = window.setTimeout(() => {
        this.sizePty(cols, rows);
      }, RESIZE_SETTLE_MS);
    });
  }

  send(text: string) {
    if (text) this.sendBytes(utf8.encode(text));
  }

  private sendBytes(bytes: Uint8Array) {
    // Typing goes to the bottom (xterm scrolls there on input), and stays there with the output.
    this.held = null;
    if (this.status.value === "running" && bytes.length) powos.term.write(this.id, b64(bytes));
  }

  /** Opens the host's terminal (a [restart] if it ended): it starts from what it wrote lately. */
  async start(restart = false) {
    if (this.opening) return;
    this.opening = true;
    this.status.value = "starting";
    this.queue = [];
    const dims = this.fit.proposeDimensions();
    let st: TermState;
    try {
      st = await powos.term.open(this.id, this.owner, this.command, dims?.cols ?? this.term.cols, dims?.rows ?? this.term.rows, restart);
    } catch (e) {
      console.warn("term.open", this.id, e);
      this.queue = null;
      this.opening = false;
      this.status.value = "exited";
      return;
    }
    if (st.run !== this.run) {
      this.term.reset();
      this.run = st.run;
      this.seen = 0;
    }
    this.output(unb64(st.history), st.end);
    const queued = this.queue;
    this.queue = null;
    this.opening = false;
    this.status.value = st.running ? "running" : "exited";
    for (const q of queued) q.exit ? this.exit(q.e) : this.data(q.e);
    // The pty takes the size it's shown at, which may have changed while it opened.
    this.ptySize = "";
    this.sizePty(this.term.cols, this.term.rows);
  }

  /** Bytes ending at offset [end] of the run's output: what's been shown already is skipped. */
  private output(bytes: Uint8Array, end: number) {
    if (end <= this.seen) return;
    const start = end - bytes.length;
    this.term.write(start < this.seen ? bytes.subarray(this.seen - start) : bytes, () => {
      const b = this.term.buffer.active;
      if (this.held != null && b.viewportY !== Math.min(this.held, b.baseY)) this.term.scrollToLine(Math.min(this.held, b.baseY));
    });
    this.seen = end;
  }

  data(e: { run: number; data: string; end: number }) {
    if (this.queue) return void this.queue.push({ exit: false, e });
    if (e.run === this.run) this.output(unb64(e.data), e.end);
  }

  exit(e: { run: number; code: number }) {
    if (this.queue) return void this.queue.push({ exit: true, e });
    if (e.run !== this.run) return;
    this.status.value = "exited";
    if (focused.value && this.views.includes(focused.value)) release();
  }

  /** The newest view shows it, at its own text size; the pty follows its size. */
  async show() {
    const view = this.views[this.views.length - 1];
    if (!view) return;
    if (this.shown !== view || this.holder.parentElement !== view.screen) view.screen.append(this.holder);
    this.shown = view;
    const style = await styleFor(view.fontSize);
    if (this.views[this.views.length - 1] !== view) return;
    this.holder.style.inset = `${style.pad}px`;
    this.holder.style.bottom = `${style.pad + view.cut}px`;
    // HACK: the fit addon keeps a scrollbar's width (14px) free at the right, always - a phone has no scrollbar (a
    // drag scrolls), so that was an empty strip down the tile. The holder reaches that far past the view (.term clips
    // it), so the columns fill the width as the Compose terminal's do. Real fix: an addon option for the reserve (or
    // fitting from the renderer's cell size ourselves once xterm exposes it).
    this.holder.style.right = `${style.pad - FIT_SCROLLBAR}px`;
    const sp = viewText(view);
    this.term.options.fontSize = sp != null ? sp * style.fontScale : style.size;
    this.term.options.fontFamily = await fontFamily(style);
    this.backToWebgl(view);
    this.refit();
  }

  /** Fits the xterm to its view (cols and rows to the pty): a view that isn't laid out (0 wide) leaves it. */
  refit() {
    if (!this.holder.isConnected || !this.holder.clientWidth || !this.holder.clientHeight) return;
    this.fit.fit();
    // Whole rows fit; what's left of a row is split above and below them, not all left under the last one (a tile's
    // bottom stood a row's height empty). xterm maps the pointer from the screen's own rect, so the shift is safe.
    // Layout sizes on both sides (offsetHeight, not the bounding rect): a session screen fits while it grows out of
    // its card under a scale transform, and the rect's scaled height left most of the screen as "space to split" -
    // the content shifted half a screen down, an empty band above it and its last rows under the bottom edge.
    requestAnimationFrame(() => {
      const xt = this.holder.querySelector<HTMLElement>(".xterm");
      const scr = this.holder.querySelector<HTMLElement>(".xterm-screen");
      if (!xt || !scr) return;
      const left = Math.min(this.holder.clientHeight - scr.offsetHeight, this.holder.clientHeight / this.term.rows);
      xt.style.transform = left > 1 ? `translateY(${Math.floor(left / 2)}px)` : "";
    });
  }

  /**
   * Back to WebGL after a lost context, where the user looks at it (a session or terminal screen, not a home tile): the
   * DOM renderer draws the same font and metrics, but WebGL is PowTerm's drawing (crisp cells, box drawing joined). A
   * tile doesn't ask: each new context takes the oldest of Chromium's 16, another tile's.
   */
  private backToWebgl(view: View) {
    if (this.webglLost && this.renderer === "dom" && atTerminalText(view)) this.renderer = webgl(this.term);
  }

  restyle() {
    this.term.options.theme = theme();
    this.show();
  }
}

/**
 * Draws [term] with the WebGL renderer: "webgl", or "dom" where WebGL2 isn't there. A lost context (the GPU process
 * restarted, or Chromium's per-page context limit took the oldest) hands it back to xterm's DOM renderer, which draws
 * the same buffer at once; the session keeps its scrollback and size.
 */
function webgl(term: Terminal): "webgl" | "dom" {
  try {
    const gl = new WebglAddon();
    term.loadAddon(gl);
    let lost = false;
    const toDom = () => {
      if (lost) return;
      lost = true;
      gl.dispose();
      const s = [...sessions.values()].find((x) => x.term === term);
      if (s) Object.assign(s, { renderer: "dom", webglLost: true });
    };
    gl.onContextLoss(toDom);
    // At once, not after the addon's 3 s wait for a restore: the loss Chromium deals most (its per-page context limit
    // taking the oldest, when a home of terminal tiles and other WebGL widgets passes 16) never restores, and the tile
    // drew nothing for those 3 s - the widget sweep measured terminal tiles blank. The DOM renderer draws the buffer
    // the next frame. Caught on the way down (the event doesn't bubble) and disposed a task later, after the addon's own
    // listener has armed its timer; that timer then fires on a disposed addon, a no-op.
    term.element?.addEventListener("webglcontextlost", () => setTimeout(toDom), { capture: true, once: true });
    return "webgl";
  } catch (e) {
    console.warn("term: no WebGL, the DOM renderer draws", e);
    return "dom";
  }
}

// --- text size: a pinch, as PowTerm's (Termux's onScale) -------------------------------------------------------------

/** The terminal text size's range (sp: Style's terminal.text, PowTerm's pinch range 6..32). */
const TEXT_MIN = 6;
const TEXT_MAX = 32;
/** A pinch steps the size by 1 once its scale leaves 0.9..1.1, then measures from there (PowTerm's onScale). */
const PINCH_STEP = 0.1;
/** How long the pinched size holds before it's saved (one save per pinch, not per step). */
const PINCH_SAVE_MS = 400;

/** The text size a pinch has shown and not saved yet (sp), else null. */
let pinchSp: number | null = null;
let pinchSave = 0;

/** [v] has no size of its own (a tile's fontSize or textSize): it's at the terminal text size, and pinches it. */
const atTerminalText = (v: View) => v.fontSize == null && v.textSize == null;
/** The size [v] shows (sp), else null for the host's: its own, or one a pinch has shown ([pinchText]) before it's saved. */
const viewText = (v: View) => v.textSize ?? (v.fontSize == null ? pinchSp : null);

/**
 * Steps the terminal text size by [dir] (sp), as PowTerm's pinch: every terminal without a size of its own shows it at
 * once, then it's saved to the terminal text setting (style.text, which the launcher's terminals share) and the host's
 * style asked again. A failed save shows the size the host has again.
 */
export async function pinchText(dir: 1 | -1) {
  const st = await styleFor(null);
  const now = pinchSp ?? Math.round(st.size / st.fontScale);
  const next = Math.min(TEXT_MAX, Math.max(TEXT_MIN, now + dir));
  if (next === now) return;
  pinchSp = next;
  sessions.forEach((s) => s.show());
  clearTimeout(pinchSave);
  pinchSave = window.setTimeout(async () => {
    await powos.screens.act("style", "text", next).catch((e) => console.warn("term: text size not saved", e));
    if (pinchSp !== next) return;
    pinchSp = null;
    styles.clear();
    sessions.forEach((s) => s.show());
  }, PINCH_SAVE_MS);
}

/** How long a terminal's size holds before the pty takes it. */
const RESIZE_SETTLE_MS = 120;

/** What the fit addon leaves free for a scrollbar (addon-fit 0.11: overviewRuler.width, else 14). */
const FIT_SCROLLBAR = 14;

const sessions = new Map<string, Session>();

powos.on("term.data", (e: { id: string; run: number; data: string; end: number }) => sessions.get(e.id)?.data(e));
powos.on("term.exit", (e: { id: string; run: number; code: number }) => sessions.get(e.id)?.exit(e));
// Another theme: its colors are on the page's tokens a moment later (app.tsx), then in every terminal.
powos.on("theme.changed", () => setTimeout(() => sessions.forEach((s) => s.restyle()), 50));
// The terminal font arrived (or the text size changed): every terminal asks again.
powos.on("term.style", () => {
  styles.clear();
  sessions.forEach((s) => s.show());
});
// A stylesheet swapped in place (hot reload): the theme's colors may have changed.
powos.on("files.changed", ({ path }: { path: string }) => {
  if (path.endsWith(".css")) setTimeout(() => sessions.forEach((s) => s.restyle()), 100);
});

/** Ends a terminal that no widget owns (a terminal screen of the shell's own); a widget's end with it on the host. */
/** The xterm behind a terminal id (dev/gate.mjs's terminal scenes read its cols, rows and cursor). */
export const terminalFor = (id: string) => sessions.get(id)?.term ?? null;
/** What draws a terminal id's cells (the gate's terminal scenes check it's the WebGL renderer). */
export const rendererFor = (id: string) => sessions.get(id)?.renderer ?? null;

export function closeTerminal(id: string) {
  sessions.get(id)?.term.dispose();
  sessions.delete(id);
  // A host without terminals (an older bridge.ts in the override folder) has nothing to close.
  powos.term?.close(id).catch(() => {});
}

// --- focus, the keyboard and the extra keys ---------------------------------------------------------------------------

/** The view that has the keys, if any. */
const focused = signal<View | null>(null);
/** The session it shows. */
const focusedSession = () => [...sessions.values()].find((s) => focused.value && s.views.includes(focused.value)) ?? null;
let keyboardUp = false;
let keyboardHeight = 0;

function focus(view: View) {
  const s = [...sessions.values()].find((x) => x.views.includes(view));
  if (!s || s.status.value !== "running") return;
  // It shows in the view being typed in, a tile's screen over the tile included.
  s.views.splice(s.views.indexOf(view), 1);
  s.views.push(view);
  s.show();
  focused.value = view;
  document.documentElement.classList.add("term-focus");
  mountExtraKeys();
  s.term.focus();
  powos.keyboard.show("terminal");
  requestAnimationFrame(lift);
}

function release() {
  const view = focused.value;
  if (!view) return;
  focusedSession()?.term.blur();
  focused.value = null;
  view.cut = 0;
  document.documentElement.classList.remove("term-focus");
  document.documentElement.style.removeProperty("--term-lift");
  powos.keyboard.hide();
  [...sessions.values()].find((s) => s.views.includes(view))?.show();
}

// A press anywhere but the focused terminal and its keys lets go of it (the press still does what it does).
document.addEventListener(
  "pointerdown",
  (e) => {
    const view = focused.value;
    const t = e.target as Node;
    if (view && !view.el.contains(t) && !extraKeys?.contains(t)) release();
  },
  true,
);
// Back: a widget's screen closes first (state.ts back), its terminal letting go as it goes; on home, the tile lets go.
powos.on("system.back", () => screen.value.key == null && release());
// Another home page: the tile typed in is off screen (Home.kt), so it lets go.
let shownPage = page.peek();
effect(() => {
  if (page.value !== shownPage) {
    shownPage = page.value;
    if (screen.peek().key == null) release();
  }
});
powos.on("system.insets", (i: { keyboard: number }) => {
  keyboardHeight = i.keyboard;
  // The keyboard gone by itself (Back closes it before the page sees Back): a tile lets go, as the Compose one; a
  // screen's terminal keeps the keys (the next Back closes the screen).
  if (keyboardUp && i.keyboard === 0 && screen.value.key == null) release();
  keyboardUp = i.keyboard > 0;
  extraKeysState.value = { keyboard: keyboardUp };
  requestAnimationFrame(lift);
});

const px = (name: string) => parseFloat(document.documentElement.style.getPropertyValue(name)) || 0;

/**
 * Lifts the home screen so the focused terminal clears the keyboard and the extra keys, but not past the status bar
 * (TerminalTiles.liftFor); a tile too tall for both gives up its bottom (the cut), never below [MIN_ROWS_PX].
 */
function lift() {
  const view = focused.value;
  const root = document.documentElement;
  if (!view) return;
  const lifted = px("--term-lift");
  const r = view.el.getBoundingClientRect();
  const top = r.top + lifted;
  const bar = extraKeys?.firstElementChild?.getBoundingClientRect().height ?? 0;
  const floor = window.innerHeight - Math.max(keyboardHeight, px("--inset-bottom")) - bar;
  const overlap = Math.max(0, top + r.height - floor);
  const room = Math.max(0, top - px("--inset-top"));
  const next = Math.min(overlap, room);
  const cut = Math.max(0, Math.min(overlap - room, r.height - MIN_ROWS_PX));
  root.style.setProperty("--term-lift", `${next}px`);
  if (Math.abs(cut - view.cut) >= 1) {
    view.cut = cut;
    focusedSession()?.show();
  }
}

/** The sticky modifiers: a tap latches one for the next key, a long press locks it. */
const ctrl = signal<0 | 1 | 2>(0);
const alt = signal<0 | 1 | 2>(0);
const extraKeysState = signal({ keyboard: false });

/** Typed text through the latched modifiers: Ctrl makes a control character, Alt prefixes ESC. */
function modify(d: string): string {
  if (!ctrl.value && !alt.value) return d;
  const one = [...d].length === 1;
  if (!one) return d;
  let out = d;
  if (ctrl.value) out = control(d);
  if (alt.value) out = "\x1b" + out;
  consume();
  return out;
}

function control(ch: string) {
  const c = ch.toLowerCase().charCodeAt(0);
  if (c >= 97 && c <= 122) return String.fromCharCode(c - 96);
  const special: Record<string, string> = { " ": "\0", "@": "\0", "[": "\x1b", "\\": "\x1c", "]": "\x1d", "^": "\x1e", _: "\x1f", "?": "\x7f", "/": "\x1f", "-": "\x1f" };
  return special[ch] ?? ch;
}

function consume() {
  if (ctrl.value === 1) ctrl.value = 0;
  if (alt.value === 1) alt.value = 0;
}

/** A key's bytes: cursor keys follow the application's cursor mode; with modifiers, xterm's CSI 1;m form. */
function keySeq(key: string, term: Terminal) {
  const mod = 1 + (alt.value ? 2 : 0) + (ctrl.value ? 4 : 0);
  const app = term.modes.applicationCursorKeysMode;
  const cursor: Record<string, string> = { up: "A", down: "B", right: "C", left: "D", home: "H", end: "F" };
  const tilde: Record<string, string> = { pgup: "5", pgdn: "6" };
  let seq: string;
  if (cursor[key]) seq = mod > 1 ? `\x1b[1;${mod}${cursor[key]}` : `${app ? "\x1bO" : "\x1b["}${cursor[key]}`;
  else if (tilde[key]) seq = `\x1b[${tilde[key]}${mod > 1 ? `;${mod}` : ""}~`;
  else if (key === "esc") seq = (alt.value ? "\x1b" : "") + "\x1b";
  else if (key === "tab") seq = ctrl.value ? "\t" : alt.value ? "\x1b\t" : "\t";
  else seq = modify(key);
  consume();
  return seq;
}

interface Key {
  label: string;
  key: string;
  repeats?: boolean;
  arrow?: number;
}

/** ExtraKeys.kt's two rows. */
const ROWS: (Key | "ctrl" | "alt")[][] = [
  [{ label: "esc", key: "esc" }, { label: "/", key: "/" }, { label: "-", key: "-" }, { label: "home", key: "home" }, { label: "up", key: "up", repeats: true, arrow: 0 }, { label: "end", key: "end" }, { label: "pgup", key: "pgup", repeats: true }, { label: "copy", key: "copy" }],
  [{ label: "tab", key: "tab" }, "ctrl", "alt", { label: "left", key: "left", repeats: true, arrow: -90 }, { label: "down", key: "down", repeats: true, arrow: 180 }, { label: "right", key: "right", repeats: true, arrow: 90 }, { label: "pgdn", key: "pgdn", repeats: true }, { label: "paste", key: "paste" }],
];

async function press(key: string) {
  const s = focusedSession();
  if (!s) return;
  if (key === "copy") {
    const text = s.term.getSelection();
    if (text) await powos.clipboard.write(text);
    s.term.clearSelection();
    return;
  }
  if (key === "paste") {
    const text = await powos.clipboard.read();
    if (text) s.term.paste(text);
    return;
  }
  s.send(keySeq(key, s.term));
}

/**
 * A keycap. Keys never take the focus (the press is cancelled before it reaches the textarea), so the soft keyboard
 * stays up; arrows and pages repeat while held.
 */
function Cap({ k }: { k: Key }) {
  const timer = useRef(0);
  const stop = () => clearTimeout(timer.current);
  return (
    <button
      class="term-key"
      onPointerDown={(e) => {
        e.preventDefault();
        tick();
        press(k.key);
        if (k.repeats) {
          const again = () => {
            press(k.key);
            timer.current = window.setTimeout(again, REPEAT_MS);
          };
          timer.current = window.setTimeout(again, REPEAT_DELAY_MS);
        }
      }}
      onPointerUp={stop}
      onPointerCancel={stop}
      onPointerLeave={stop}
    >
      {k.arrow != null ? <span class="term-arrow" style={{ transform: `rotate(${k.arrow}deg)` }}>⌃</span> : k.label}
    </button>
  );
}

function Sticky({ name, mod }: { name: string; mod: typeof ctrl }) {
  const held = useRef<{ t: number; timer: number } | null>(null);
  return (
    <button
      class={`term-key sticky ${mod.value ? "on" : ""} ${mod.value === 2 ? "locked" : ""}`}
      onPointerDown={(e) => {
        e.preventDefault();
        tick();
        const timer = window.setTimeout(() => {
          mod.value = 2;
          held.current = null;
        }, TAP_MS);
        held.current = { t: performance.now(), timer };
      }}
      onPointerUp={() => {
        if (!held.current) return;
        clearTimeout(held.current.timer);
        held.current = null;
        mod.value = mod.value ? 0 : 1;
      }}
    >
      {name}
    </button>
  );
}

function ExtraKeys() {
  if (!focused.value) return null;
  return (
    <div class="term-extra tile">
      <div class="term-rows">
        {ROWS.map((row, i) => (
          <div class="term-row" key={i}>
            {row.map((k) => (k === "ctrl" ? <Sticky key={k} name={k} mod={ctrl} /> : k === "alt" ? <Sticky key={k} name={k} mod={alt} /> : <Cap key={k.key} k={k} />))}
          </div>
        ))}
      </div>
    </div>
  );
}

let extraKeys: HTMLDivElement | null = null;
function mountExtraKeys() {
  if (extraKeys) return;
  extraKeys = document.createElement("div");
  extraKeys.className = "term-extra-host";
  document.body.append(extraKeys);
  render(<ExtraKeys />, extraKeys);
}

// --- scrolling (PowTerm's: Termux's TerminalView onScroll / doScroll / onFling) ----------------------------------------

/** A finger on a focused terminal: where it is, the part of a row it moved that isn't scrolled yet, its last moves. */
interface Drag {
  y: number;
  y0: number;
  id: number;
  rest: number;
  moves: { y: number; t: number }[];
}

/** The moves the release velocity is read from (Android's VelocityTracker looks back ~100 ms). */
const VELOCITY_SAMPLES = 5;
const VELOCITY_WINDOW_MS = 100;
/** Termux's onFling: the fling runs in rows at a quarter of the finger's px/s. */
const FLING_SCALE = 0.25;
/** The fling's decay (its velocity falls by 1/e every [FLING_TAU_S]) and the speed it stops under (rows/s). */
const FLING_TAU_S = 0.12;
const FLING_MIN = 2;

const flings = new WeakMap<Session, number>();

/** The height of one of [s]'s rows (px): the screen's height over its rows, as the fit made them. */
function cellHeight(s: Session) {
  const scr = s.holder.querySelector<HTMLElement>(".xterm-screen");
  return (scr?.offsetHeight || s.holder.clientHeight) / s.term.rows || 16;
}

/**
 * Scrolls [rows] rows (positive: the finger went down, toward older lines) as Termux's doScroll, one row at a time:
 * the program's mouse wheel while it tracks the mouse (tmux's mouse: its history), an arrow key in the alternate screen
 * (a full-screen program), else the scrollback. A wheel event per row, in lines: xterm reports one wheel click per
 * event, and in pixels it counted a finger's small moves as a trackpad's (x0.3) - a drag scrolled a third of the way.
 */
function scrollRows(s: Session, rows: number, x: number, y: number) {
  const t = s.term;
  if (t.modes.mouseTrackingMode === "none" && t.buffer.active.type === "normal") {
    t.scrollLines(-rows);
    const b = t.buffer.active;
    s.held = b.viewportY < b.baseY ? b.viewportY : null;
    return;
  }
  const target = t.element?.querySelector(".xterm-screen");
  for (let i = 0; i < Math.abs(rows); i++)
    target?.dispatchEvent(new WheelEvent("wheel", { deltaY: rows > 0 ? -1 : 1, deltaMode: WheelEvent.DOM_DELTA_LINE, clientX: x, clientY: y, bubbles: true, cancelable: true }));
}

function stopFling(s: Session) {
  cancelAnimationFrame(flings.get(s) ?? 0);
  flings.delete(s);
}

/**
 * The release of [d] at [at] goes on scrolling (Termux's onFling): rows at a quarter of the finger's speed, slowing to
 * a stop; while the program tracks the mouse, at most half a screen (Termux's bound).
 */
function fling(s: Session, d: Drag, x: number, at: number) {
  const recent = d.moves.filter((m) => at - m.t <= VELOCITY_WINDOW_MS);
  if (recent.length < 2) return;
  const first = recent[0];
  const last = recent[recent.length - 1];
  const dt = (last.t - first.t) / 1000;
  if (dt <= 0) return;
  let v = ((last.y - first.y) / dt) * FLING_SCALE;
  if (Math.abs(v) < FLING_MIN) return;
  const bound = s.term.modes.mouseTrackingMode === "none" ? Infinity : Math.floor(s.term.rows / 2);
  let moved = 0;
  let rest = 0;
  let prev = performance.now();
  const step = (now: number) => {
    const sec = Math.max(0, (now - prev) / 1000);
    prev = now;
    rest += v * sec;
    v *= Math.exp(-sec / FLING_TAU_S);
    let rows = Math.trunc(rest);
    rows = Math.sign(rows) * Math.min(Math.abs(rows), bound - Math.abs(moved));
    if (rows) {
      rest -= rows;
      moved += rows;
      scrollRows(s, rows, x, d.y);
    }
    if (Math.abs(v) < FLING_MIN || Math.abs(moved) >= bound) return void flings.delete(s);
    flings.set(s, requestAnimationFrame(step));
  };
  stopFling(s);
  flings.set(s, requestAnimationFrame(step));
}

// --- the view ---------------------------------------------------------------------------------------------------------

export interface TerminalProps {
  /** The terminal's id: views naming the same one show one shell. */
  id: string;
  /** The widget it ends with, if any. */
  owner?: string | null;
  /** What it runs; null: PowOS's tmux picker (rooted mode), or a login shell. */
  command?: string | null;
  interactive?: boolean;
  fontSize?: number | null;
  textSize?: number | null;
  /** Focused as soon as its shell is up (a screen opened to type in). */
  focus?: boolean;
  /**
   * A drag scrolls it while it isn't focused too (a view-only session: its history is the scrollback, session.tsx), as
   * a focused one's; a tap still focuses it. Off for a home tile, whose drags are home's swipes.
   */
  scroll?: boolean;
  class?: string;
  style?: Record<string, string | number | undefined>;
}

export function TerminalView({ id, owner = null, command = null, interactive = true, fontSize = null, textSize = null, focus: autoFocus = false, scroll = false, class: cls, style }: TerminalProps) {
  const el = useRef<HTMLDivElement>(null);
  const screen = useRef<HTMLDivElement>(null);
  const view = useRef<View | null>(null);
  let s = sessions.get(id);
  if (!s) {
    s = new Session(id, owner, command);
    sessions.set(id, s);
  }
  const session = s;
  const status = session.status.value;
  const isFocused = focused.value != null && focused.value === view.current;

  useLayoutEffect(() => {
    const v: View = { el: el.current!, screen: screen.current!, interactive, fontSize, textSize, cut: 0 };
    view.current = v;
    session.views.push(v);
    session.show();
    const ro = new ResizeObserver(() => session.views[session.views.length - 1] === v && session.refit());
    ro.observe(v.el);
    return () => {
      ro.disconnect();
      if (focused.value === v) release();
      session.views.splice(session.views.indexOf(v), 1);
      // The view under it shows the terminal again (a screen closed over its tile).
      session.show();
    };
  }, [session]);

  // Props that change: a new size shows at once; a new command is a new shell.
  useEffect(() => {
    const v = view.current!;
    Object.assign(v, { interactive, fontSize, textSize });
    session.owner = owner;
    if (session.command !== command) {
      session.command = command;
      session.start(true);
    } else if (session.status.value === "starting") session.start();
    session.show();
  }, [session, command, owner, interactive, fontSize, textSize]);

  useEffect(() => {
    if (autoFocus && status === "running" && interactive && view.current && focused.value !== view.current) focus(view.current);
  }, [autoFocus, status, interactive]);

  // Focused, its touches are the terminal's: kept from the home screen's swipes. A drag scrolls as PowTerm's (Termux's
  // TerminalView.onScroll/doScroll): a row per row the finger moved, then a fling on release ([scrollRows], [fling]).
  // A tap is a click (the browser's mouse events, which xterm reports to tmux).
  const drag = useRef<Drag | null>(null);
  // Two fingers pinch the text size (PowTerm's): a view at the terminal text size, not a tile's own.
  const fingers = useRef(new Map<number, { x: number; y: number }>());
  const pinch = useRef<number | null>(null);
  const spread = () => {
    const [a, b] = [...fingers.current.values()];
    return a && b ? Math.hypot(a.x - b.x, a.y - b.y) : 0;
  };
  const dragStart = (e: PointerEvent) => {
    stopFling(session);
    if (e.pointerType !== "mouse") fingers.current.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (fingers.current.size === 2 && view.current && atTerminalText(view.current)) {
      drag.current = null;
      pinch.current = spread();
      return;
    }
    drag.current = { y: e.clientY, y0: e.clientY, id: e.pointerId, rest: 0, moves: [{ y: e.clientY, t: e.timeStamp }] };
  };
  /** A finger of a pinch moved: a step of text size per 10% of scale. False: no pinch. */
  const pinchMove = (e: PointerEvent) => {
    if (fingers.current.has(e.pointerId)) fingers.current.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (pinch.current == null) return false;
    const d = spread();
    const scale = pinch.current ? d / pinch.current : 1;
    if (Math.abs(scale - 1) > PINCH_STEP) {
      pinch.current = d;
      void pinchText(scale > 1 ? 1 : -1);
    }
    return true;
  };
  const dragMove = (e: PointerEvent) => {
    if (pinchMove(e)) return;
    const d = drag.current;
    if (!d || d.id !== e.pointerId || e.pointerType === "mouse") return;
    d.rest += e.clientY - d.y;
    d.y = e.clientY;
    d.moves.push({ y: e.clientY, t: e.timeStamp });
    if (d.moves.length > VELOCITY_SAMPLES) d.moves.shift();
    const cell = cellHeight(session);
    const rows = Math.trunc(d.rest / cell);
    if (rows) {
      d.rest -= rows * cell;
      scrollRows(session, rows, e.clientX, e.clientY);
    }
  };
  /** The finger up: a fling if it moved; the drag it was, if any. */
  const dragEnd = (e: PointerEvent) => {
    fingers.current.delete(e.pointerId);
    if (pinch.current != null) {
      // The pinch ends with its last finger: neither finger is a tap or a fling.
      if (!fingers.current.size) pinch.current = null;
      drag.current = null;
      return null;
    }
    const d = drag.current;
    drag.current = null;
    if (d && d.id === e.pointerId && e.pointerType !== "mouse") fling(session, d, e.clientX, e.timeStamp);
    return d;
  };
  const focusedHandlers = {
    onPointerDown: (e: PointerEvent) => {
      e.stopPropagation();
      dragStart(e);
    },
    onPointerMove: dragMove,
    onPointerUp: (e: PointerEvent) => {
      const d = dragEnd(e);
      // A tap with the keyboard down (Back put it away in a screen) brings it back, as Termux's view does.
      if (d && Math.abs(e.clientY - d.y0) < SLOP && !extraKeysState.peek().keyboard) {
        session.term.focus();
        powos.keyboard.show("terminal");
      }
    },
    onPointerCancel: () => {
      drag.current = null;
      fingers.current.clear();
      pinch.current = null;
      stopFling(session);
    },
  };

  // Not focused: a tap focuses an interactive view (or restarts an ended one). The press isn't stopped, so the tile's
  // long press still lifts it; its mouse events are, so the tap that focuses isn't also a click in the terminal.
  const tap = useRef<{ x: number; y: number; t: number } | null>(null);
  const onTap = (then: () => void) => ({
    onPointerDown: (e: PointerEvent) => {
      e.preventDefault();
      tap.current = { x: e.clientX, y: e.clientY, t: performance.now() };
    },
    onPointerUp: (e: PointerEvent) => {
      const t = tap.current;
      tap.current = null;
      if (!t || performance.now() - t.t > TAP_MS || Math.hypot(e.clientX - t.x, e.clientY - t.y) >= SLOP) return;
      takeTap(e);
      then();
    },
  });
  // [scroll]: the cover's drags scroll it as a focused view's do (a view-only session's history, its scrollback).
  const scrolls = (h: { onPointerDown?: (e: PointerEvent) => void; onPointerUp?: (e: PointerEvent) => void }) =>
    !scroll
      ? h
      : {
          onPointerDown: (e: PointerEvent) => {
            e.preventDefault();
            h.onPointerDown?.(e);
            dragStart(e);
          },
          onPointerMove: dragMove,
          onPointerUp: (e: PointerEvent) => {
            dragEnd(e);
            h.onPointerUp?.(e);
          },
          onPointerCancel: () => {
            drag.current = null;
            fingers.current.clear();
            pinch.current = null;
            stopFling(session);
          },
        };

  return (
    <div
      ref={el}
      class={`term ${isFocused ? "focused" : ""} ${cls ?? ""}`}
      style={style}
      // Touch events stop here: xterm's own touch scrolling would scroll a second time.
      onTouchStartCapture={(e) => isFocused && e.stopPropagation()}
      onTouchMoveCapture={(e) => isFocused && e.stopPropagation()}
      {...(isFocused ? focusedHandlers : {})}
    >
      <div ref={screen} class="term-screen" />
      {status === "exited" ? (
        <div class="term-cover term-note" {...onTap(() => session.start(true))}>
          exited · tap to restart
        </div>
      ) : status === "starting" ? (
        <div class="term-cover term-note">starting…</div>
      ) : (
        !isFocused && <div class="term-cover" {...scrolls(interactive ? onTap(() => view.current && focus(view.current)) : {})} />
      )}
    </div>
  );
}
