/**
 * Adding a device: the PowOS devices this network announces (mDNS _powos._tcp), the realm's enrolled devices (through
 * [realm], this device's enrolled agent: what lists them over the VPN, where mDNS doesn't reach) and an address field;
 * then the code that device shows on its own screen, typed here. The token it answers with goes into host.net's secret for it.
 */
import { useEffect, useState } from "preact/hooks";
import { discover, enrolledDevices, info, pairConfirm, pairStart, urlOf, type Device, type Found, type Net } from "./devices";
import { KIND, S } from "./ui";

type Step = { url: string; name: string; request: string; id: string };

export function AddDevice({ net, paired, realm, added }: { net?: Net; paired: Device[]; realm?: Device | null; added: (d: Device) => void }) {
  const [found, setFound] = useState<Found[]>([]);
  const [step, setStep] = useState<Step | null>(null);
  const [err, setErr] = useState("");
  const [working, setWorking] = useState(false);
  useEffect(() => void discover(net, paired, realm ? () => enrolledDevices(net, realm) : undefined).then(setFound), [net, paired.length, realm?.id]);
  const attempt = async (fn: () => Promise<void>) => {
    setErr("");
    setWorking(true);
    try {
      await fn();
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setWorking(false);
    }
  };
  const start = (url: string) => attempt(async () => {
    const i = await info(net, url);
    const r = await pairStart(net, url);
    setStep({ url, name: i.name, request: r.request, id: i.id });
  });
  const confirm = (code: string) => attempt(async () => {
    const r = await pairConfirm(net, { ...step!, code });
    added({ id: r.device.id, name: r.device.name, kind: r.device.kind, caps: r.device.caps, url: step!.url });
    setStep(null);
  });
  return (
    <div style={S.card} data-add>
      <div style={S.name}>Add a device</div>
      {step
        ? <PairCode name={step.name} working={working} confirm={confirm} cancel={() => setStep(null)} />
        : <Pick found={found} working={working} start={start} />}
      {err && <div style={S.errorText} data-add-error>{err}</div>}
    </div>
  );
}

function Pick({ found, working, start }: { found: Found[]; working: boolean; start: (url: string) => void }) {
  const [addr, setAddr] = useState("");
  return (
    <>
      {found.map((f) => (
        <button key={f.id} style={S.found} data-found={f.id} disabled={working} onClick={() => start(f.url)}>
          <span style={S.name}>{f.name}</span> <span style={S.muted}>{KIND[f.kind] ?? f.kind} {f.via === "realm" ? "in your devices" : "on this network"} - pair</span>
        </button>
      ))}
      <div style={S.row}>
        <input style={S.field} data-addr value={addr} placeholder="address, e.g. 192.168.50.58 (works over the VPN)" onInput={(e) => setAddr((e.target as HTMLInputElement).value)} />
        <button style={S.btn} data-pair disabled={working || !addr.trim()} onClick={() => start(urlOf(addr))}>{working ? "..." : "Pair"}</button>
      </div>
    </>
  );
}

function PairCode({ name, working, confirm, cancel }: { name: string; working: boolean; confirm: (code: string) => void; cancel: () => void }) {
  const [code, setCode] = useState("");
  return (
    <>
      <div style={S.muted}>Type the code shown on {name}'s screen.</div>
      <div style={S.row}>
        <input style={S.field} data-code inputMode="numeric" maxLength={6} value={code} placeholder="123456" onInput={(e) => setCode((e.target as HTMLInputElement).value)} />
        <button style={{ ...S.btn, ...S.btnOn }} data-confirm disabled={working || code.trim().length !== 6} onClick={() => confirm(code.trim())}>
          {working ? "Pairing..." : "Pair"}
        </button>
      </div>
      <button style={S.ghost} onClick={cancel}>Cancel</button>
    </>
  );
}
