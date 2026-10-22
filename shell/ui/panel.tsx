/**
 * The desktop's panel (index.html?mode=panel): powos-shell shows it in a layer surface along each screen's bottom
 * edge, with the bar's height kept free of maximized windows (docs/DESKTOP-WEB-SHELL.md). A launcher button, then the
 * taskbar: one button per window - its icon and title, the active one marked, minimized ones dimmed. Clicking a
 * window activates it, or minimizes it when it's the active one; a middle click or its x closes it. An Android app's
 * window carries a small phone mark (the phone's session: scrcpy windows, and stand-ins for apps still on the phone's
 * own screen - clicking one moves the app into a window here). The launcher opens above the bar: the page asks the
 * host for a taller surface while it's open (panel.height) and gives it back when it closes.
 */
import { useEffect, useMemo, useRef, useState } from "preact/hooks";
import { powos } from "../bridge.ts";
import type { App, DesktopWindow } from "../types.ts";

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
    const q = query.trim().toLowerCase();
    return q ? apps.filter((a) => a.label.toLowerCase().includes(q)) : apps;
  }, [apps, query]);
  const launch = (a: App) => {
    powos.apps.launch(a.key);
    close();
  };
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
