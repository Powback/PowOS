/**
 * The AI page's Devices tab, its first section: the owner's devices signed in to the Pow account (the user, 11-25: "The
 * devices page should show the paired devices which are signed in"). The realm (PowStation enroll/powos-enroll.py GET
 * /v1/devices) lists them through this phone's own enrollment (devices/PowStation.kt "devices.realm" - its token never
 * reaches the page): a row each with its kind, name, "This device", online / last seen and its account sync
 * (powos-account-sync's last round, reported to the realm). Rename this device; an approver removes another one through
 * the realm's revoke (a confirm in the row, then optimistic with rollback). Removed devices fold under "Removed".
 * Pure parts: devicesview.ts. Installed & running per host (units.tsx) stays under it.
 */
import { useEffect, useRef, useState } from "preact/hooks";
import { computed, signal } from "@preact/signals";
import { thisDevice } from "../apps/thisdevice.ts";
import { powos } from "../bridge.ts";
import { stored } from "../state.ts";
import { Icon } from "./icons.tsx";
import { optimistic } from "./pending.tsx";
import { Reveal } from "./reveal.tsx";
import { devicesView, kindIcon, presence, relAgo, syncLine, whatIs, withDevice, type AccountDevice } from "./devicesview.ts";

/** What the tab knows: the list as last seen (shown at once when the page comes back), and how the last read went. */
interface Account {
  /** loading: nothing read yet; ok; out: this device isn't signed in; off: this app can't ask (an older APK, a desktop). */
  state: "loading" | "ok" | "out" | "off";
  list: AccountDevice[];
  approver: boolean;
  /** The last successful read (seconds). */
  at: number;
  /** The last read failed (the hub not reachable): its words, the list kept. */
  error?: string;
}

const cache = stored("ai.accountDevices", "");
const first = (): Account => {
  try {
    const a = JSON.parse(cache.value) as Account;
    if (Array.isArray(a?.list)) return { ...a, error: undefined };
  } catch {}
  return { state: "loading", list: [], approver: false, at: 0 };
};
export const account = signal<Account>(first());
const keep = (a: Account) => {
  account.value = a;
  if (a.state === "ok") cache.value = JSON.stringify({ ...a, error: undefined });
};

/** Signed in and online now, for the tab's count and glance ("" until the account was read). */
export const accountCounts = computed(() => {
  const a = account.value;
  if (a.state !== "ok") return null;
  const v = devicesView(a.list, Date.now() / 1000);
  return { signedIn: v.signedIn.length, online: v.online };
});

const why = (e: unknown) => (e instanceof Error ? e.message : String(e ?? "")) || "it didn't work";
const READ_MS = 30_000;

/** One read of the account: whether this device is signed in (and may approve), then the list. */
async function read() {
  let st: { enrolled?: boolean; approver?: boolean };
  try {
    st = await thisDevice.realm("state");
  } catch {
    return keep({ ...account.value, state: account.value.list.length ? account.value.state : "off" });
  }
  if (!st?.enrolled) return keep({ state: "out", list: [], approver: false, at: 0 });
  try {
    const r = await thisDevice.realm("devices");
    keep({ state: "ok", list: Array.isArray(r?.devices) ? r.devices : [], approver: !!st.approver, at: Math.floor(Date.now() / 1000) });
  } catch (e) {
    keep({ ...account.value, approver: !!st.approver, error: why(e) });
  }
}

/** While the tab shows (mounted only then): read now and every READ_MS - the realm pushes nothing. */
function AccountFeed() {
  useEffect(() => {
    void read();
    const t = setInterval(() => void read(), READ_MS);
    return () => clearInterval(t);
  }, []);
  return null;
}

/** Rename this device: the name shows at once, the realm is told after; a refusal puts the old one back with why. */
function rename(d: AccountDevice, name: string, failed: (s: string) => void) {
  const old = d.name;
  const set = (n?: string) => keep({ ...account.value, list: withDevice(account.value.list, d.id, (x) => ({ ...x, name: n })) });
  optimistic(
    () => (failed(""), set(name)),
    () => thisDevice.realm("rename", { name }),
    (e) => (set(old), failed(`Couldn't rename: ${why(e)}`)),
  ).catch(() => {});
}

