/**
 * The host API: the one contract between the shell (this folder) and the native side - the phone's launcher (an
 * Android WebView, ShellBridge.kt) or PowOS's desktop host. Calls are async; events come through `on`. A browser
 * without a host gets bridge.ts's mock, so the shell runs anywhere.
 */
export interface App {
  /** Stable id: "a:<package/activity[@profile]>" (Android) or "l:<desktop id>" (Linux / PowOS). */
  key: string;
  label: string;
  /** URL of its icon (the host serves them). */
  icon: string;
  kind: "android" | "linux";
  /** A work-profile app, a clone, or the system's own (not uninstallable). */
  work?: boolean;
  clone?: boolean;
  system?: boolean;
}

/** CSS px; [keyboard] is the soft keyboard's height (0 while it's down). */
export interface Insets { top: number; bottom: number; left: number; right: number; keyboard: number; }

export interface Cell { x: number; y: number; w: number; h: number; }

/** Something on a home page: a widget, a pinned app or a folder of them. */
export interface HomeItem {
  key: string;
  kind: "widget" | "app" | "folder";
  page: number;
  /** Its place on the page's grid; null until placed. */
  cell: Cell | null;
  resizable: boolean;
  minSize: [number, number];
  size: [number, number] | null;
  /** widget */
  name?: string;
  error?: string;
  /** app: its label and the drawer's key for it */
  label?: string;
  app?: string;
  /** folder */
  apps?: { key: string; label: string; app: string }[];
}

export interface Home { columns: number; pages: number[]; items: HomeItem[]; }

/** One entry of PowOS AI's chat; a tool's ok is null while it runs. */
export type ChatItem =
  | { kind: "user" | "assistant"; text: string }
  | { kind: "tool"; name: string; hint: string; ok: boolean | null }
  | { kind: "note"; text: string; error: boolean };
/** The colors in use: the launcher's palette as CSS (background, surface, foreground, muted, accent, border, red, ...), and the theme's own by name (color0-15, cursor, ...). */
export interface ThemeColors {
  name: string;
  light: boolean;
  css: Record<string, string>;
  colors: Record<string, string>;
}
/** A theme to pick: what its swatch shows (background, foreground, accent, red, yellow, green, magenta). */
export interface ThemeChoice {
  name: string;
  title: string;
  colors: Record<string, string>;
}

/** A widget's full-size screen, open over home ([key] null: none). A terminal's is edge to edge, without a title. */
export interface WidgetScreen {
  key: string | null;
  terminal?: boolean;
  title?: string;
}

export interface Chat {
  busy: boolean;
  items: ChatItem[];
}

