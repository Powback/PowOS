/**
 * __NAME__: a UI-only PowOS app ("module": null in powos-app.json) - a page and a home widget, no database of its own,
 * so it builds and installs anywhere, with no Rust and no SpacetimeDB (`powos app new <name> --template ui`). Its own
 * state lives in the shell's storage (useStored below), shared live by the page and the widget.
 *
 * Wanting a database later (rows synced across devices, reducers): make a module app (`powos app new <name>`) and move
 * the UI over; its ui/lib/app.ts adds useApp(host) with useTable / useReducer.
 */
import { useEffect, useState } from "preact/hooks";

/** What the shell hands a page or a widget (shell/apps/stdb.ts IslandHost); a UI-only app uses no database. */
export interface Host {
  /** Opens an installed app's full-screen page (this one's: openApp(app)). */
  openApp?(id: string): void;
  /** Opens a link outside the shell (the browser). */
  openUrl?(url: string): Promise<unknown>;
  /** The element on screen, home shown and uncovered: stop animating without it. */
  useOnScreen?(ref: { current: Element | null }): boolean;
  /** Nothing else open or moving on home: animate only then. */
  useQuiet?(): boolean;
  /**
   * The devices and services powos-app.json declares in "net" (exact hosts, or "lan"), reached by the PowOS app itself:
   * no CORS, secrets kept per app. An older PowOS app has none: check for it.
   */
  net?: {
    fetch(app: string, url: string, init?: { method?: string; headers?: Record<string, string>; body?: string | object }): Promise<{
      status: number;
      body: string;
      json<T = any>(): T;
    }>;
  };
}

/** Props of a page (ui/pages/*.tsx) and a widget (ui/widgets/*.tsx). */
export interface Props {
  host: Host;
  /** The app's id. */
  app: string;
  /** The app's UI dir as a URL ("./_app/<id>/"), for its own files: images, sounds. */
  base: string;
  /** A widget's size on home in cells, [w, h]. */
  cells?: [number, number];
  /** A page: closes it (Back does too). */
  close?: () => void;
}

const changed = (app: string, key: string) => `powos-app:${app}:${key}`;

function read<T>(app: string, key: string, initial: T): T {
  try {
    const v = localStorage.getItem(changed(app, key));
    return v === null ? initial : (JSON.parse(v) as T);
  } catch {
    return initial;
  }
}

/**
 * A value kept for this app on this device (the shell's storage), live in every page and widget of it that shows:
 *   const [count, setCount] = useStored(app, "count", 0);
 */
export function useStored<T>(app: string, key: string, initial: T): [T, (v: T) => void] {
  const [value, setValue] = useState<T>(() => read(app, key, initial));
  useEffect(() => {
    const on = () => setValue(read(app, key, initial));
    window.addEventListener(changed(app, key), on);
    return () => window.removeEventListener(changed(app, key), on);
  }, [app, key]);
  const set = (v: T) => {
    try {
      localStorage.setItem(changed(app, key), JSON.stringify(v));
    } catch {
      // storage full or off: the value still shows until the page closes
    }
    setValue(v);
    window.dispatchEvent(new Event(changed(app, key)));
  };
  return [value, set];
}
