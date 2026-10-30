/**
 * "Still broken" on a card that asked the user to try something (powai.tsx): a one-line reply on the card - typed, or
 * the mic (hold to talk and send, tap to dictate, as PowOS AI's own field) - and an optional screenshot, a thumbnail
 * (a tap: full screen; x takes it off). Send hands both to the card (a user FAIL check + the manager's inbox, linked
 * to the task); its words stay here, per card, until that went through (clearBroken).
 */
import { signal } from "@preact/signals";
import { powos } from "../bridge.ts";
import { Pill, hearing, type MicTarget } from "./bar.tsx";
import { imageUrl, openFull } from "./rich.tsx";

/** What the user wrote with "still broken" and the screenshot they attached, if any (a path PowOS AI can read). */
export interface Broken {
  text: string;
  image: string | null;
}

/** The reply lines' words and screenshots by card: kept while the line is closed or a send failed. */
const drafts = signal<Record<string, Broken>>({});
const attaching = signal(false);
const draftOf = (id: string): Broken => drafts.value[id] ?? { text: "", image: null };
const setDraft = (id: string, b: Partial<Broken>) => (drafts.value = { ...drafts.value, [id]: { ...draftOf(id), ...b } });

/**
 * A screenshot to send along: the screen as the assistant saw it (side button), else the last moments that changed
 * (live mode's filmstrip). Null where the host has neither: the button says so.
 */
async function capture(): Promise<string | null> {
  const a = powos.assist;
  const shot = await a.attach(null).catch(() => null);
  return shot ?? (await a.filmstrip().catch(() => null));
}

async function attach(id: string, failed: () => void) {
  attaching.value = true;
  const image = await capture();
  attaching.value = false;
  if (image) setDraft(id, { image });
  else failed();
}

function Thumb({ id, path }: { id: string; path: string }) {
  const url = imageUrl(path);
  if (!url) return null;
  return (
    <span class="ai-reply-thumb">
      <button type="button" class="ai-img" onClick={() => openFull("your screenshot", <img class="ai-img-full" src={url} alt="" />)}>
        <img src={url} alt="your screenshot" />
      </button>
      <button type="button" class="ai-reply-x" aria-label="remove the screenshot" onClick={() => setDraft(id, { image: null })}>
        ×
      </button>
    </span>
  );
}

const noShot = signal<string | null>(null);

/** Sends card [id]'s line (its words, or what the mic heard) and its screenshot; nothing while it has no words. */
function sendDraft(id: string, onSend: (b: Broken) => void, text = draftOf(id).text) {
  const t = text.trim();
  if (!t) return;
  onSend({ text: t, image: draftOf(id).image });
}

/** Card [id]'s reply went through: its line starts empty next time. */
export const clearBroken = (id: string) => {
  const { [id]: _, ...rest } = drafts.value;
  drafts.value = rest;
};

/** One mic target per card (dictation.ts knows its target by identity), sending through that card's latest onSend. */
const mics = new Map<string, { target: MicTarget; onSend: (b: Broken) => void }>();
function micOf(id: string, onSend: (b: Broken) => void): MicTarget {
  let m = mics.get(id);
  if (!m) {
    const entry = { onSend, target: null as unknown as MicTarget };
    entry.target = { typed: () => draftOf(id).text, heard: (full, sendIt) => (sendIt ? sendDraft(id, entry.onSend, full) : setDraft(id, { text: full })) };
    mics.set(id, (m = entry));
  }
  m.onSend = onSend;
  return m.target;
}

export function BrokenReply({ id, onSend, onCancel }: { id: string; onSend: (b: Broken) => void; onCancel: () => void }) {
  const d = draftOf(id);
  const mic = micOf(id, onSend);
  return (
    <form
      class="ai-reply"
      onSubmit={(e) => {
        e.preventDefault();
        sendDraft(id, onSend);
      }}
    >
      <Pill target={mic} send value={hearing(mic) ?? d.text} onInput={(v: string) => setDraft(id, { text: v })} onFocus={() => powos.keyboard.show()} placeholder="what's still wrong?" aria-label="what's still wrong" enterKeyHint="send" autocomplete="off" autofocus />
      <div class="ai-reply-foot">
        {d.image ? <Thumb id={id} path={d.image} /> : (
          <button type="button" class="ai-act quiet" disabled={attaching.value} onClick={() => void attach(id, () => (noShot.value = id))}>
            {attaching.value ? "taking…" : noShot.value === id ? "no screen to add" : "add screenshot"}
          </button>
        )}
        <button type="button" class="ai-act quiet" onClick={onCancel}>
          cancel
        </button>
      </div>
    </form>
  );
}
