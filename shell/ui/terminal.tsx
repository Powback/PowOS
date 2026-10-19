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
import { powos } from "../bridge.ts";
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
    background: v("--term-background"),
    foreground: v("--term-foreground"),
    cursor: v("--term-cursor"),
    cursorAccent: v("--term-background"),
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
  const fallback = getComputedStyle(document.documentElement).getPropertyValue("--font").trim() || "monospace";
  const symbols = (await loadFont("PowOS Symbols", "/_font/symbols")) ? '"PowOS Symbols", ' : "";
  const face = `PowOS Terminal ${style.family}`;
  const own = style.font && (await loadFont(face, `/_font/terminal/${encodeURIComponent(style.family)}`));
  return `${own ? JSON.stringify(face) + ", " : ""}${symbols}${fallback}`;
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

  constructor(
    readonly id: string,
    public owner: string | null,
    public command: string | null,
  ) {
    this.holder.className = "term-holder";
    this.term = new Terminal({
      scrollback: SCROLLBACK,
      theme: theme(),
      fontFamily: "monospace",
      cursorBlink: false,
      allowProposedApi: false,
    });
    this.term.loadAddon(this.fit);
    this.term.open(this.holder);
    this.term.onData((d) => this.send(modify(d)));
    // Mouse reports in the X10 encoding: bytes, not text.
    this.term.onBinary((d) => this.sendBytes(Uint8Array.from(d, (c) => c.charCodeAt(0) & 0xff)));
    // The pty follows once the size settles: a screen opening or closing passes through a few (the keys docking, the
    // keyboard sliding), and every one was a full tmux redraw over the bridge. xterm itself refits at once.
    this.term.onResize(({ cols, rows }) => {
      clearTimeout(this.resizeTimer);
      this.resizeTimer = window.setTimeout(() => {
        if (this.status.value === "running") powos.term.resize(this.id, cols, rows);
      }, RESIZE_SETTLE_MS);
    });
  }

  send(text: string) {
    if (text) this.sendBytes(utf8.encode(text));
  }

  private sendBytes(bytes: Uint8Array) {
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
    if (this.status.value === "running") powos.term.resize(this.id, this.term.cols, this.term.rows);
  }

  /** Bytes ending at offset [end] of the run's output: what's been shown already is skipped. */
  private output(bytes: Uint8Array, end: number) {
    if (end <= this.seen) return;
    const start = end - bytes.length;
    this.term.write(start < this.seen ? bytes.subarray(this.seen - start) : bytes);
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
    this.term.options.fontSize = view.textSize != null ? view.textSize * style.fontScale : style.size;
    this.term.options.fontFamily = await fontFamily(style);
    this.refit();
  }

  /** Fits the xterm to its view (cols and rows to the pty): a view that isn't laid out (0 wide) leaves it. */
  refit() {
    if (!this.holder.isConnected || !this.holder.clientWidth || !this.holder.clientHeight) return;
    this.fit.fit();
  }

  restyle() {
    this.term.options.theme = theme();
    this.show();
  }
}

/** How long a terminal's size holds before the pty takes it. */
const RESIZE_SETTLE_MS = 120;

/** What the fit addon leaves free for a scrollbar (addon-fit 0.11: overviewRuler.width, else 14). */
const FIT_SCROLLBAR = 14;

const sessions = new Map<string, Session>();

powos.on("term.data", (e: { id: string; run: number; data: string; end: number }) => sessions.get(e.id)?.data(e));
powos.on("term.exit", (e: { id: string; run: number; code: number }) => sessions.get(e.id)?.exit(e));
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
/** The keyboard was put away by the extra keys' own key (not Back): the terminal keeps the keys. */
let ownHide = false;
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
  ownHide = false;
  document.documentElement.classList.add("term-focus");
  mountExtraKeys();
  s.term.focus();
  powos.keyboard.show();
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
  if (keyboardUp && i.keyboard === 0 && !ownHide && screen.value.key == null) release();
  keyboardUp = i.keyboard > 0;
  if (keyboardUp) ownHide = false;
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
        navigator.vibrate?.(5);
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
        navigator.vibrate?.(5);
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

/** The keyboard's own key, at either end: puts it away (the terminal keeps the keys) or brings it back. */
function KeyboardKey() {
  const up = extraKeysState.value.keyboard;
  return (
    <button
      class="term-key keyboard"
      onPointerDown={(e) => {
        e.preventDefault();
        if (up) {
          ownHide = true;
          powos.keyboard.hide();
        } else {
          focusedSession()?.term.focus();
          powos.keyboard.show();
        }
      }}
    >
      <svg viewBox="0 0 24 24">
        <rect x="2.5" y="6" width="19" height="12" rx="2" />
        <path d="M6 10h.01M9.5 10h.01M13 10h.01M16.5 10h.01M6 13.5h.01M18 13.5h.01M9 14.5h6" />
      </svg>
    </button>
  );
}

function ExtraKeys() {
  if (!focused.value) return null;
  return (
    <div class="term-extra tile">
      <KeyboardKey />
      <div class="term-rows">
        {ROWS.map((row, i) => (
          <div class="term-row" key={i}>
            {row.map((k) => (k === "ctrl" ? <Sticky key={k} name={k} mod={ctrl} /> : k === "alt" ? <Sticky key={k} name={k} mod={alt} /> : <Cap key={k.key} k={k} />))}
          </div>
        ))}
      </div>
      <KeyboardKey />
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
  class?: string;
  style?: Record<string, string | number | undefined>;
}

export function TerminalView({ id, owner = null, command = null, interactive = true, fontSize = null, textSize = null, focus: autoFocus = false, class: cls, style }: TerminalProps) {
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

  // Focused, its touches are the terminal's: kept from the home screen's swipes. A drag scrolls - the scrollback, or
  // what the program does with the wheel (tmux's mouse: its history; a full-screen program: arrow keys), which xterm
  // works out from a wheel event; a tap is a click (the browser's mouse events, which xterm reports to tmux).
  const drag = useRef<{ y: number; id: number; rest: number } | null>(null);
  const focusedHandlers = {
    onPointerDown: (e: PointerEvent) => {
      e.stopPropagation();
      drag.current = { y: e.clientY, id: e.pointerId, rest: 0 };
    },
    onPointerMove: (e: PointerEvent) => {
      const d = drag.current;
      if (!d || d.id !== e.pointerId || e.pointerType === "mouse") return;
      const dy = e.clientY - d.y;
      d.y = e.clientY;
      const t = session.term;
      if (t.modes.mouseTrackingMode === "none" && t.buffer.active.type === "normal") {
        // xterm's own scrolling reads the wheel's legacy wheelDelta, which an event made here doesn't have.
        const cell = session.holder.clientHeight / t.rows;
        d.rest += dy;
        const lines = Math.trunc(d.rest / cell);
        if (lines) {
          t.scrollLines(-lines);
          d.rest -= lines * cell;
        }
        return;
      }
      t.element?.querySelector(".xterm-screen")?.dispatchEvent(
        new WheelEvent("wheel", { deltaY: -dy, deltaMode: WheelEvent.DOM_DELTA_PIXEL, clientX: e.clientX, clientY: e.clientY, bubbles: true, cancelable: true }),
      );
    },
    onPointerUp: () => (drag.current = null),
    onPointerCancel: () => (drag.current = null),
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
        !isFocused && <div class="term-cover" {...(interactive ? onTap(() => view.current && focus(view.current)) : {})} />
      )}
    </div>
  );
}
