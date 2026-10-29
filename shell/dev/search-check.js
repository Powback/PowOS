/** Runs in the real shell module graph in both Chromium and the queued phone check. */
export async function launcherSearchCheck() {
  const s = await importShim('./state.ts');
  const search = await importShim('./search.ts');
  const screens = await importShim('./screens.ts');
  const old = { query: s.query.value, drawer: s.drawer.value, screens: screens.screens.value, target: screens.screenTarget.value };
  const wait = async (f) => { for (let i = 0; i < 60; i++) { if (f()) return; await new Promise(r => setTimeout(r, 50)); } throw Error('search timed out'); };
  const failures = [];
  let off;
  try {
    s.drawer.value = 1;
    await checkAppIcons(s, search, wait);
    s.query.value = 'dock position';
    await wait(() => search.searchResults.value.filter(r => r.source === 'Settings').length === 3);
    await wait(() => document.querySelectorAll('[data-search-result^="settings:style:"]').length === 3);
    document.querySelector('[data-search-result="settings:style:desktop dock position"]').click();
    await wait(() => document.activeElement?.dataset.setting === 'desktop dock position');
    failures.push(...highlightFailures(document.activeElement));
    const box = document.activeElement.getBoundingClientRect();
    if (box.top < 0 || box.bottom > innerHeight) failures.push('setting opened outside viewport');
    if (s.drawer.value !== 0 || screens.screens.value.at(-1) !== 'style') failures.push('setting did not open');
    await checkDockTargets(search, screens);
    await checkGestureTargets(screens);
    await checkNativeSettings(s, search, wait);
    await checkUnmatchedChat(s, search, wait);
    screens.closeScreens();
    let opened = false;
    off = search.registerSearchProvider({ id: 'search-test', async search(q) {
      await new Promise(r => setTimeout(r, q === 'oldresult' ? 350 : 20));
      return [{ id: q, label: q, source: 'Test app', open() { opened = true; } }];
    }});
    s.query.value = 'oldresult';
    await new Promise(r => setTimeout(r, 150));
    s.query.value = 'newresult';
    await wait(() => search.searchResults.value.some(r => r.id === 'newresult'));
    await new Promise(r => setTimeout(r, 400));
    if (!hasCurrentResult(search.searchResults.value)) failures.push('stale result replaced new query');
    search.openSearchResult(search.searchResults.value.find(r => r.id === 'newresult'));
    if (!opened) failures.push('provider destination did not open');
    off(); off = null;
    s.query.value = 'dock position'; s.drawer.value = 1;
    await wait(() => search.searchResults.value.some(r => r.source === 'Settings'));
    const best = search.searchResults.value[0];
    document.querySelector('.home > .bar').dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
    if (screens.screenTarget.value !== best.label) failures.push('Enter did not open best setting');
  } catch (e) { failures.push(String(e)); }
  finally { off?.(); screens.screens.value = old.screens; screens.screenTarget.value = old.target; s.query.value = old.query; s.drawer.value = old.drawer; }
  return failures;
}

function hasCurrentResult(results) {
  return results.some(r => r.id === "newresult") && !results.some(r => r.id === "oldresult");
}

async function checkDockTargets(search, screens) {
  for (const entry of search.settingDestinations.filter(s => s.label.includes('dock position'))) {
    screens.openScreen(entry.screen, entry.target);
    await waitForSetting(entry.target);
  }
}

async function waitForSetting(target) {
  for (let i = 0; i < 60; i++) {
    if (document.activeElement?.dataset.setting === target) return;
    await new Promise(r => setTimeout(r, 50));
  }
  throw Error(`missing setting target: ${target}`);
}

async function checkNativeSettings(state, search, wait) {
  const { powos } = await importShim('./bridge.ts');
  const pages = await powos.qs.destinations?.().catch(() => []) ?? [];
  for (const page of pages.filter(p => ['VPN', 'Wi-Fi', 'Bluetooth', 'Accessibility', 'Screen refresh rate'].includes(p.label))) {
    state.query.value = page.label === 'Wi-Fi' ? 'wifi' : page.label;
    await wait(() => search.searchResults.value.some(r => r.id === `android-settings:${page.id}`));
  }
}

