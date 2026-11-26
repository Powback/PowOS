/**
 * The launcher search's personal sources (searchsources.ts) against the mock host's contacts and files (bridge.ts
 * mockSearch, answering after 250 ms): placeholders from the first key until each source answers, a contact (tap opens,
 * Call calls), a file (tap opens), math inline, "Search the web for …" as the last row, unmatched text still a chat, and
 * the "Allow" row asking once. Returns failures.
 */
export async function searchSourcesCheck() {
  const s = await importShim("./state.ts");
  const search = await importShim("./search.ts");
  const m = window.__searchMock;
  const old = { query: s.query.value, drawer: s.drawer.value, state: { ...m.state } };
  const fails = [];
  const t = {
    s, search, m,
    f: (ok, msg) => ok || fails.push(msg),
    ask: async (text) => { s.drawer.value = 1; s.query.value = ""; await new Promise((r) => setTimeout(r, 30)); s.query.value = text; },
  };
  try {
    for (const step of [contactStep, fileStep, mathStep, chatStep, allowStep]) await step(t);
  } catch (e) {
    fails.push(String(e));
  } finally {
    m.state = old.state;
    window.__mockEvents.emit("search.permission", null);
    s.query.value = old.query;
    s.drawer.value = old.drawer;
  }
  return fails;
}

async function until(fn, ms = 3000) {
  for (let t = 0; t < ms; t += 25) {
    if (fn()) return true;
    await new Promise((r) => setTimeout(r, 25));
  }
  return false;
}
const q = (sel) => document.querySelector(`.drawer-list.results ${sel}`);
const INGRID = '[data-search-result="contact:101/lk-ingrid"]';

/** Placeholders at once (inside the 100 ms debounce), gone once their source answered; the contact, its Call; web last. */
async function contactStep({ f, m, ask }) {
  await ask("ingrid");
  f(await until(() => q('[data-search-placeholder="contacts"]') && q('[data-search-placeholder="files"]'), 200), "no contacts/files placeholders while they're read");
  f(await until(() => q(INGRID)), "Ingrid Solberg not in the results");
  f(await until(() => !q("[data-search-placeholder]")), "a placeholder stayed after its source answered");
  f(/912 34 567/.test(q(INGRID)?.textContent ?? ""), "the contact row has no number");
  const results = document.querySelector(".launcher-search-results");
  const bottomUp = document.querySelector(".drawer-list.results")?.dataset.order === "bottom-up";
  const last = bottomUp ? results.firstElementChild : results.lastElementChild;
  f(last?.dataset.searchResult === "web" && /Search the web for “ingrid”/.test(last.textContent), `the web row isn't last (${last?.className})`);
  m.opened.length = 0;
  q('[data-search-action="contact:101/lk-ingrid"]')?.click();
  f(m.opened.some(([k, id]) => k === "call" && id === "101/lk-ingrid"), "Call didn't call the contact");
}

/** A file by name: its folder shown; a tap opens it. */
async function fileStep({ f, m, ask }) {
  await ask("invoice");
  f(await until(() => q('[data-search-result="file:9001"]')), "invoice-november.pdf not found");
  f(/Download/.test(q('[data-search-result="file:9001"]')?.textContent ?? ""), "the file row has no folder");
  m.opened.length = 0;
  q('[data-search-result="file:9001"]')?.click();
  f(m.opened.some(([k, id]) => k === "file" && id === "9001"), "tapping the file didn't open it");
}

/** Math inline as a result (never a chat), a conversion, and the web row searching. */
async function mathStep({ f, m, search, ask }) {
  await ask("12*7");
  f(await until(() => q('[data-search-result="math"]')?.textContent?.includes("84")), "12*7 shows no 84");
  await until(() => !search.searchPending.value);
  f(!document.querySelector(".drawer .chat") && !!q('[data-search-result="math"]'), "12*7 became a chat");
  await ask("5 km in miles");
  f(await until(() => /3\.10\d* mi/.test(q('[data-search-result="math"]')?.textContent ?? "")), "5 km in miles not converted");
  m.opened.length = 0;
  q('[data-search-result="web"]')?.click();
  f(m.opened.some(([k, text]) => k === "web" && text === "5 km in miles"), "the web row didn't search the web");
}

/** Text that finds nothing is still a chat: the web row and the placeholders never count as results. */
async function chatStep({ f, search, ask }) {
  await ask("__powos_unmatched_chat_5521");
  f(await until(() => !search.searchPending.value && search.searchResults.value.length === 0 && !search.searchAnswer.value), "unmatched text found something");
}

/** Not allowed yet: no placeholders, an "Allow" row under other results; tapped, it asks once and contacts come in. */
async function allowStep({ f, m, ask }) {
  m.state = { contacts: false, files: false, ask: true };
  window.__mockEvents.emit("search.permission", null);
  await new Promise((r) => setTimeout(r, 60));
  m.asked = 0;
  // Under other results only: on its own it would turn every unmatched text away from the chat.
  await ask("wallpaper");
  f(await until(() => q('[data-search-result="search-allow"]')), "no Allow row before contacts/files are allowed");
  f(!q("[data-search-placeholder]"), "placeholders for sources that may not be read");
  q('[data-search-result="search-allow"]')?.click();
  f(m.asked === 1, `Allow asked ${m.asked} times`);
  f(await until(() => !q('[data-search-result="search-allow"]')), "the Allow row stayed after it was answered");
  await ask("ingrid");
  f(await until(() => q(INGRID)), "contacts didn't come in once allowed");
}
