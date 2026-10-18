/**
 * The host API: the one contract between the shell (this folder) and the native side - the phone's launcher
 * (an Android WebView) or PowOS's desktop host. Calls are async; events come through `on`. A browser without a host
 * gets bridge.js's mock, so the shell runs anywhere.
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
  };
  keyboard: {
    show(): Promise<void>;
    hide(): Promise<void>;
  };
  system: {
    insets(): Promise<Insets>;
  };
  /**
   * Events: "apps.changed", "home.changed", "widget.tree", "keyboard.inset" (px, every frame of its slide), "system.insets",
   * "files.changed" ({ path }, for hot reload). Returns an unsubscribe function.
   */
  on(event: string, handler: (data: any) => void): () => void;
}

declare global {
  interface Window { powos?: Bridge; }
}
