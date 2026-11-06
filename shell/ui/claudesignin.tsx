/**
 * The native Claude sign-in (the user, 11-06: "it should detect when signin is missing or needs refresh and have a login
 * button which opens the url and shows the code input box"). claude-login end to end, by the host (ClaudeSignIn.kt ->
 * `powos manager --fleet-login`): through the fleet's authority (claude-auth.pow, which stays the only refresher) or,
 * on a machine without one, in PowOS's Linux for its own login. Never `/login` in a terminal.
 *
 * Where the user sees the problem: the AI page (Chat.auth "signin" / "relogin"), a terminal tile whose claude printed
 * "run /login" ([TerminalLogin], detected by [watchTerminal]), and the host's notification. One state for all of them
 * (Chat.signin): Login opens the link in the browser and shows the code box here at the same time; the pasted code
 * signs in and the state says so live. Optimistic: every tap shows its result at once, the host's phase replaces it.
 */
import { useEffect, useState } from "preact/hooks";
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import { chat } from "../state.ts";
import type { ClaudeSignInState } from "../types.ts";
import { Icon } from "./icons.tsx";

type Phase = ClaudeSignInState["phase"];

/** Terminal ids whose output asked for a login (claude's "run /login", a 401), until signed in or dismissed. */
export const loginAsked = signal<ReadonlySet<string>>(new Set());

/** Claude Code's ways of saying its login is gone or lapsed (its own words, 2026: "Please run /login", ...). */
export const LOGIN_PROMPT =
  /run \/login|not logged in|invalid api key|oauth token (?:has )?expired|authentication_error|401[^\n]{0,40}(?:unauthori[sz]ed|authentication)|sign in again/i;

const tails = new Map<string, string>();
const ANSI = /\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07/g;

/** Each terminal's output (decoded text), watched for [LOGIN_PROMPT] across chunk boundaries. */
export function watchTerminal(id: string, text: string) {
  const tail = ((tails.get(id) ?? "") + text.replace(ANSI, "")).slice(-400);
  tails.set(id, tail);
  if (!LOGIN_PROMPT.test(tail) || loginAsked.value.has(id)) return;
  tails.set(id, "");
  loginAsked.value = new Set([...loginAsked.value, id]);
  // Confirm it with the host (the authority's / the image's state): the details for the sheet, and its notification.
  void powos.ai.auth?.().catch(() => undefined);
  void powos.ai.signin?.status().catch(() => undefined);
}

const dismiss = (id: string) => {
  const next = new Set(loginAsked.value);
  next.delete(id);
  loginAsked.value = next;
};

export function signinState(): ClaudeSignInState {
  return chat.value.signin ?? { phase: "", url: "", error: "", mode: "", state: "", tenant: "", why: "", canLogin: true };
}

/** "Claude sign-in needed - powback" (the fleet tenant's), or the machine's own. */
export function signinTitle(s: ClaudeSignInState) {
  if (s.mode === "direct" && s.state === "missing") return "Sign in to Claude";
  return "Claude sign-in needed" + (s.mode === "authority" && s.tenant ? ` - ${s.tenant}` : "");
}

function why(s: ClaudeSignInState) {
  if (s.state === "refresh") return "The Claude login expired and can't refresh by itself. Log in again on claude.com, then paste the code here.";
  if (s.mode === "direct" || !s.mode) return "PowOS AI and claude run on your own Claude account. Log in on claude.com, then paste the code here.";
  return "This phone's Claude has no login yet. Log in on claude.com, then paste the code here.";
}

const isCoding = (p: Phase) => p === "starting" || p === "code" || p === "checking";
const tenantOf = (s: ClaudeSignInState) => (s.mode === "authority" && s.tenant ? ` - ${s.tenant}` : "");

function SignedIn({ s, cls }: { s: ClaudeSignInState; cls: string }) {
  return (
    <div class={`signin ${cls}`}>
      <div class="signin-head">
        <Icon name="checkCircleOutline" size={22} class="signin-ok" />
        <span class="signin-title">Signed in to Claude{tenantOf(s)}</span>
      </div>
      <div class="signin-text muted">Every claude on this phone uses it now. A command that stopped for the login can run again.</div>
    </div>
  );
}