/** Remove (revoke) another device: it moves under Removed at once; a refusal brings it back with why. */
function remove(d: AccountDevice, failed: (s: string) => void) {
  const set = (revoked: number | null) => keep({ ...account.value, list: withDevice(account.value.list, d.id, (x) => ({ ...x, revoked })) });
  optimistic(
    () => (failed(""), set(Math.floor(Date.now() / 1000))),
    () => thisDevice.realm("revoke", { id: d.id }),
    (e) => (set(null), failed(`Couldn't remove ${d.name || "it"}: ${why(e)}`)),
  ).catch(() => {});
}

/** This device's name, editable in place: Enter keeps it, Escape or an empty name doesn't. */
function NameEdit({ d, done }: { d: AccountDevice; done: (name: string | null) => void }) {
  const [v, setV] = useState(d.name ?? "");
  const el = useRef<HTMLInputElement>(null);
  useEffect(() => el.current?.focus(), []);
  const over = useRef(false);
  const end = (name: string | null) => !over.current && ((over.current = true), done(name));
  const finish = () => end(v.trim() && v.trim() !== d.name ? v.trim() : null);
  return (
    <form class="ag-say dv-rename" onSubmit={(e) => (e.preventDefault(), finish())}>
      <input
        value={v}
        aria-label="this device's name"
        maxLength={64}
        enterKeyHint="done"
        autocomplete="off"
        ref={el}
        onInput={(e) => setV((e.currentTarget as HTMLInputElement).value)}
        onFocus={() => powos.keyboard.show()}
        onKeyDown={(e) => e.key === "Escape" && end(null)}
        onBlur={finish}
      />
    </form>
  );
}

/** A device's name, with "This device" on this one. */
function Name({ d }: { d: AccountDevice }) {
  return (
    <span class="dv-name">
      <span class="ag-row-title">{d.name || d.id}</span>
      {d.self && <span class="fl-chip dv-this">This device</span>}
    </span>
  );
}

/** Its muted line: online / seen when, its sync (missing apps stand out), what it is. */
function Sub({ d, now }: { d: AccountDevice; now: number }) {
  const sync = syncLine(d, now);
  const what = whatIs(d);
  return (
    <span class="dv-sub">
      <span data-presence>{presence(d, now)}</span>
      {sync && <span data-sync class={/missing|not/.test(sync) ? "dv-warn" : ""}>{sync}</span>}
      {what && <span class="dv-what">{what}</span>}
    </span>
  );
}

/** Remove's confirm, under the row: what it does, Cancel / Remove. */
function Confirm({ d, cancel, sure }: { d: AccountDevice; cancel: () => void; sure: () => void }) {
  return (
    <div class="dv-confirm" data-confirm>
      <span class="dv-confirm-what">Remove {d.name || "this device"}? It's signed out of your account and stops syncing.</span>
      <span class="ag-actions">
        <button type="button" class="ag-act" onClick={cancel}>
          Cancel
        </button>
        <button type="button" class="ag-act danger" data-remove-sure onClick={sure}>
          Remove
        </button>
      </span>
    </div>
  );
}

/** The row's action: rename on this device (a pencil), Remove on another for an approver, else none. */
function Action({ d, removable, edit, ask }: { d: AccountDevice; removable: boolean; edit: () => void; ask: () => void }) {
  if (d.self)
    return (
      <button type="button" class="ag-act dv-edit" aria-label="rename this device" onClick={edit}>
        <Icon name="pencilOutline" size={16} />
      </button>
    );
  return removable ? (
    <button type="button" class="ag-act" data-remove onClick={ask}>
      Remove
    </button>
  ) : null;
}

/** One signed-in device: kind, name (+ This device), what it is; online / last seen and its sync; its action. */
function DeviceRow({ d, now, approver, failed }: { d: AccountDevice; now: number; approver: boolean; failed: (s: string) => void }) {
  const [editing, setEditing] = useState(false);
  const [sure, setSure] = useState(false);
  const on = presence(d, now) === "online";
  const removable = !d.self && approver && !sure;
  return (
    <li class="aip-area tile ag-row dv-row" data-device={d.id} data-self={d.self ? "" : undefined} data-online={on ? "" : undefined}>
      <div class="aip-area-row dv-line">
        <span class="dv-kind" aria-hidden="true">
          <Icon name={kindIcon(d.kind)} size={22} />
          <span class={`dv-dot ${on ? "on" : ""}`} />
        </span>
        <span class="dv-main">
          {editing ? <NameEdit d={d} done={(n) => (setEditing(false), n && rename(d, n, failed))} /> : <Name d={d} />}
          <Sub d={d} now={now} />
        </span>
        {!editing && <Action d={d} removable={removable} edit={() => setEditing(true)} ask={() => setSure(true)} />}
      </div>
      {sure && <Confirm d={d} cancel={() => setSure(false)} sure={() => (setSure(false), remove(d, failed))} />}
    </li>
  );
}

