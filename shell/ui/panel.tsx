/**
 * The desktop's panel (index.html?mode=panel): powos-shell shows it in a layer surface along each screen's bottom
 * edge, with the bar's height kept free of maximized windows (docs/DESKTOP-WEB-SHELL.md). A launcher button, then the
 * taskbar: one button per window - its icon and title, the active one marked, minimized ones dimmed. Clicking a
 * window activates it, or minimizes it when it's the active one; a middle click or its x closes it. An Android app's
 * window carries a small phone mark (the phone's session: scrcpy windows, and stand-ins for apps still on the phone's
 * own screen - clicking one moves the app into a window here). The launcher opens above the bar: the page asks the
 * host for a taller surface while it's open (panel.height) and gives it back when it closes.
 *
 * Desktop mode (docs/DESKTOP-KWIN-NATIVE.md phase 1; app.tsx loaded state.ts for it): the bar starts with the phone
 * dock's pinned apps (the same "dock" store key and AppCell as ui/home.tsx's Dock), and the launcher is the drawer's
 * own app list (drawer.tsx AppList / findApps). Meta and KWin's swipe-up reach it as "launcher.toggle" (powos-shell's
 * org.powos.Shell /Launcher toggle). Only powos-shell serves this page: the phone's Android shell never renders it.
 */
import { useEffect, useMemo, useRef, useState } from "preact/hooks";
import { powos } from "../bridge.ts";
import type { App, DesktopWindow } from "../types.ts";
import { apps as allApps, byKey, dock } from "../state.ts";
import { AppCell } from "./apps.tsx";
import { AppList, findApps } from "./drawer.tsx";

/** The desktop-mode panel: PowOS's dock and drawer (only powos-shell's host is "powos"). */
const docked = powos.host === "powos";

/** How tall the surface gets while the launcher is open (CSS px, the bar included). */
const OPEN_HEIGHT = 520;

export function Panel() {
  const [windows, setWindows] = useState<DesktopWindow[]>([]);
  const [launcher, setLauncher] = useState(false);
  useEffect(() => {
    const off = powos.on("windows.changed", setWindows);
    powos.windows.list().then(setWindows, (e) => console.warn("windows.list", e));
    return off;
  }, []);
  // Meta / swipe-up (org.powos.Shell /Launcher toggle): open or close, as the start button does.
  const shown = useRef(launcher);
  shown.current = launcher;
  useEffect(() => powos.on("launcher.toggle", () => (shown.current ? close() : open())), []);

  const open = async () => {
    await powos.panel.height(OPEN_HEIGHT);
    setLauncher(true);
  };
  const close = () => {
    setLauncher(false);
    powos.panel.height(0);
  };

  const click = (w: DesktopWindow) => {
    if (w.active && !w.minimized) powos.windows.minimize(w.id);
    else powos.windows.activate(w.id);
  };

  return (
    <div class="panel">
      {/* The room above the bar is the launcher's while it's open; a click on what's left of it closes it. */}
      {launcher && (
        <div class="panel-room" onPointerDown={(e) => e.target === e.currentTarget && close()}>
          <Launcher close={close} />
        </div>
      )}
      <div class="panel-bar">
        <button class={`panel-start ${launcher ? "open" : ""}`} title="Applications" onClick={() => (launcher ? close() : open())}>
          <svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true">
            <rect x="3" y="3" width="7" height="7" rx="1.5" />
            <rect x="14" y="3" width="7" height="7" rx="1.5" />
            <rect x="3" y="14" width="7" height="7" rx="1.5" />
            <rect x="14" y="14" width="7" height="7" rx="1.5" />
          </svg>
        </button>
        {docked && (
          <div class="panel-dock dock-page">
            {dock.value
              .map((k) => byKey.value.get(k))
              .filter((a) => a != null)
              .map((app) => (
                <AppCell key={app.key} app={app} labels={false} />
              ))}
          </div>
        )}
        <div class="panel-tasks" role="list">
          {windows.map((w) => (
            <button
              key={w.id}
              role="listitem"
              class={`panel-task${w.active ? " active" : ""}${w.minimized ? " minimized" : ""}`}
              title={w.title}
              onClick={() => click(w)}
              onAuxClick={(e) => e.button === 1 && powos.windows.close(w.id)}
            >
              <span class="panel-task-icon">
                <img src={w.icon} alt="" width={24} height={24} draggable={false} />
                {w.android && <i class={`panel-task-android${w.onPhone ? " on-phone" : ""}`} title={w.onPhone ? "On the phone's screen" : "Android app"} />}
              </span>
              <span class="panel-task-title">{w.title || w.appName}</span>
              {!w.onPhone && (
                <span
                  class="panel-task-close"
                  role="button"
                  aria-label={`Close ${w.title || w.appName}`}
                  onClick={(e) => {
                    e.stopPropagation();
                    powos.windows.close(w.id);
                  }}
                >
                  ×
                </span>
              )}
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}

/** The apps, searchable by name; Enter starts the first match, Escape closes. */
function Launcher({ close }: { close: () => void }) {
  const [apps, setApps] = useState<App[]>([]);
  const [query, setQuery] = useState("");
  const input = useRef<HTMLInputElement>(null);
  useEffect(() => {
    const load = () => powos.apps.list().then(setApps, (e) => console.warn("apps.list", e));
    load();
    input.current?.focus();
    return powos.on("apps.changed", load);
  }, []);
  const shown = useMemo(() => {
    if (docked) return query.trim() ? findApps(query) : allApps.value;
    const q = query.trim().toLowerCase();
    return q ? apps.filter((a) => a.label.toLowerCase().includes(q)) : apps;
  }, [apps, query, docked && allApps.value]);
  const launch = (a: App) => {
    powos.apps.launch(a.key);
    close();
  };
  if (docked)
    return (
      <div class="panel-launcher panel-drawer" onKeyDown={(e) => e.key === "Escape" && close()}>
        <input
          ref={input}
          class="panel-search"
          placeholder="Search apps"
          value={query}
          onInput={(e) => setQuery(e.currentTarget.value)}
          onKeyDown={(e) => e.key === "Enter" && shown[0] && launch(shown[0])}
        />
        <div class="drawer" onClick={(e) => (e.target as Element).closest(".app") && close()}>
          <AppList found={query.trim() ? shown : null} />
        </div>
      </div>
    );
  return (
    <div class="panel-launcher" onKeyDown={(e) => e.key === "Escape" && close()}>
      <input
        ref={input}
        class="panel-search"
        placeholder="Search apps"
        value={query}
        onInput={(e) => setQuery(e.currentTarget.value)}
        onKeyDown={(e) => e.key === "Enter" && shown[0] && launch(shown[0])}
      />
      <div class="panel-apps">
        {shown.map((a) => (
          <button key={a.key} class="panel-app" title={a.label} onClick={() => launch(a)}>
            <img src={a.icon} alt="" width={40} height={40} draggable={false} loading="lazy" />
            <span>{a.label}</span>
          </button>
        ))}
      </div>
    </div>
  );
}