/** The code box: the link is open in the browser (or opening); paste (or the Paste button) and Sign in. */
function CodeBox({ s, phase, onSend }: { s: ClaudeSignInState; phase: Phase; onSend: (code: string) => void }) {
  const [code, setCode] = useState("");
  const send = () => code.trim() && onSend(code.trim());
  const paste = async () => {
    const t = await powos.clipboard?.read().catch(() => null);
    if (t) setCode(t.trim());
  };
  const opening = phase === "starting";
  return (
    <>
      <div class="signin-text muted">
        {opening ? "Opening claude.com…" : "Log in on claude.com in the browser, then paste the code it shows (code#state)."}
        {s.url && !opening && (
          <button type="button" class="signin-link" onClick={() => void powos.ai.signin?.reopen().catch(() => undefined)}>
            Open it again
          </button>
        )}
      </div>
      <div class="signin-row">
        <input
          class="signin-code"
          value={code}
          placeholder="paste code#state"
          autocomplete="off"
          spellcheck={false}
          onInput={(e) => setCode((e.target as HTMLInputElement).value)}
          onKeyDown={(e) => e.key === "Enter" && send()}
        />
        <button type="button" class="signin-paste" onClick={() => void paste()}>
          Paste
        </button>
      </div>
      <button type="button" class="signin-go" disabled={!code.trim() || phase !== "code"} onClick={send}>
        {phase === "checking" ? "Signing in…" : "Sign in"}
      </button>
    </>
  );
}

/** Before Login (or after an error): what's wrong, the error if any, Login. */
function Intro({ s, phase, onLogin }: { s: ClaudeSignInState; phase: Phase; onLogin: () => void }) {
  return (
    <>
      <div class="signin-text muted">{s.canLogin ? why(s) : s.why}</div>
      {phase === "error" && <div class="signin-err">{s.error}</div>}
      {s.canLogin && (
        <button type="button" class="signin-go" onClick={onLogin}>
          Login
        </button>
      )}
    </>
  );
}

/** The sheet itself: Login, then the code box (the link already open in the browser), then the result. */
export function SignInSheet({ class: cls = "", onDone }: { class?: string; onDone?: () => void }) {
  const s = signinState();
  // The tap's result before the host's (optimistic): cleared as soon as the host's phase moves.
  const [mine, setMine] = useState<Phase | null>(null);
  useEffect(() => setMine(null), [s.phase, s.error]);
  useEffect(() => void (s.phase === "done" && onDone?.()), [s.phase]);
  const phase = mine ?? s.phase;
  if (phase === "done") return <SignedIn s={s} cls={cls} />;
  const login = () => (setMine("starting"), void powos.ai.signin?.start().catch(() => setMine(null)));
  const send = (code: string) => (setMine("checking"), void powos.ai.signin?.complete(code).catch(() => setMine(null)));
  const close = () => (setMine(null), void powos.ai.signin?.cancel().catch(() => undefined), void powos.ai.auth?.().catch(() => undefined));
  const coding = isCoding(phase);
  return (
    <div class={`signin ${cls}`}>
      <div class="signin-head">
        <Icon name="accountCircleOutline" size={22} class="signin-icon" />
        <span class="signin-title">{signinTitle(s)}</span>
        {coding && (
          <button type="button" class="signin-link" onClick={close}>
            Cancel
          </button>
        )}
      </div>
      {coding ? <CodeBox s={s} phase={phase} onSend={send} /> : <Intro s={s} phase={phase} onLogin={login} />}
    </div>
  );
}

/** Over a terminal tile whose claude asked for a login: the sheet at its foot, the tile still readable above it. */
export function TerminalLogin({ id }: { id: string }) {
  if (!loginAsked.value.has(id)) return null;
  const s = signinState();
  // The host says the login works (and nothing is under way): claude's line was about something else, or it's done.
  if (s.state === "ok" && !s.phase) return null;
  return (
    <div class="term-signin">
      <SignInSheet onDone={() => setTimeout(() => dismiss(id), 2500)} />
      {!s.phase && (
        <button type="button" class="signin-link term-signin-x" aria-label="Dismiss" onClick={() => dismiss(id)}>
          <Icon name="close" size={18} />
        </button>
      )}
    </div>
  );
}
