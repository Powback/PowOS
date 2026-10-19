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
export interface Insets {
  top: number;
  bottom: number;
  left: number;
  right: number;
  keyboard: number;
}

export interface Cell {
  x: number;
  y: number;
  w: number;
  h: number;
}

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

export interface Home {
  columns: number;
  pages: number[];
  items: HomeItem[];
}

/** The quick settings that switch here: on or off, null where the phone can't (no flashlight, no access). */
export interface QuickState {
  torch: boolean | null;
  dnd: boolean | null;
  /** The control center's tiles, in the phone's own order. */
  tiles: QuickTile[];
  /** 0..1 (perceptual), and whether the phone sets it itself. */
  brightness: { value: number; auto: boolean };
  /** Media volume 0..1; the ringer: 0 silent, 1 vibrate, 2 ring. */
  volume: { value: number; ringer: number };
}

/** What's playing: nothing (playing false, no title) or a track. art: an id for /_media/<id>. */
export interface MediaState {
  available: boolean;
  playing: boolean;
  title?: string | null;
  artist?: string | null;
  album?: string | null;
  app?: string;
  package?: string;
  position?: number | null;
  duration?: number | null;
  art?: string | null;
}

/** One control center tile: a switch (on true/false) or an action/page (on null). */
export interface QuickTile {
  id: string;
  label: string;
  on: boolean | null;
  /** A line under the label (the carrier). */
  detail: string | null;
  /** A third-party tile's app (custom(...) ids). */
  app?: string;
}

/** The screen the assistant was opened over. */
export interface AssistScreen {
  text: string;
  screenshot: string | null;
}

/** Something an agent told the user (time: Unix seconds). */
export interface AgentMail {
  from: string;
  text: string;
  time: number;
}
/** An agent at work: a tmux session in PowOS; [title] its pane's (Claude Code's: the task, a spinner while working). */
export interface AgentSession {
  name: string;
  activity: number;
  attached: boolean;
  title: string;
  path: string;
  command: string;
}

/** One entry of PowOS AI's chat; a tool's ok is null while it runs. */
export type ChatItem =
  | { kind: "user" | "assistant"; text: string }
  | { kind: "tool"; name: string; hint: string; ok: boolean | null }
  | { kind: "note"; text: string; error: boolean };
/** A notification as the panel shows it; [icon] its app's drawer icon, [time] Unix seconds. */
export interface PhoneNotification {
  key: string;
  app: string;
  icon: string | null;
  title: string;
  text: string;
  time: number;
  clearable: boolean;
  profile: string | null;
}
/**
 * A recent task, as the switcher shows it: [id] the system's, [key] and [icon] its app's in the drawer (null when it
 * isn't there), [snapshot] its last frame (a new URL each listing).
 */
