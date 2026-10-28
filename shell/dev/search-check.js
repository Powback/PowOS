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
    s.query.value = 'dock position';
    await wait(() => search.searchResults.value.filter(r => r.source === 'Settings').length === 3);
    await wait(() => document.querySelectorAll('[data-search-result^="settings:style:"]').length === 3);
    document.querySelector('[data-search-result="settings:style:desktop dock position"]').click();
    await wait(() => document.activeElement?.dataset.setting === 'desktop dock position');
    const box = document.activeElement.getBoundingClientRect();
    if (box.top < 0 || box.bottom > innerHeight) failures.push('setting opened outside viewport');
    if (s.drawer.value !== 0 || screens.screens.value.at(-1) !== 'style') failures.push('setting did not open');
    await checkDockTargets(search, screens);
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
