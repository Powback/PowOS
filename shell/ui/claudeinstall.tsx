/**
 * Install Claude (Chat.auth "install": the manager's claude isn't in the image - the user, 11-10 on the razr: "it
 * shouldnt say sign in to claude if claude is not installed, it should show install claude"). The button runs the
 * host's install (ClaudeInstall.kt -> `powos manager --install`); the installer's latest line and the seconds so far
 * show all the way (no silent wait), then the host asks the sign-in state again and the page moves on to Sign in to
 * Claude, or the chat. Optimistic: the tap shows "Installing Claude…" at once, the host's state replaces it.
 */
import { useEffect, useState } from "preact/hooks";
import { powos } from "../bridge.ts";
import { chat } from "../state.ts";
import { Icon } from "./icons.tsx";

/** Seconds since [from] (null: not running), ticking each second. */
function useSeconds(from: number | null) {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    if (from == null) return;
    const t = window.setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, [from]);
  return from == null ? 0 : Math.max(0, Math.floor((now - from) / 1000));
}

/** The tap's own state until the host's [running] says it took over; an older host without ai.install: its error. */
function useInstall() {
  const host = chat.value.install;
  const [tapped, setTapped] = useState<number | null>(null);
  const [failed, setFailed] = useState("");
  useEffect(() => void (host?.running && tapped == null && setTapped(Date.now())), [host?.running]);
  useEffect(() => void (tapped != null && host && !host.running && host.error && setTapped(null)), [host?.running, host?.error]);
  const running = tapped != null;
  const start = () => {
    setFailed("");
    setTapped(Date.now());
    const go = powos.ai.install?.();
    if (!go) return (setTapped(null), setFailed("This PowOS can't install Claude from here - run powos ai install claude in a terminal."));
    go.catch((e: unknown) => (setTapped(null), setFailed(String(e))));
  };
  return { running, since: tapped, line: host?.line || "Installing Claude…", error: running ? "" : failed || host?.error || "", start };
}

export function InstallClaude() {
  const s = useInstall();
  const secs = useSeconds(s.running ? s.since : null);
  return (
    <div class="ai-install">
      <Icon name="robotOutline" size={40} class="ai-signin-icon" />
      <div class="ai-signin-sheet">
        <div class="signin-title">Install Claude</div>
        <div class="signin-text muted">PowOS AI runs on Claude Code, which isn't installed yet. Install it, then sign in with your Claude account.</div>
        {s.running ? (
          <div class="install-progress" role="status">
            <span class="install-line">{s.line}</span>
            <span class="install-secs muted">{secs} s</span>
          </div>
        ) : (
          <button type="button" class="signin-go install-go" onClick={s.start}>
            {s.error ? "Try again" : "Install Claude"}
          </button>
        )}
        {s.error && <div class="signin-err">{s.error}</div>}
      </div>
    </div>
  );
}