export interface RecentTask {
  id: number;
  label: string;
  key: string | null;
  icon: string | null;
  snapshot: string;
}
/** [available]: the launcher may read them (it has notification access). */
export interface NotificationList {
  available: boolean;
  items: PhoneNotification[];
}

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
    /** Gives items without a cell (a store widget, an app pinned from a menu) the first free spot on a grid this big. */
    arrange(cols: number, rows: number): Promise<void>;
  };
  /**
   * OWL widgets: the host runs them; the page draws their trees, sent as "widget.tree" ({ key, screen, tree }) while
   * watched, and sends back events and sizes. [screen]: the widget's full-screen block instead of its tile.
   */
  widgets: {
    watch(key: string, screen?: boolean): Promise<void>;
    unwatch(key: string, screen?: boolean): Promise<void>;
    /** Runs a handler (onTap, onDrag, onChange) of element [id] with its numbers (x, y, dx, dy in dp). */
    fire(
      key: string,
      screen: boolean,
      id: string,
      name: string,
      args: number[],
    ): Promise<void>;
    /** The tile's size: cells (cols, rows) and dp. */
    size(
      key: string,
      cols: number,
      rows: number,
      width: number,
      height: number,
    ): Promise<void>;
    /** A Canvas's size in dp: its drawing is evaluated at it. */
    canvas(
      key: string,
      id: string,
      width: number,
      height: number,
    ): Promise<void>;
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
    /** What agents told the user lately, newest first ("ai.mail" brings it again). */
    mail(): Promise<AgentMail[]>;
    /** Asks for the agents at work (PowOS's tmux sessions); they come as "ai.sessions" (AgentSession[]). */
    sessions(): Promise<void>;
    /** Opens a terminal on one of them. */
    attach(name: string): Promise<void>;
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
    open(
      id: string,
      owner: string | null,
      command: string | null,
      cols: number,
      rows: number,
      restart?: boolean,
    ): Promise<TermState>;
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
  /** The phone's notifications, for the launcher's own panel; "notifications.changed" brings the list again. */
  notifications: {
    list(): Promise<NotificationList>;
    open(key: string): Promise<void>;
    dismiss(key: string): Promise<void>;
    clearAll(): Promise<void>;
    /** Opens the setting that grants the launcher notification access. */
    access(): Promise<void>;
  };
  /**
   * The assistant's screen (index.html?mode=assist, over another app): what that app's screen showed - its text, an
   * outline, and a screenshot URL ("assist.context" brings them as they arrive) - and closing the assistant.
   */
  assist: {
    screen(): Promise<AssistScreen | null>;
    close(): Promise<void>;
    /** Saves an image for PowOS AI to look at (a cut-out region as a data: URL, or null: the whole screen); its path. */
    attach(image: string | null): Promise<string | null>;
    /** Live mode: the screen a frame a second (Android asks for consent); "assist.live" brings its state. */
    live(on: boolean): Promise<void>;
    liveState(): Promise<{ on: boolean; frames: number }>;
    /** The last moments that changed, tiled into one image where PowOS sees it; its path (null: nothing yet). */
    filmstrip(): Promise<string | null>;
    /** Where the page takes touches (live mode: its bar, CSS px); null: everywhere. */
    touchable(
      rect: { left: number; top: number; width: number; height: number } | null,
    ): Promise<void>;
  };
  /** The lock screen's face (index.html?mode=lock): unlocking is Android's (its PIN pad, the fingerprint). */
  lock: {
    unlock(): Promise<void>;
  };
  /**
   * The control center (and the notification panel's row): every tile the phone's own control center has, switched
   * here, and its sliders. "qs.changed" brings the state again.
   */
  /** What's playing ("media.changed" brings it again once asked): the control center's media card. */
  media: {
    state(): Promise<MediaState>;
    control(
      command: "toggle" | "play" | "pause" | "next" | "previous" | "open",
    ): Promise<void>;
    /** The phone's output picker (speaker, Bluetooth, cast) for that app's audio. */
    output(pkg?: string): Promise<void>;
  };
  qs: {
    state(): Promise<QuickState>;
    /** A tile tapped: a switch flipped, an action run (screenshot, lock), a page opened. */
    toggle(name: string): Promise<QuickState>;
    /** Android's own page for a tile (its long press), or wifi / bluetooth / internet / settings. */
    open(name: string): Promise<void>;
    /** A slider: "brightness" / "volume" 0..1, "auto-brightness" 0/1, "ringer" 0..1 (silent, vibrate, ring). */
    set(
      name: "brightness" | "volume" | "auto-brightness" | "ringer",
      value: number,
    ): Promise<QuickState>;
  };
  /**
   * The shade (index.html?mode=shade, in PowOS's system window above the status bar - the native shade host): the
   * host drives the pull ("shade.drag" { q: 0..1 } while the finger is on the top edge, "shade.settle" { open }), and
   * hears when the page closed it.
   */
  shade: {
    closed(): Promise<void>;
  };
  /** Android's recent tasks (the host is the recents provider): newest first; switching to one; removing one. */
  tasks: {
    list(): Promise<RecentTask[]>;
    /** Brings the task back (the switcher goes away); false if it's gone. */
    open(id: number): Promise<boolean>;
    remove(id: number): Promise<boolean>;
  };
  /**
   * The switcher (index.html?mode=switcher, the system's recents screen): "switcher.shown" ({ from: the task it was
   * opened over, or null }) each time it comes up, "switcher.toggle" when the overview button is pressed again.
   */
  switcher: {
    /** Away: what was under it shows again. */
    close(): Promise<void>;
    home(): Promise<void>;
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
    /** The battery: level 0-100 (null when unknown) and whether it's charging. */
    battery(): Promise<{ level: number | null; charging: boolean }>;
    /** Pulls Android's notification shade down ([open], the default) or puts it away. */
    notifications(open?: boolean): Promise<boolean>;
  };
  /**
   * Events: "apps.changed", "home.changed", "widget.tree", "system.back" (Android's Back), "system.home" (Home pressed while home shows), "keyboard.inset" (px, every frame of its slide), "system.insets", "ai.changed" (a Chat), "ai.mail" (AgentMail[]), "assist.context" (AssistScreen), "shade.drag" ({ q }), "shade.panel" ({ panel: "notifications" | "control" }), "media.changed" (MediaState), "qs.changed" (QuickState), "lock.shown" (the face shown again), "shade.settle" ({ open }), "switcher.shown" ({ from }), "switcher.toggle", "ai.sessions" (AgentSession[]), "widget.screen" (a WidgetScreen), "speech.state" / "speech.done" / "speech.permission", "theme.changed" (ThemeColors), "notifications.changed" (NotificationList),
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
    __powosHost?: {
      resolve(id: number, v: unknown): void;
      reject(id: number, m: string): void;
      emit(e: string, d: unknown): void;
    };
  }
}
