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

export interface Insets { top: number; bottom: number; left: number; right: number; }

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
  keyboard: {
    show(): Promise<void>;
    hide(): Promise<void>;
  };
  system: {
    insets(): Promise<Insets>;
  };
  /**
   * Events: "apps.changed", "keyboard.inset" (px, every frame of its slide), "system.insets",
   * "files.changed" ({ path }, for hot reload). Returns an unsubscribe function.
   */
  on(event: string, handler: (data: any) => void): () => void;
}

declare global {
  interface Window { powos?: Bridge; }
}
