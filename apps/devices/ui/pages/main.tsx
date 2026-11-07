/**
 * Devices: every PowOS device paired from here, live (on or off, battery or mains, screen on or off, locked, what
 * keeps it busy), and what this device may do to it - only the actions that device says it can do (its caps), so the
 * same page works for a PC, a phone, a TV. A tap shows the result at once (optimistic) and rolls back with the
 * device's own words and a retry if it refused. Pairing: a code shown on the other device's screen, typed here.
 * lib/devices.ts is the protocol, lib/live.ts the polling and actions; docs/research/device-ecosystem.md the design.
 * On a device enrolled as an approver, lib/join.tsx: new devices asking to join (Approve / Deny) and Revoke per device.
 */
import { useState } from "preact/hooks";
import { approverOf, forget, load, save, type Cap, type Device, type Host, type Status } from "../lib/devices";
import { canWake, useActions, useLive, type Live, type Pending } from "../lib/live";
import { AddDevice } from "../lib/add";
import { ThisPhone } from "../lib/thisphone";
import { Join, useRealm } from "../lib/join";
import { KIND, S } from "../lib/ui";

interface Props {
  host: Host;
  app: string;
  close?: () => void;
}

const LABEL: Partial<Record<Cap, string>> = {
  lock: "Lock",
  unlock: "Unlock",
  screen_off: "Screen off",
  screen_on: "Screen on",
  sleep: "Sleep",
  wake: "Wake",
  ring: "Ring",
};

export default function Main({ host, close }: Props) {
  const net = host.net;
  const [list, setList] = useState<Device[]>(load);
  const update = (next: Device[]) => {
    setList(next);
    save(next);
  };
  const liveState = useLive(net, list, update);
  const live = liveState.live;
  const { pending, run, dismiss } = useActions(net, list, liveState);
  const by = approverOf(list, Object.fromEntries(Object.entries(live).map(([k, v]) => [k, v.s])));
  const realm = useRealm(net, by);
  const drop = (d: Device) => {
    update(list.filter((x) => x.id !== d.id));
    forget(net, d);
  };
  return (
    <div style={S.page} data-devices>
      <header style={S.head}>
        {close && <button style={S.back} onClick={close} aria-label="back">‹</button>}
        <h1 style={S.title}>Devices</h1>
      </header>
      <ThisPhone dev={host.thisDevice} />
      <Join net={net} by={by} />
      {list.length === 0 && <div style={S.muted}>No devices yet. Add one below: it shows a code on its own screen.</div>}
      {list.map((d) => (
        <DeviceCard
          key={d.id}
          d={d}
          live={live[d.id]}
          pending={pending[d.id]}
          wake={canWake(d, list, live)}
          run={(a, force) => run(d, a, force)}
          dismiss={() => dismiss(d.id)}
          remove={() => drop(d)}
          enrolled={by && realm.enrolled ? realm.enrolled.has(d.id) : null}
          revoke={async () => {
            await realm.revoke(d.id);
            drop(d);
          }}
        />
      ))}
      <AddDevice net={net} paired={list} added={(d) => update([...list.filter((x) => x.id !== d.id), d])} />
    </div>
  );
}

/** What the user sees: the last status, with a tapped action's result laid over it while it's in flight. */
function shownStatus(live?: Live, pending?: Pending): Status | undefined {
  const base = live?.s;
  if (!base || !pending || pending.error) return base;
  return { ...base, ...pending.expect };
}

/**
 * The buttons for a device right now: its caps that make sense in its state (screen off or on, wake when off). Unlock
 * sits next to Lock when the device advertises it (a desktop; its owner only - anyone else gets the device's refusal).
 */
function actionsFor(d: Device, s: Status | undefined, wake: boolean): Cap[] {
  if (!s?.online) return wake ? ["wake"] : [];
  const screen: Cap = s.screen === "off" ? "screen_on" : "screen_off";
  return (["lock", "unlock", screen, "sleep", "ring"] as Cap[]).filter((a) => d.caps.includes(a));
}

function DeviceCard({ d, live, pending, wake, run, dismiss, remove, enrolled, revoke }: {
  d: Device;
  live?: Live;
  pending?: Pending;
  wake: boolean;
  run: (a: Cap, force?: boolean) => void;
  dismiss: () => void;
  remove: () => void;
  /** In the realm (this device an approver): true enrolled, false paired only; null = not known here. */
  enrolled: boolean | null;
  revoke: () => Promise<void>;
}) {
  const shown = shownStatus(live, pending);
  const actions = actionsFor(d, shown, wake);
  return (
    <div style={S.card} data-device={d.id}>
      <div style={S.row}>
        <span style={{ ...S.dot, background: dotColor(live, shown) }} aria-hidden="true" />
        <div style={S.grow}>
          <div style={S.name}>{d.name}</div>
          <div style={S.muted} data-device-line>{live ? line(d, shown, live) : "checking..."}</div>
        </div>
        <button style={S.ghost} onClick={remove} aria-label={`forget ${d.name}`}>Forget</button>
      </div>
      {actions.length > 0 && <Actions actions={actions} pending={pending} run={run} />}
      {pending?.error && <Refused pending={pending} run={run} dismiss={dismiss} />}
      {enrolled !== null && <Membership name={d.name} enrolled={enrolled} revoke={revoke} />}
    </div>
  );
}