export interface Bridge {
  /** "android" | "powos" | "mock" */
  host: string;
  apps: {
    list(): Promise<App[]>;
    launch(key: string): Promise<void>;
    info(key: string): Promise<void>;
    uninstall(key: string): Promise<void>;
  };
  usage: {
    /** Keys, last opened first. */
    recent(limit: number): Promise<string[]>;
  };
  /** The shell's own data files (data/*.json), kept by the host. */
  store: {
    get<T = unknown>(name: string): Promise<T | null>;
    set(name: string, value: unknown): Promise<void>;
  };
  /** The home screen, shared with the Compose launcher while both exist. */
  home: {
    get(): Promise<Home>;
    /** Moves or resizes an item (to another page too). */
    place(key: string, cell: Cell, page: number): Promise<void>;
    /** Pins an app (a drawer key) to a page, at a cell if given; returns the item's key. */
    add(app: string, page: number, cell?: Cell): Promise<string>;
    remove(key: string): Promise<void>;
    /** Drops an app item on another app or a folder: into one folder. Returns the folder's key. */
    group(key: string, target: string): Promise<string | null>;
  };
  /**
   * OWL widgets: the host runs them; the page draws their trees, sent as "widget.tree" ({ key, screen, tree }) while
   * watched, and sends back events and sizes. [screen]: the widget's full-screen block instead of its tile.
   */
  widgets: {
    watch(key: string, screen?: boolean): Promise<void>;
    unwatch(key: string, screen?: boolean): Promise<void>;
    /** Runs a handler (onTap, onDrag, onChange) of element [id] with its numbers (x, y, dx, dy in dp). */
    fire(key: string, screen: boolean, id: string, name: string, args: number[]): Promise<void>;
    /** The tile's size: cells (cols, rows) and dp. */
    size(key: string, cols: number, rows: number, width: number, height: number): Promise<void>;
    /** A Canvas's size in dp: its drawing is evaluated at it. */
    canvas(key: string, id: string, width: number, height: number): Promise<void>;
    /** The home page on screen (a page number): widgets on it and beside it run their sources. */
    page(page: number): Promise<void>;
    /** A tap on the tile that no element took: the widget's own onTap (often screen(), opening it full size). */
    tap(key: string): Promise<void>;
    /** The widget screen open now; "widget.screen" brings each change. */
    screen(): Promise<WidgetScreen>;
    closeScreen(): Promise<void>;
  };
  /**
   * PowOS AI: the conversation with PowOS's manager, the one its own app (and the desktop's manager widget) shows.
   * "ai.changed" brings the whole chat ({ busy, items }) as a turn streams in.
   */
  ai: {
    chat(): Promise<Chat>;
    /** Asks it: one turn, streamed into the chat. */
    send(text: string): Promise<void>;
    /** Opens PowOS AI's own app. */
    open(): Promise<void>;
  };
  /**
   * Terminals: a process on a pty, by an id the page picks (views naming one id share it). Bytes are base64 both ways.
   * Output comes as "term.data" ({ id, run, data, end }: [end] the offset after it in the run's output) and its end as
   * "term.exit" ({ id, run, code }); "term.style" says the style changed (the terminal font arrived).
   */
  term: {
    /**
     * Starts [id] unless it runs ([restart]: also if it ended), running [command] (null: PowOS's tmux picker, or a
     * login shell); [owner] is the widget it ends with. Answers its state, with what it wrote lately to start from.
     */
    open(id: string, owner: string | null, command: string | null, cols: number, rows: number, restart?: boolean): Promise<TermState>;
    write(id: string, data: string): Promise<void>;
    resize(id: string, cols: number, rows: number): Promise<void>;
    close(id: string): Promise<void>;
    /** How terminals look: the launcher's terminal font, at [points] (null: the terminal text size). */
    style(points: number | null): Promise<TermStyle>;
  };
  clipboard: {
    read(): Promise<string | null>;
    write(text: string): Promise<void>;
  };
  /** The theme: the colors in use ("theme.changed" brings them again), the ones to pick from, picking one. */
  theme: {
    get(): Promise<ThemeColors>;
    list(): Promise<ThemeChoice[]>;
    pick(name: string): Promise<void>;
  };
  /** The Compose launcher's screens the shell has no own yet: store, themes, style, aur, linux, agents, settings. */
  screens: {
    open(name: string): Promise<void>;
  };
  /** The default coding agent: its name, and the home menu's tasks for it (or the screen that sets one up). */
  agents: {
    default(): Promise<string | null>;
    newWidget(): Promise<"started" | "linux" | "agents">;
    newApp(): Promise<"started" | "linux" | "agents">;
  };
  /**
   * Speech to text (the phone's recognizer; the page's own has none). "speech.state" ({ listening, text, error })
   * as it hears; "speech.done" ({ text }) once it ends; "speech.permission" ({ granted }) after it asked for the mic.
   */
  speech: {
    /** [hold]: listens across pauses until stop(). "asked": it asked for the mic first, nothing started. */
    start(hold: boolean): Promise<"started" | "asked" | "unavailable">;
    stop(): Promise<void>;
    cancel(): Promise<void>;
  };
  keyboard: {
    show(): Promise<void>;
    hide(): Promise<void>;
  };
  system: {
    insets(): Promise<Insets>;
  };
  /**
   * Events: "apps.changed", "home.changed", "widget.tree", "system.back" (Android's Back), "system.home" (Home pressed while home shows), "keyboard.inset" (px, every frame of its slide), "system.insets", "ai.changed" (a Chat), "widget.screen" (a WidgetScreen), "speech.state" / "speech.done" / "speech.permission", "theme.changed" (ThemeColors),
   * "files.changed" ({ path }, for hot reload). Returns an unsubscribe function.
   */
  on(event: string, handler: (data: any) => void): () => void;
}


export interface TermState {
  running: boolean;
  /** The exit status once it ended (-signal if a signal ended it). */
  code: number | null;
  /** Which start of [id] this is: events of an earlier one are stale. */
  run: number;
  /** Its latest output (base64), up to [end], the offset after it. */
  history: string;
  end: number;
}

export interface TermStyle {
  /** Text size, CSS px; the pad around the text, CSS px; Android's font scale (a widget's textSize is in sp). */
  size: number;
  pad: number;
  fontScale: number;
  family: string;
  /** The family's file is there (/_font/terminal/<family>); the Nerd Font symbols are at /_font/symbols. */
  font: boolean;
}

/** A widget's node tree (WidgetTree.kt): props evaluated, colors as CSS, a Canvas's drawing as ops. */
export interface OwlNode {
  k: string;
  id: string;
  p?: Record<string, any>;
  h?: string[];
  c?: OwlNode[];
  ops?: OwlOp[];
}

export interface OwlOp {
  op: string;
  a: any[];
  n?: Record<string, any>;
  c?: OwlOp[];
}

export interface OwlRoot extends OwlNode {
  padding?: number;
  /** The widget has an onTap: a tap on the tile that no element takes runs it (widgets.tap). */
  tap?: boolean;
  background?: string | null;
}

declare global {
  interface Window {
    powos?: Bridge;
    PowosHost?: { call(id: number, method: string, args: string): void };
    __powosHost?: { resolve(id: number, v: unknown): void; reject(id: number, m: string): void; emit(e: string, d: unknown): void };
  }
}
