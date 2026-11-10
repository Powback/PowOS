#!/usr/bin/env python3
"""Probe regressions; no device access or generated fixture files."""
import importlib.util
import json
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
V = ROOT / 'tools/phone/verify'
spec = importlib.util.spec_from_file_location('resize_state', V / 'resize-state.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def capture(round_=False, active=True, off=False, prop=None):
    prop = int(round_) if prop is None else prop
    radius = '    cornerRadius=< 33.15, 33.15 >\n' if round_ else ''
    states = '\n'.join('T ' + json.dumps(dict(at=t, active=active, epoch=1, off=off)) for t in (999, 1050, 1101))
    return (f'WWR_BEGIN 1000\nWWR_PROP {prop}\nWWR_SF_BEGIN\n'
            '  Layer [11887] powos-ww-4#11887\n    bounds={0,0,100,100}\n' + radius +
            f'WWR_SF_END\nWWR_PROP {prop}\nWWR_END 1100\n' + states)


class ResizeState(unittest.TestCase):
    def test_square(self):
        self.assertIn('VALID', m.validate(capture(), 'T', 4, False, True))

    def test_round(self):
        self.assertIn('VALID', m.validate(capture(True), 'T', 4, True, True))

    def test_wrong_setting(self):
        for text in (capture(prop=1), capture(off=True)):
            with self.assertRaises(ValueError):
                m.validate(text, 'T', 4, False, True)

    def test_outside_drag(self):
        with self.assertRaisesRegex(ValueError, 'outside'):
            m.validate(capture(active=False), 'T', 4, False, True)

    def test_wrong_applied_radius(self):
        with self.assertRaisesRegex(ValueError, 'radius'):
            m.validate(capture(True, prop=0), 'T', 4, False, True)

    def test_blur(self):
        with self.assertRaisesRegex(ValueError, 'blur remains'):
            m.validate(capture().replace('bounds=', 'blurRegions.size()=8 bounds='), 'T', 4, False, True)

    def test_missing_container(self):
        with self.assertRaisesRegex(ValueError, 'container'):
            m.validate(capture().replace('powos-ww-4#', 'powos-ww-4-linux#'), 'T', 4, False, True)

    def test_regrab(self):
        text = capture().replace('"at": 1101, "active": true, "epoch": 1', '"at": 1101, "active": true, "epoch": 3')
        with self.assertRaisesRegex(ValueError, 'outside'):
            m.validate(text, 'T', 4, False, True)

    def test_observer_actual_schema(self):
        # Lock this observer to entry()/sizeOf()/geometry(), not an invented export.
        source = (ROOT / 'shell/ui/webwindows.tsx').read_text()
        self.assertIn('return `1 ${r.cw} ${r.ch}`', source)
        self.assertIn('...rects, RADIUS * scale, visible ? 1 : 0, px(alpha), px(scale), w.restore ? 1 : 0, mergeOf(w, el), sizeOf(w, body), fillOf()', source)
        observer = (V / 'resize-state.js').read_text().replace('TOKEN', '"T"').replace('WINDOW_ID', '4')
        script = '''let sample, records=[]; globalThis.setInterval=f=>(sample=f,1); globalThis.clearInterval=()=>{};
let entry=[4,...Array(12).fill(0),12,1,1,1,0,-1,-1,1,300,200,'ffffff'];
globalThis.__ww={geometry:()=>[2.76,1,...entry].join(' '),lastResize:null};
globalThis.__glassDrag=()=>{};globalThis.__glassDragOff=false;
console.log=x=>records.push(JSON.parse(x.slice(2)));
''' + observer + ''';
sample();entry[20]=0;globalThis.__ww.lastResize={id:4};sample();
if(!records[0].active || records[1].active || records[0].epoch===records[1].epoch) process.exit(1);
'''
        subprocess.run(['node', '-e', script], check=True)


if __name__ == '__main__':
    unittest.main()
