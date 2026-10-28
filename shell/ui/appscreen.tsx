/**
 * A PowOS app open full screen (apps/pages.ts): its page module (powos-app.json "page", from its installed UI at
 * ./_app/<id>/) imported into this page and rendered over home with the host - its database's connection and live rows,
 * shared with its widgets on home. Back, Home or the page's own close put it away.
 *
 * Hot reload: its UI changing on disk gives the module a new URL (appRev); the new one is imported and swapped in once
 * it's loaded, the old one on screen until then - no blank frame, the connection kept.
 *
 * Trusted, as islands are: the page runs with the shell's bridge. Third-party apps get the isolated kind (their own
 * origin, a scoped bridge - docs/POWOS-APPS-FEASIBILITY.md section 3).
 */
import { Component, type ComponentType } from "preact";
import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";
import { appRev, appView, closeApp, installedApps, manifestOf, moduleUrl, openApp, retryDelay, retryUrl } from "../apps/pages.ts";
import { watchRegistry } from "../apps/registry.ts";
import { host } from "../apps/stdb.ts";
import { addIsland } from "./apppicker.tsx";

declare function importShim(url: string): Promise<{ default: ComponentType<any> }>;

/**
 * For tests and agents over devtools (CDP): open/close an app, add a widget, read the hot-reload revisions and the last
 * page load ({ id, url, ms, at }) - devtools' own importShim() loads a second copy of the modules, not these.
 */
(window as any).__powosApps = { openApp, closeApp, addIsland, appView, appRev, installedApps, loaded: null };

const MS = 220;
const EASE = "cubic-bezier(0.2, 0.8, 0.2, 1)";

/** Its touches are its own: home's swipes under it don't see them. */
const own = {
  onTouchStart: (e: TouchEvent) => e.stopPropagation(),
  onTouchMove: (e: TouchEvent) => e.stopPropagation(),
  onPointerDown: (e: PointerEvent) => e.stopPropagation(),
};

/** A failure, reported (console.error: the shell's error capture reads it from the console) and shown. */
function fail(id: string, what: string, e: unknown) {
  const detail = String((e as Error)?.message ?? e);
  console.error(`[powos-app] ${id}: ${what}: ${detail}`, e);
  return detail;
}

class Boundary extends Component<{ id: string; name: string; children?: any }, { error: string | null }> {
  state = { error: null as string | null };
  componentDidCatch(e: unknown) {
    this.setState({ error: fail(this.props.id, "page crashed", e) });
  }
  render() {
    return this.state.error ? <Fault name={this.props.name} error={this.state.error} /> : this.props.children;
  }
}

/** What went wrong in words, the detail small under it, and the way back. */
function Fault({ name, error }: { name: string; error: string }) {
  const missing = /404|not found|failed to fetch|not installed/i.test(error);
  return (
    <div style={{ padding: "16px 20px", display: "flex", flexDirection: "column", gap: "14px", height: "100%", boxSizing: "border-box" }}>
      <button type="button" class="session-back" onClick={closeApp} aria-label="back">
        ‹
      </button>
      <div style={{ fontSize: "1.2em", fontWeight: 600 }}>{name} couldn't open</div>
      <div style={{ opacity: 0.8 }}>
        {missing ? "Its page isn't installed on this device. Install the app again (powos app install <its folder>)." : "Its page stopped with an error. Fix it and save: the page reloads by itself."}
      </div>
      <div class="muted" style={{ fontSize: "var(--text-small)", whiteSpace: "pre-wrap", wordBreak: "break-word" }}>
        {error}
      </div>
    </div>
  );
}

export function AppScreen() {
  // Mounted with home: the registry's apps live from here on (the drawer's PowOS apps).
  useEffect(watchRegistry, []);
  const v = appView.value;
  const box = useRef<HTMLDivElement>(null);
  const app = v ? installedApps.value.find((a) => a.id === v.id) : undefined;
  const page = app ? manifestOf(app).page : undefined;
  const entry = page?.entry;
  const base = app && entry ? moduleUrl(app.id, entry, app.version) : null;
  const [tries, setTries] = useState(0);
  useEffect(() => setTries(0), [base]);
  // Tried again while it fails (a 404 mid-install, an error being fixed): never a dead page.
  const url = base ? retryUrl(base, tries) : null;
  const [mod, setMod] = useState<{ id: string; url: string; c: ComponentType<any> } | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    if (!url || !v || v.closing) return;
    let live = true;
    let timer = 0;
    const t0 = performance.now();
    importShim(url).then(
      (m) => {
        if (!live) return;
        setMod({ id: v.id, url, c: m.default });
        setError(null);
        (window as any).__powosApps.loaded = { id: v.id, url, ms: Math.round(performance.now() - t0), at: Date.now() };
      },
      (e) => {
        if (!live) return;
        setError(fail(v.id, `page ${url} didn't load`, e));
        timer = window.setTimeout(() => live && setTries((n) => n + 1), retryDelay(tries));
      },
    );
    return () => {
      live = false;
      clearTimeout(timer);
    };
  }, [url, v?.closing]);
  // Opened: from where it was tapped (or a little below) to the screen.
  useLayoutEffect(() => {
    const el = box.current;
    if (!el || !v || v.closing) return;
    el.style.transition = "none";
    el.style.opacity = "0";
    el.style.transform = v.from ? `translate(${v.from.left + v.from.width / 2 - innerWidth / 2}px, ${v.from.top + v.from.height / 2 - innerHeight / 2}px) scale(0.2)` : "translateY(6%) scale(0.96)";
    void el.offsetWidth;
    el.style.transition = `transform ${MS}ms ${EASE}, opacity ${MS / 2}ms linear`;
    el.style.transform = "none";
    el.style.opacity = "1";
  }, [v?.id, !!v]);
  // Closing: away, then gone - its module unmounted, so its database lets go (5 s later, if nothing else uses it).
  useLayoutEffect(() => {
    const el = box.current;
    if (!el || !v?.closing) return;
    el.style.transform = "translateY(6%) scale(0.96)";
    el.style.opacity = "0";
    const t = window.setTimeout(() => {
      if (appView.value?.closing) appView.value = null;
      setMod(null);
    }, MS);
    return () => clearTimeout(t);
  }, [v?.closing]);
  if (!v) return null;
  const C = mod && mod.id === v.id ? mod.c : null;
  const name = app?.name ?? v.id;
  return (
    <div
      ref={box}
      class={page?.background === "own" ? "app-screen sheet" : "app-screen tile sheet"}
      data-app={v.id}
      style={{
        position: "fixed",
        zIndex: 15,
        inset: 0,
        paddingTop: "var(--inset-top, 0px)",
        paddingBottom: "max(var(--inset-bottom, 0px), var(--inset-keyboard, 0px))",
        paddingLeft: "var(--inset-left, 0px)",
        paddingRight: "var(--inset-right, 0px)",
        boxSizing: "border-box",
        color: "var(--color-foreground)",
        display: "flex",
        flexDirection: "column",
        overflow: "hidden",
      }}
      {...own}
    >
      {error && !(mod && mod.id === v.id) ? (
        <Fault name={name} error={error} />
      ) : !app && installedApps.value.length ? (
        <Fault name={name} error={`${v.id}: not installed`} />
      ) : C ? (
        <div style={{ flex: 1, minHeight: 0, position: "relative" }}>
          <Boundary key={mod!.url} id={v.id} name={name}>
            <C route={v.route} host={host} app={v.id} base={`./_app/${v.id}/`} close={closeApp} />
          </Boundary>
        </div>
      ) : null}
    </div>
  );
}