async function checkGestureTargets(screens) {
  for (const side of ['left', 'right']) {
    screens.openScreen('gestures', `${side} edge/handle`);
    for (let i = 0; i < 60; i++) {
      const active = document.activeElement;
      if (active?.dataset.setting === 'handle' && active.closest('section')?.dataset.setting === `${side} edge`) break;
      if (i === 59) throw Error(`wrong ${side} gesture search target`);
      await new Promise(r => setTimeout(r, 50));
    }
  }
}

function highlightFailures(element) {
  return element.dataset.searchHighlight === 'true' ? [] : ['setting opened without highlight'];
}

async function checkUnmatchedChat(state, search, wait) {
  state.query.value = '__powos_unmatched_chat_814765';
  await wait(() => !search.searchPending.value && search.searchResults.value.length === 0);
  state.query.value = 'search android settings';
  await wait(() => !search.searchPending.value);
  if (search.searchResults.value.some(r => r.id === 'android-settings:settings-search')) throw Error('generic settings action stole chat input');
}

/**
 * Typing in the launcher's chat (the user, 2026-10-28 17:05 and 19:53: "launcher chat refreshes every keypress"): in a
 * chat the pill is the next message, never a search. Five keys must run no search, flip no searchPending, replace no
 * node of the drawer or the chat, re-render none of its messages and leave its scroll where it was. Returns
 * [failures, counts].
 */
export async function launcherChatTypingCheck() {
  const s = await importShim('./state.ts');
  const search = await importShim('./search.ts');
  const { effect } = await importShim('@preact/signals');
  const frame = () => new Promise(r => requestAnimationFrame(() => setTimeout(r, 0)));
  const wait = async (f) => { for (let i = 0; i < 60; i++) { if (f()) return; await new Promise(r => setTimeout(r, 50)); } throw Error('chat typing: timed out'); };
  const counts = { searches: 0, pendingFlips: 0, drawerReplaced: 0, chatReplaced: 0, messagesChanged: 0, scrollMoved: 0 };
  const off = search.registerSearchProvider({ id: 'chat-typing-probe', search() { counts.searches++; return []; } });
  let stop = () => {};
  const observers = [];
  try {
    s.query.value = '';
    s.drawer.value = 1;
    s.ask('hi');
    // The mock's turn (bridge.ts ai.send) streams for ~1 s and its events replace the chat: the keys come after it.
    await wait(() => s.chat.value.items.some(i => i.kind === 'assistant') && !s.chat.value.busy);
    // A history longer than the panel, so its scroll can be checked.
    const said = Array.from({ length: 30 }, (_, i) => ({ kind: 'user', text: `line ${i} of an earlier chat` }));
    s.chat.value = { ...s.chat.value, busy: false, items: said };
    await wait(() => s.chatting.value && document.querySelector('.drawer .chat'));
    await frame(); await frame();
    const drawer = document.querySelector('.drawer');
    const chat = drawer.querySelector('.chat');
    chat.scrollTop = Math.max(0, Math.floor((chat.scrollHeight - chat.clientHeight) / 2));
    const top = chat.scrollTop;
    let pending = search.searchPending.value;
    stop = effect(() => { const p = search.searchPending.value; if (p !== pending) { counts.pendingFlips++; pending = p; } });
    const drawerKids = [...drawer.children];
    observers.push(watchChat(drawer, chat, counts));
    for (const ch of 'hello') {
      s.query.value += ch;
      await new Promise(r => setTimeout(r, 160)); // past search.ts's 100 ms debounce, as a typist's keys are
      if (chat.scrollTop !== top) counts.scrollMoved++;
    }
    await frame();
    if (drawer.querySelector('.chat') !== chat) counts.chatReplaced++;
    if (drawerKids.some(n => !n.isConnected)) counts.drawerReplaced++;
  } finally {
    observers.forEach(o => o.disconnect());
    stop(); off();
    s.query.value = '';
    s.closeDrawer();
  }
  const failures = chatTypingFailures(counts);
  failures.push(...await noMatchTypingFailures(s, search, wait, counts));
  return [failures, counts];
}

/**
 * A new chat message (not yet `chatting`; the user, 2026-10-29: "im typing in the launcherchat and it triggers a search
 * even after no search results"): once the text found nothing, more letters - even an app's name, which the probe here
 * would match - neither search nor show results, nor does deleting letters; the "↵ ask" line still shows the text;
 * an emptied pill searches again from scratch.
 */
