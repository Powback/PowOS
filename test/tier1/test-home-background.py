#!/usr/bin/env python3
"""Exercise the switcher's actual async handlers with controlled host responses."""
import pathlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class HomeBackground(unittest.TestCase):
    def test_background_requests_and_optimistic_stop(self):
        source = (ROOT / 'shell/ui/recents.tsx').read_text()
        ask = source.split('function askBackground() {', 1)[1].split('\n}\n', 1)[0]
        stop = source.split('function stopBackground(b: BackgroundApp) {', 1)[1].split('\n}\n', 1)[0]
        stop = stop.replace('(ok: boolean)', '(ok)')
        script = '''
const assert = require('node:assert/strict');
const sig = (value) => ({value, peek() { return this.value; }});
const background = sig([]), backgroundLoading = sig(false), backgroundError = sig(false), stopping = sig(new Set());
let backgroundRequest = 0;
const requests = [], notes = [];
const showNote = n => notes.push(n);
let stopResolve;
const powos = {apps: {
 background: () => new Promise((resolve, reject) => requests.push({resolve, reject})),
 stopBackground: () => new Promise(r => stopResolve = r)
}};
const flush = async () => { for (let i=0;i<8;i++) await Promise.resolve(); };
''' + 'function askBackground() {' + ask + '\n}\n' + 'function stopBackground(b) {' + stop + '\n}\n' + '''
(async () => {
 const app = {key:'a:termux', label:'Termux'};
 askBackground();
 assert.equal(backgroundLoading.value, true, 'loading is synchronous');
 await flush();
 askBackground(); await flush();
 requests[1].resolve([app]); await flush();
 requests[0].resolve([]); await flush();
 assert.deepEqual(background.value, [app], 'old request cannot overwrite new');
 askBackground(); await flush();
 requests[2].reject(new Error('offline')); await flush();
 assert.equal(backgroundError.value, true);
 assert.deepEqual(background.value, [app], 'failure preserves rows for retry');
 askBackground(); await flush();
 stopBackground(app);
 assert.equal(stopping.value.has(app.key), true, 'stop hides synchronously');
 await flush();
 requests[3].resolve([app]); await flush();
 stopResolve(true); await flush();
 assert.deepEqual(background.value, []);
 requests[4].resolve([]); await flush();
 background.value = [app];
 stopBackground(app); await flush(); stopResolve(false); await flush();
 assert.equal(stopping.value.size, 0);
 assert.deepEqual(background.value, [app], 'failed stop restores row');
 assert.equal(notes.at(-1), "Couldn't stop Termux");
 powos.apps.stopBackground = () => {throw Error('bridge down')};
 stopBackground(app); await flush();
 assert.equal(stopping.value.size, 0, 'sync bridge failure also rolls back');
})().catch(e => {console.error(e); process.exitCode=1});
'''
        subprocess.run(['node', '-e', script], check=True)

    def test_pill_gutter_applies_to_both_screens(self):
        css = (ROOT / 'shell/ui/shell.css').read_text()
        self.assertIn('.home:has(> .bar .bar-pill) > .stage > .home-dots { bottom: var(--gap); }', css)
        self.assertNotIn('.home:not(.wide):has(> .bar .bar-pill) > .stage > .home-dots', css)
        self.assertIn('--content-foot: calc(var(--gap) + var(--bar-edit-rise, 0px));', css)


if __name__ == '__main__':
    unittest.main()
