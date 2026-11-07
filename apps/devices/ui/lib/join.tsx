/**
 * New devices joining the realm, approved from here: only when this device is enrolled as an approver (its own agent,
 * paired from this app, says realm.approver and that this app runs on it - lib/devices/powos-deviced /v1/enroll/*).
 *
 * "New device wants to join": every waiting device with its code shown big, so the person matches it with the code on
 * the new device's own screen, and Approve / Deny. Live (polled while the page is shown) and optimistic: a tap shows
 * the result at once ("Approved - Phone is joining"), kept when the realm took it, rolled back with the realm's own
 * words and a Try again when it didn't. Approval gives the device no AI subscription; `powos devices approve <code>
 * --tenant T` on an approver does.
 *
 * The realm's registry (useRealm) gives each paired card its Revoke (enrolled) or how to enroll it (paired only).
 */
import { useEffect, useRef, useState } from "preact/hooks";
import { decide, enrolledDevices, revokeEnrolled, waiting, type Device, type Enrolled, type Net, type Waiting } from "./devices";
import { KIND, S } from "./ui";

const POLL_MS = 3000;
/** How long a decided device stays on the card with its result before it goes. */
const SHOWN_MS = 4000;

type Decision = { decision: "approve" | "deny"; error?: string; done?: boolean };

/** Polls [load] while the page is shown and [by] is set; returns the last answer and a reload. */
function usePoll<T>(by: Device | null, load: (by: Device) => Promise<T>, empty: T): [T, () => void] {
  const [v, setV] = useState<T>(empty);
  const ref = useRef(by);
  ref.current = by;
  const reload = () => {
    const d = ref.current;
    if (d) load(d).then((x) => ref.current === d && setV(x), () => {});
  };
  useEffect(() => {
    if (!by) return setV(empty);
    reload();
    const t = setInterval(() => !document.hidden && reload(), POLL_MS);
    return () => clearInterval(t);
  }, [by?.id]);
  return [v, reload];
}

export function Join({ net, by }: { net?: Net; by: Device | null }) {
  const [list, reload] = usePoll<Waiting[]>(by, (d) => waiting(net, d), []);
  const [decided, setDecided] = useState<Record<string, Decision & { w: Waiting }>>({});
  if (!by) return null;
  const run = async (w: Waiting, decision: "approve" | "deny") => {
    const code = w.user_code;
    setDecided((all) => ({ ...all, [code]: { w, decision } }));
    try {
      await decide(net, by, code, decision);
      setDecided((all) => ({ ...all, [code]: { w, decision, done: true } }));
      setTimeout(() => setDecided(({ [code]: _, ...rest }) => rest), SHOWN_MS);
      reload();
    } catch (e) {
      setDecided((all) => ({ ...all, [code]: { w, decision, error: (e as Error).message } }));
    }
  };
  const dismiss = (code: string) => setDecided(({ [code]: _, ...rest }) => rest);
  // The waiting ones, plus the ones decided here while the realm hasn't dropped them yet (or that just went).
  const shown = [...list.filter((w) => !decided[w.user_code]).map((w) => ({ w, d: undefined as Decision | undefined })),
    ...Object.values(decided).map(({ w, ...d }) => ({ w, d }))];
  if (shown.length === 0) return null;
  return (
    <div style={{ ...S.card, ...S.joinCard }} data-join>
      <div style={S.name}>{shown.length === 1 ? "New device wants to join" : `${shown.length} new devices want to join`}</div>
      <div style={S.muted}>Approve only when the code matches the one on the new device's screen.</div>
      {shown.map(({ w, d }) => <Row key={w.user_code} w={w} d={d} run={(x) => run(w, x)} dismiss={() => dismiss(w.user_code)} />)}
    </div>
  );
}

const what = (w: Waiting) =>
  [KIND[w.device.kind ?? ""] ?? w.device.kind, w.device.platform, w.paired && "paired with this device"].filter(Boolean).join(" · ");
const stateOf = (d?: Decision) => (!d ? "waiting" : d.error ? "error" : d.done ? "done" : "sending");

function Row({ w, d, run, dismiss }: { w: Waiting; d?: Decision; run: (x: "approve" | "deny") => void; dismiss: () => void }) {
  return (
    <div style={S.joinRow} data-waiting={w.user_code} data-state={stateOf(d)}>
      <div style={S.joinCode} data-join-code>{w.user_code}</div>
      <div style={S.name}>{w.device.name}</div>
      <div style={S.muted}>{what(w)}</div>
      {!d && <Choice run={run} />}
      {d && !d.error && <Result name={w.device.name} decision={d.decision} />}
      {d?.error && <Failed d={d} run={run} dismiss={dismiss} />}
    </div>
  );
}

function Choice({ run }: { run: (x: "approve" | "deny") => void }) {
  return (
    <div style={S.actions}>
      <button style={S.btn} data-join-approve onClick={() => run("approve")}>Approve</button>
      <button style={S.btn} data-join-deny onClick={() => run("deny")}>Deny</button>
    </div>
  );
}

function Result({ name, decision }: { name: string; decision: "approve" | "deny" }) {
  return decision === "approve"
    ? <div style={S.okText} data-join-result>Approved - {name} is joining</div>
    : <div style={S.muted} data-join-result>Denied - it won't join</div>;
}

/** Rolled back: the realm's own words, and the same decision again or leave it waiting. */
function Failed({ d, run, dismiss }: { d: Decision; run: (x: "approve" | "deny") => void; dismiss: () => void }) {
  return (
    <div style={S.error} data-join-error>
      <div>{d.decision === "approve" ? "Approve" : "Deny"}: {d.error}</div>
      <div style={S.actions}>
        <button style={S.btn} data-join-retry onClick={() => run(d.decision)}>Try again</button>
        <button style={S.ghost} onClick={dismiss}>OK</button>
      </div>
    </div>
  );
}

/** The realm's devices as the approver sees them: enrolled ids (revoked ones left out), and a revoke. */
export function useRealm(net: Net | undefined, by: Device | null) {
  const [devices, reload] = usePoll<Enrolled[] | null>(by, (d) => enrolledDevices(net, d), null);
  const enrolled = devices && new Set(devices.filter((d) => !d.revoked).map((d) => d.id));
  const revoke = async (id: string) => {
    await revokeEnrolled(net, by!, id);
    reload();
  };
  return { enrolled, revoke };
}