type RevokeState = "idle" | "confirm" | "sending" | { error: string };

/**
 * A device's place in the realm, seen from an approver: enrolled -> Revoke (asked once: its realm and AI tokens stop
 * at once, and this device forgets it), shown revoked the moment it's confirmed, rolled back with the realm's words;
 * paired only -> how it joins (`powos devices enroll` on it, then approve it here).
 */
function Membership({ name, enrolled, revoke }: { name: string; enrolled: boolean; revoke: () => Promise<void> }) {
  const [st, setSt] = useState<RevokeState>("idle");
  if (!enrolled && st !== "sending") return <div style={S.muted} data-not-enrolled>Paired, not enrolled - run powos devices enroll on it, then approve it here</div>;
  const go = async () => {
    setSt("sending");
    try {
      await revoke();
    } catch (e) {
      setSt({ error: (e as Error).message });
    }
  };
  if (st === "sending") return <div style={S.muted} data-revoked>Revoked - {name} is out of the realm</div>;
  if (st === "confirm")
    return (
      <div style={S.confirm} data-revoke-confirm>
        <div>Revoke {name}? Its realm and AI tokens stop at once, and this device forgets it.</div>
        <div style={S.actions}>
          <button style={S.btn} data-revoke-yes onClick={go}>Revoke</button>
          <button style={S.ghost} onClick={() => setSt("idle")}>Cancel</button>
        </div>
      </div>
    );
  return (
    <div style={S.row}>
      <div style={{ ...S.muted, ...S.grow }}>Enrolled</div>
      {typeof st === "object" && <div style={S.errorText} data-revoke-error>Revoke: {st.error}</div>}
      <button style={S.ghost} data-revoke onClick={() => setSt("confirm")}>{typeof st === "object" ? "Try again" : "Revoke"}</button>
    </div>
  );
}

const dotColor = (live?: Live, s?: Status) => (!live ? "var(--color-muted)" : s?.online ? "var(--status-working)" : "var(--status-stalled)");

function Actions({ actions, pending, run }: { actions: Cap[]; pending?: Pending; run: (a: Cap) => void }) {
  const inFlight = !!pending && !pending.error;
  return (
    <div style={S.actions}>
      {actions.map((a) => (
        <button key={a} data-action={a} style={inFlight && pending!.action === a ? { ...S.btn, ...S.btnOn } : S.btn} disabled={inFlight} onClick={() => run(a)}>
          {LABEL[a]}
        </button>
      ))}
    </div>
  );
}

/** A refusal in the device's words, with the one next step: try again, or sleep anyway when something was running. */
function Refused({ pending, run, dismiss }: { pending: Pending; run: (a: Cap, force?: boolean) => void; dismiss: () => void }) {
  const why = pending.busy ? `busy - ${pending.busy.join(", ")} would stop` : pending.error;
  return (
    <div style={S.error} data-device-error>
      <div>{LABEL[pending.action]}: {why}</div>
      <div style={S.actions}>
        {pending.busy
          ? <button style={S.btn} data-force onClick={() => run(pending.action, true)}>Sleep anyway</button>
          : <button style={S.btn} data-retry onClick={() => run(pending.action)}>Try again</button>}
        <button style={S.ghost} data-dismiss onClick={dismiss}>OK</button>
      </div>
    </div>
  );
}

function powerWords(p: Status["power"]): string | null {
  if (!p) return null;
  if (p.battery != null) return `${p.battery}%${p.charging ? " charging" : ""}`;
  return p.source === "ac" ? "on mains" : null;
}

function line(d: Device, s: Status | undefined, live: Live): string {
  const kind = KIND[d.kind] ?? d.kind;
  if (live.auth) return `${kind} - doesn't know this device any more: forget it and pair again`;
  if (!s?.online) return `${kind} - off or not reachable`;
  const busy = s.busy ?? [];
  return [
    kind,
    powerWords(s.power),
    s.screen && `screen ${s.screen}`,
    s.locked && "locked",
    busy.length > 0 && `busy: ${busy.length === 1 ? busy[0] : `${busy.length} things`}`,
  ].filter(Boolean).join(" · ");
}