/** A removed device, one line in the fold: its name, when. */
function RemovedLine({ d, now }: { d: AccountDevice; now: number }) {
  return (
    <li class="ag-rest" data-removed={d.id}>
      <span class="ag-rest-line dv-removed">
        <Icon name={kindIcon(d.kind)} size={16} />
        <span class="ag-row-title">{d.name || d.id}</span>
        <span class="ag-row-state">removed {d.revoked ? relAgo(d.revoked, now) : ""}</span>
      </span>
    </li>
  );
}

/** Nothing read yet: three rows at their real size (skeleton), never an empty page that fills in later. */
function Placeholder() {
  return (
    <ul class="aip-areas" aria-busy="true" data-devices-loading>
      {[0, 1, 2].map((i) => (
        <li key={i} class="aip-area tile ag-row dv-row">
          <div class="aip-area-row dv-line">
            <span class="dv-kind dv-skel-icon" />
            <span class="dv-main pending-skel-rows">
              <span class="pending-skel-row" style={{ width: `${60 - i * 12}%` }} />
              <span class="pending-skel-row" style={{ width: `${40 + i * 8}%` }} />
            </span>
          </div>
        </li>
      ))}
    </ul>
  );
}

/** The Removed fold: closed by default, a count on its row. */
function Removed({ list, now }: { list: AccountDevice[]; now: number }) {
  const [open, setOpen] = useState(false);
  if (!list.length) return null;
  return (
    <ul class="aip-areas">
      <li class={`aip-area tile ag-fold ${open ? "open" : ""}`} data-removed-fold>
        <button type="button" class="aip-area-row ais-toggle" aria-expanded={open} onClick={() => setOpen(!open)}>
          <span class="aip-area-name">Removed · {list.length}</span>
          <span class="ais-chev" aria-hidden="true" />
        </button>
        <Reveal open={open}>
          <ul class="aip-tasks ag-fold-list">
            {list.map((d) => (
              <RemovedLine key={d.id} d={d} now={now} />
            ))}
          </ul>
        </Reveal>
      </li>
    </ul>
  );
}

/** What the section says besides the rows: nothing read yet (skeleton), not signed in, can't ask here, the last read failed. */
function Status({ a, err, now }: { a: Account; err: string; now: number }) {
  const empty = !a.list.length;
  if (a.state === "loading" && empty) return <Placeholder />;
  if (a.state === "out") return <div class="aip-empty">This device isn't signed in to your Pow account. Settings › powstation signs it in.</div>;
  if (a.state === "off" && empty) return <div class="aip-empty">Your signed-in devices show here on a PowOS phone.</div>;
  if (!err && !a.error) return null;
  return (
    <div class="dv-note" role="status" data-devices-error>
      {err || `PowStation not reachable${a.at ? ` · as of ${relAgo(a.at, now)}` : ""}`}
    </div>
  );
}

/** The section: signed-in devices, then Removed. [shown]: the feed runs only on screen. */
export function AccountDevices({ shown }: { shown: boolean }) {
  const [err, setErr] = useState("");
  const a = account.value;
  const now = Math.floor(Date.now() / 1000);
  const v = devicesView(a.list, now);
  return (
    <section class="ais-sec dv-account" aria-label="Signed in" data-devices={a.state}>
      {shown && <AccountFeed />}
      <h3 class="ais-h">
        Signed in{a.state === "ok" && <span class="ais-n">{v.signedIn.length}</span>}
      </h3>
      <Status a={a} err={err} now={now} />
      {v.signedIn.length > 0 && (
        <ul class="aip-areas">
          {v.signedIn.map((d) => (
            <DeviceRow key={d.id} d={d} now={now} approver={a.approver} failed={setErr} />
          ))}
        </ul>
      )}
      <Removed list={v.removed} now={now} />
    </section>
  );
}
