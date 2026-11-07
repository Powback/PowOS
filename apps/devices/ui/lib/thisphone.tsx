/**
 * This phone, when PowOS runs on it without root: whether its other devices may lock it. Android's sanctioned way is a
 * device admin holding only the force-lock policy (the app's devices/LockAccess.kt); the person turns it on here -
 * this sheet says exactly what it allows, then Android's own "Activate" screen asks - and off here or in Settings.
 * Nothing is ever taken without that: the phone advertises lock/screen_off to its paired devices only while it's on.
 *
 * Optimistic: Allow / Turn off show the new state at once with what's happening, kept when Android confirms (the
 * "devices.lock" event), rolled back with the reason and a Try again when it didn't (the Activate screen closed
 * without Activate: the page comes back and the state is still off).
 */
import { useEffect, useRef, useState } from "preact/hooks";
import type { LockAccess, ThisDevice } from "./devices";
import { S } from "./ui";

type Pending = { want: boolean; error?: string };

/** After the page comes back from Android's screen: how long the confirming event may still take. */
const CONFIRM_GRACE_MS = 1500;

/** The lock's state as shown: Android's answer, with a change laid over it while it's in flight (or its error). */
function useLockAccess(dev?: ThisDevice) {
  const [access, setAccess] = useState<LockAccess | null>(null);
  const [pending, setPending] = useState<Pending | null>(null);
  const ref = useRef(pending);
  ref.current = pending;
  // The truth: Android's answer, whoever changed it (this page, Settings). It settles a pending change it agrees with.
  const settle = (s: LockAccess) => {
    setAccess(s);
    const p = ref.current;
    if (p && !p.error && p.want === s.allowed) setPending(null);
  };
  // Back from Android's Activate screen: still off after the grace = it was closed without Activate.
  const recheck = (d: ThisDevice) => {
    const p = ref.current;
    if (document.hidden || !p?.want || p.error) return;
    setTimeout(() => d.lock().then((s) => {
      settle(s);
      const now = ref.current;
      if (!s.allowed && now?.want && !now.error) setPending({ want: true, error: "not turned on - Android's screen was closed without Activate" });
    }, () => {}), CONFIRM_GRACE_MS);
  };
  useEffect(() => {
    if (!dev) return;
    dev.lock().then(settle, () => setAccess(null));
    const off = dev.onLock(settle);
    const back = () => recheck(dev);
    document.addEventListener("visibilitychange", back);
    return () => {
      off();
      document.removeEventListener("visibilitychange", back);
    };
  }, [dev]);
  const change = async (want: boolean) => {
    setPending({ want });
    try {
      const s = await (want ? dev!.allowLock() : dev!.stopLock());
      // Turning off answers at once; turning on waits for Android's screen (the event, or the page coming back).
      if (!want) settle(s);
    } catch (e) {
      setPending({ want, error: (e as Error).message });
    }
  };
  const busy = !!pending && !pending.error;
  return { access, pending, busy, on: busy ? pending!.want : !!access?.allowed, change, dismiss: () => setPending(null) };
}

export function ThisPhone({ dev }: { dev?: ThisDevice }) {
  const { access, pending, busy, on, change, dismiss } = useLockAccess(dev);
  const [sheet, setSheet] = useState(false);
  if (!dev || !access?.available) return null;
  return (
    <div style={S.card} data-this-phone data-lock-on={String(on)}>
      <div style={S.row}>
        <div style={S.grow}>
          <div style={S.name}>This phone</div>
          <div style={S.muted} data-this-phone-line>{phoneLine(on, pending)}</div>
        </div>
        {on
          ? <button style={S.ghost} data-lock-stop disabled={busy} onClick={() => change(false)}>Turn off</button>
          : <button style={S.btn} data-lock-allow disabled={busy} onClick={() => setSheet(true)}>Allow lock</button>}
      </div>
      {pending?.error && <LockError pending={pending} retry={() => (pending.want ? setSheet(true) : change(false))} dismiss={dismiss} />}
      {sheet && <LockSheet allow={() => (setSheet(false), change(true))} cancel={() => setSheet(false)} />}
    </div>
  );
}

function LockError({ pending, retry, dismiss }: { pending: Pending; retry: () => void; dismiss: () => void }) {
  return (
    <div style={S.error} data-lock-error>
      <div>{pending.want ? "Lock from other devices" : "Turning it off"}: {pending.error}</div>
      <div style={S.actions}>
        <button style={S.btn} data-lock-retry onClick={retry}>Try again</button>
        <button style={S.ghost} onClick={dismiss}>OK</button>
      </div>
    </div>
  );
}

function phoneLine(on: boolean, pending: Pending | null): string {
  if (pending && !pending.error) return pending.want ? "Android is asking - tap Activate there" : "turning it off...";
  return on ? "Your paired devices can lock this phone" : "Your other devices can ring it and turn its screen on; locking needs your OK";
}

/** What turning it on allows and doesn't, before Android's own screen asks. */
function LockSheet({ allow, cancel }: { allow: () => void; cancel: () => void }) {
  return (
    <div style={SHEET.backdrop} onClick={cancel}>
      <div style={SHEET.sheet} data-lock-sheet role="dialog" aria-label="Lock this phone from your other devices" onClick={(e) => e.stopPropagation()}>
        <div style={S.name}>Lock this phone from your other devices</div>
        <ul style={SHEET.list}>
          <li>Your paired PowOS devices get Lock and Screen off for this phone - nothing else.</li>
          <li>PowOS asks Android for one permission only, "lock the screen". It can't see or change your PIN, wipe the phone or set password rules.</li>
          <li>After a remote lock, Android asks for your PIN, pattern or password once (not the fingerprint).</li>
          <li>Turn it off here at any time, or in Settings, Security, Device admin apps. While it's on, uninstalling PowOS asks you to turn it off first.</li>
        </ul>
        <div style={S.muted}>Android shows its own screen next: tap Activate there.</div>
        <div style={S.actions}>
          <button style={{ ...S.btn, ...S.btnOn }} data-lock-continue onClick={allow}>Continue</button>
          <button style={S.ghost} data-lock-cancel onClick={cancel}>Not now</button>
        </div>
      </div>
    </div>
  );
}

const SHEET: Record<string, Record<string, string | number>> = {
  backdrop: { position: "fixed", inset: 0, display: "flex", alignItems: "flex-end", background: "var(--backdrop-tint)", zIndex: 10 },
  sheet: { display: "flex", flexDirection: "column", gap: "12px", width: "100%", boxSizing: "border-box", padding: "16px var(--edge, 16px) 24px", borderRadius: "var(--radius, 12px) var(--radius, 12px) 0 0", background: "var(--color-background)", fontFamily: "var(--font-body)" },
  list: { margin: 0, paddingLeft: "20px", display: "flex", flexDirection: "column", gap: "6px" },
};