async function noMatchTypingFailures(s, search, wait, counts) {
  const app = s.apps.value[0]?.label ?? 'Settings';
  const probe = { searches: 0, shown: 0 };
  const off = search.registerSearchProvider({ id: 'chat-nomatch-probe', search(text) {
    probe.searches++;
    return text.toLocaleLowerCase().includes(app.toLocaleLowerCase()) ? [{ id: `probe:${text}`, label: text, source: 'Probe', open() {} }] : [];
  } });
  const key = async (ch) => {
    s.query.value += ch;
    await new Promise(r => setTimeout(r, 160)); // past search.ts's 100 ms debounce
    probe.shown += search.searchResults.value.length || document.querySelectorAll('[data-search-result]').length ? 1 : 0;
  };
  try {
    s.closeDrawer();
    s.drawer.value = 1;
    for (const ch of 'zqxw') await key(ch);
    await wait(() => !search.searchPending.value);
    const chattingAlready = s.chatting.value;
    Object.assign(probe, { searches: 0, shown: 0 });
    for (const ch of ` open ${app}`) await key(ch);
    Object.assign(counts, { noMatchSearches: probe.searches, noMatchShown: probe.shown });
    await new Promise(r => requestAnimationFrame(() => setTimeout(r, 0)));
    const asked = document.querySelector('.msg.ask')?.textContent.includes(app);
    s.query.value = 'zq';
    await new Promise(r => setTimeout(r, 160));
    const afterDelete = probe.searches;
    s.query.value = '';
    await key('z');
    await wait(() => !search.searchPending.value);
    return [
      [chattingAlready, 'chatting was already set, the case is not tested'],
      [afterDelete, `deleting letters ran ${afterDelete} searches`],
      [probe.searches === afterDelete, 'an emptied pill did not search again'],
      [counts.noMatchSearches, `${counts.noMatchSearches} searches after the text found nothing`],
      [counts.noMatchShown, `results shown on ${counts.noMatchShown} keys after the text found nothing`],
      [!asked, 'no "↵ ask" line for the text'],
    ].filter(([bad]) => bad).map(([, m]) => `no-match typing: ${m}`);
  } finally {
    off();
    s.closeDrawer();
  }
}

/** Counts, into [counts], the drawer's children replaced and every change inside the chat but its "↵ ask" line. */
function watchChat(drawer, chat, counts) {
  const inHint = (n) => !!(n.nodeType === 1 ? n : n.parentElement)?.closest?.('.msg.ask');
  const hintOnly = (r) => [...r.addedNodes, ...r.removedNodes].every(inHint) && (r.addedNodes.length + r.removedNodes.length > 0 || inHint(r.target));
  const mo = new MutationObserver((recs) => {
    for (const r of recs) {
      if (r.target === drawer && r.type === 'childList') counts.drawerReplaced += r.removedNodes.length;
      else if (!hintOnly(r)) counts.messagesChanged++;
    }
  });
  mo.observe(drawer, { childList: true });
  mo.observe(chat, { childList: true, subtree: true, characterData: true, attributes: true });
  return mo;
}

function chatTypingFailures(counts) {
  const said = [
    [counts.searches, `typing ran ${counts.searches} searches`],
    [counts.pendingFlips, `typing flipped searchPending ${counts.pendingFlips} times`],
    [counts.drawerReplaced || counts.chatReplaced, `typing replaced the drawer's nodes ${counts.drawerReplaced}x, the chat ${counts.chatReplaced}x`],
    [counts.messagesChanged, `typing re-rendered the messages (${counts.messagesChanged} DOM changes)`],
    [counts.scrollMoved, `typing moved the chat's scroll on ${counts.scrollMoved} of 5 keys`],
  ];
  return said.filter(([n]) => n).map(([, m]) => `launcher chat: ${m}`);
}

async function checkAppIcons(state, search, wait) {
  const apps = state.apps.value.filter(a => a.icon);
  if (!apps.length) throw Error('no apps to verify search icons');
  for (const kind of new Set(apps.map(a => a.kind))) {
    const app = apps.find(a => a.kind === kind);
    state.query.value = app.label;
    await wait(() => search.searchResults.value.some(r => r.id === `app:${app.key}`));
    const result = search.searchResults.value.find(r => r.id === `app:${app.key}`);
    if (result.icon !== app.icon) throw Error(`${kind} search lost the app icon`);
    await wait(() => [...document.querySelectorAll('[data-search-result]')].some(row => {
      const img = row.querySelector('.app-icon img');
      return row.dataset.searchResult === result.id && img?.complete && img.naturalWidth > 0;
    }));
  }
}
