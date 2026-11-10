#!/usr/bin/env python3
"""Real phone failure: Steam is in host background data AND has a rendered card."""
import pathlib
import subprocess
import unittest
ROOT = pathlib.Path(__file__).resolve().parents[2]

class Count(unittest.TestCase):
    def test_actual_filter_contract(self):
        src = (ROOT / 'shell/dev/device-checks.js').read_text()
        body = src.split('export function backgroundWithoutCards(listed, tasks, ids) {', 1)[1].split('\n}', 1)[0]
        script = 'const assert=require("node:assert/strict"); function filter(listed,tasks,ids) {' + body + '}\n' + '''
const listed = ['messages','home','wireguard','l:steam','companion'].map(key=>({key}));
const tasks = [{id:536870966,key:'l:steam'},{id:3414,key:'termux'},{id:3420,key:null}];
assert.equal(filter(listed,tasks,[536870966,3414]).length,4);
assert.deepEqual(filter(listed,tasks,[536870966,3414]).map(x=>x.key),['messages','home','wireguard','companion']);
assert.equal(filter(listed,tasks,[]).length,5); // hidden/unrendered cards exclude nothing
assert.equal(filter(listed,tasks,[3414]).length,5); // unrelated Termux is never removed
assert.equal(filter(listed,[...tasks,{id:7,key:'l:steam'}],[536870966,7]).length,4);
'''
        subprocess.run(['node','-e',script],check=True)
        self.assertIn('s.toggle !== `${bg.length} running in background`', src)
        self.assertIn('rows.length === count', src)

if __name__ == '__main__': unittest.main()
