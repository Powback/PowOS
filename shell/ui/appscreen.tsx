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
import { appRev, appView, closeApp, installedApps, manifestOf, moduleUrl, openApp } from "../apps/pages.ts";
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

class Boundary extends Component<{ children?: any }, { error: string | null }> {
  state = { error: null as string | null };
  componentDidCatch(e: unknown) {
    this.setState({ error: String((e as Error)?.stack ?? (e as Error)?.message ?? e) });
  }
  render() {
    return this.state.error ? <Fault error={this.state.error} /> : this.props.children;
  }
}

function Fault({ error }: { error: string }) {
  return (
    <div style={{ padding: "16px", display: "flex", flexDirection: "column", gap: "12px" }}>
      <button type="button" class="session-back" onClick={closeApp}>
        ‹
      </button>
      <pre style={{ whiteSpace: "pre-wrap", color: "var(--color-red, #e66)", fontSize: "var(--text-small)" }}>{error}</pre>
    </div>
  );
}

export function AppScreen() {
  // Mounted with home: the registry's apps live from here on (the drawer's PowOS apps).
  useEffect(watchRegistry, []);
  const v = appView.value;
  const box = useRef<HTMLDivElement>(null);
  const app = v ? installedApps.value.find((a) => a.id === v.id) : undefined;
  const entry = app ? manifestOf(app).page?.entry : undefined;
  const url = app && entry ? moduleUrl(app.id, entry, app.version) : null;
  const [mod, setMod] = useState<{ id: string; url: string; c: ComponentType<any> } | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    if (!url || !v || v.closing) return;
    let live = true;
    const t0 = performance.now();
    importShim(url).then(
      (m) => {
        if (!live) return;
        setMod({ id: v.id, url, c: m.default });
        setError(null);
        (window as any).__powosApps.loaded = { id: v.id, url, ms: Math.round(performance.now() - t0), at: Date.now() };
      },
      (e) => live && setError(String(e?.message ?? e)),
    );
    return () => {
      live = false;
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
  return (
    <div
      ref={box}
      class="app-screen"
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
        background: "var(--color-background)",
        color: "var(--color-foreground)",
        display: "flex",
        flexDirection: "column",
        overflow: "hidden",
      }}
      {...own}
    >
      {error ? (
        <Fault error={error} />
      ) : !app && installedApps.value.length ? (
        <Fault error={`${v.id}: not installed`} />
      ) : C ? (
        <div style={{ flex: 1, minHeight: 0, position: "relative" }}>
          <Boundary key={mod!.url}>
            <C host={host} app={v.id} base={`./_app/${v.id}/`} close={closeApp} />
          </Boundary>
        </div>
      ) : null}
    </div>
  );
}
