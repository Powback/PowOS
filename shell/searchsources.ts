/**
 * The launcher search's personal sources: the phone's contacts and files (SearchSources.kt, through powos.search), quick
 * math inline (searchmath.ts) and "Search the web for …". search.ts registers the providers ([personalProviders]); the
 * pure parts are here so they stay free of the launcher's state.
 *
 * Contacts and files need READ_CONTACTS / READ_MEDIA_*: asked the PowOS way - explicitly, once, from an "Allow" row
 * under the results (never a dialog popping up while typing). Until it's tapped, and after a "no", those sources are
 * empty and show no placeholder.
 */
import { signal } from "@preact/signals";
import { powos } from "./bridge.ts";
import { answer } from "./searchmath.ts";
import type { SearchContact, SearchFile, SearchSourceState } from "./types.ts";
import type { SearchGroup, SearchProvider, SearchResult } from "./search.ts";

export const CONTACTS: SearchGroup = { id: "contacts", label: "Contacts" };
export const FILES: SearchGroup = { id: "files", label: "Files" };
const ALLOW: SearchGroup = { id: "search-allow", label: "Contacts and files" };

/** Bumped when what the sources may read changed ("search.permission"): the open search runs again. */
export const sourcesRevision = signal(0);
let state: SearchSourceState | null = null;
let stateAt = 0;
async function sourceState() {
  if (!powos.search) return null;
  if (!state || Date.now() - stateAt > 30_000) {
    state = await powos.search.state().catch(() => null);
    stateAt = Date.now();
  }
  return state;
}
powos.on("search.permission", () => { state = null; void sourceState().then(() => sourcesRevision.value++); });
// Known before the first search, so its placeholders can show from the first key.
queueMicrotask(() => void sourceState().then(() => sourcesRevision.value++));

/** "2 days ago", "3 Nov" - when a file was last changed. */
function when(ms: number) {
  const days = Math.floor((Date.now() - ms) / 86_400_000);
  if (days < 1) return "Today";
  if (days === 1) return "Yesterday";
  if (days < 7) return `${days} days ago`;
  return new Date(ms).toLocaleDateString(undefined, { day: "numeric", month: "short", year: days > 300 ? "numeric" : undefined });
}

function contactResult(c: SearchContact, text: string): SearchResult {
  return {
    id: `contact:${c.id}`, label: c.name, source: "Contacts", group: CONTACTS, detail: c.number,
    // Matched by the phone (a nickname, an email): kept whatever the launcher's own word match thinks.
    keywords: `${c.number ?? ""} contact person people ${text}`,
    open: () => void powos.search?.open("contact", c.id),
    action: c.number ? { label: "Call", run: () => void powos.search?.open("call", c.id) } : undefined,
  };
}

function fileResult(f: SearchFile, text: string): SearchResult {
  return {
    id: `file:${f.id}`, label: f.name, source: "Files", group: FILES, detail: [f.folder, when(f.modified)].filter(Boolean).join(" · "),
    keywords: `file document ${f.folder} ${text}`,
    open: () => void powos.search?.open("file", f.id),
  };
}

/** The providers for search.ts's registry: contacts, files, and the "Allow" row while that's still to ask. */
export function personalProviders(): SearchProvider[] {
  return [
    {
      id: "contacts",
      placeholder: () => (state?.contacts ? CONTACTS : null),
      async search(text, abort) {
        const s = await sourceState();
        if (!s?.contacts || abort.aborted) return [];
        const found = await powos.search!.contacts(text).catch(() => []);
        return found.map((c) => contactResult(c, text));
      },
    },
    {
      id: "files",
      placeholder: () => (state?.files ? FILES : null),
      async search(text, abort) {
        const s = await sourceState();
        if (!s?.files || abort.aborted) return [];
        const found = await powos.search!.files(text).catch(() => []);
        return found.map((f) => fileResult(f, text));
      },
    },
    {
      id: "search-allow",
      async search(text) {
        const s = await sourceState();
        if (!s?.ask) return [];
        return [{
          id: "search-allow", label: "Allow contacts and files in search", source: "PowOS", group: ALLOW, hint: true,
          detail: "Find people and files as you type. Asked once.", keywords: text,
          open: () => {
            void powos.search?.ask().then(() => { state = null; return sourceState(); }).then(() => sourcesRevision.value++);
          },
        }];
      },
    },
  ];
}

/** The inline answer to [q] (math, a conversion): a result whose tap copies the value. Null: not math. */
export function mathResult(q: string): SearchResult | null {
  const a = q ? answer(q) : null;
  if (!a) return null;
  return {
    id: "math", label: a.value, detail: `${a.expression} =`, source: "Calculator",
    open: () => { void powos.clipboard.write(a.value.replace(/\s.*$/, "")); },
  };
}

/** The last result: [q] on the web (the phone's web search; elsewhere the browser). */
export function webResult(q: string): SearchResult | null {
  if (!q) return null;
  return {
    id: "web", label: `Search the web for “${q}”`, source: "Web",
    open: () => {
      if (powos.search) void powos.search.web(q).catch(() => window.open(`https://www.google.com/search?q=${encodeURIComponent(q)}`, "_blank"));
      else window.open(`https://www.google.com/search?q=${encodeURIComponent(q)}`, "_blank");
    },
  };
}
