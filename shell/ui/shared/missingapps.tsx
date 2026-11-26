/**
 * "N apps missing" on a device, opened into WHICH apps (the user, 11-26: "only a COUNT - no way to see WHICH apps are
 * missing"): a toggle with the count, folding open (Reveal) into one line per app - its icon (this device's, else its
 * initial), its name and how it gets onto that device (devicesview.ts missingNote). The AI page's Devices tab
 * (ui/aidevices.tsx) and the Devices app (apps/devices, `@powos/shared/missingapps`) both draw it, from the same realm
 * list (powos-account-sync's last report per device). Styled inline on the theme's tokens, so it looks the same in
 * the shell and in an app's own page.
 */
import { useState } from "preact/hooks";
import { Reveal } from "./reveal.tsx";
import { missingApps, missingNote, type AccountDevice, type KnownApps, type MissingApp } from "./devicesview.ts";

const S: Record<string, Record<string, string | number>> = {
  toggle: { font: "inherit", fontSize: "var(--text-small, 13px)", color: "var(--status-stalled, #d08a2b)", background: "none", border: 0, padding: 0, cursor: "pointer", display: "inline-flex", alignItems: "center", gap: "4px", minHeight: "24px" },
  list: { listStyle: "none", margin: "6px 0 0", padding: 0, display: "flex", flexDirection: "column", gap: "6px" },
  row: { display: "flex", alignItems: "center", gap: "10px", minWidth: 0 },
  icon: { width: "28px", height: "28px", borderRadius: "8px", flex: "none", objectFit: "cover" },
  initial: { width: "28px", height: "28px", borderRadius: "8px", flex: "none", display: "grid", placeItems: "center", background: "var(--color-surface-2, rgba(127,127,127,.18))", fontWeight: 600, fontSize: "14px" },
  text: { display: "flex", flexDirection: "column", minWidth: 0 },
  name: { fontSize: "14px", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" },
  note: { fontSize: "12px", opacity: 0.7, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" },
};

function Face({ m }: { m: MissingApp }) {
  const [broken, setBroken] = useState(false);
  if (m.icon && !broken) return <img style={S.icon} src={m.icon} alt="" onError={() => setBroken(true)} />;
  return (
    <span style={S.initial} aria-hidden="true">
      {m.name.slice(0, 1).toUpperCase()}
    </span>
  );
}

/** [d]'s missing apps: the count as a toggle, the list under it; just the count when the report names none (an older agent). */
export function MissingApps({ d, known, label }: { d: AccountDevice; known: KnownApps; label: string }) {
  const [open, setOpen] = useState(false);
  const { apps, more } = missingApps(d, known);
  if (!apps.length) return label ? <span style={{ ...S.toggle, cursor: "default" }} data-sync>{label}</span> : null;
  const device = d.name || "it";
  return (
    <div data-missing={d.id}>
      <button type="button" style={S.toggle} aria-expanded={open} data-missing-toggle data-sync onClick={() => setOpen(!open)}>
        {label}
      </button>
      <span style={S.toggle} aria-hidden="true" onClick={() => setOpen(!open)}>
        {open ? "▴" : "▾"}
      </span>
      <Reveal open={open}>
        <ul style={S.list} data-missing-list>
          {apps.map((m) => (
            <li key={m.id} style={S.row} data-missing-app={m.id} data-how={m.how}>
              <Face m={m} />
              <span style={S.text}>
                <span style={S.name} data-missing-name>{m.name}</span>
                <span style={S.note}>{missingNote(m, device)}</span>
              </span>
            </li>
          ))}
          {more > 0 && <li style={S.note}>and {more} more</li>}
        </ul>
      </Reveal>
    </div>
  );
}
