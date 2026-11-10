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


def capture(round_=True, active=True, off=False):
    radius = '    cornerRadius=< 33.15, 33.15 >\n' if round_ else ''
    states = '\n'.join('T ' + json.dumps(dict(at=t, active=active, epoch=1, off=off)) for t in (999, 1050, 1101))
    return ('WWR_BEGIN 1000\nWWR_SF_BEGIN\n'
            '  Layer [11887] powos-ww-4#11887\n    bounds={0,0,100,100}\n' + radius +
            'WWR_SF_END\nWWR_END 1100\n' + states)


class ResizeState(unittest.TestCase):
    def test_round(self):
        self.assertIn('VALID', m.validate(capture(), 'T', 4, True))

    def test_wrong_setting(self):
        with self.assertRaises(ValueError):
            m.validate(capture(off=True), 'T', 4, True)

    def test_outside_drag(self):
        with self.assertRaisesRegex(ValueError, 'outside'):
            m.validate(capture(active=False), 'T', 4, True)

    def test_square_during_drag(self):
        # RJ3 (square corners while resizing) is gone: a drag keeps the window's radius.
        with self.assertRaisesRegex(ValueError, 'radius'):
            m.validate(capture(False), 'T', 4, True)

    def test_no_corner_property_in_probe(self):
        self.assertNotIn('ww_drag_round', (V / 'ww-resize.sh').read_text())

    def test_blur(self):
        with self.assertRaisesRegex(ValueError, 'blur remains'):
            m.validate(capture().replace('bounds=', 'blurRegions.size()=8 bounds='), 'T', 4, True)

    def test_missing_container(self):
        with self.assertRaisesRegex(ValueError, 'container'):
            m.validate(capture().replace('powos-ww-4#', 'powos-ww-4-linux#'), 'T', 4, True)

    def test_regrab(self):
        text = capture().replace('"at": 1101, "active": true, "epoch": 1', '"at": 1101, "active": true, "epoch": 3')
        with self.assertRaisesRegex(ValueError, 'outside'):
            m.validate(text, 'T', 4, True)

    def test_invalid_state_schema(self):
        good = dict(at=999, active=True, epoch=1, off=False)
        invalid = [None, [], 'text', 42, {}, {'at': 999}]
        for field, value in [('at', '999'), ('at', None), ('at', True), ('at', 1.5),
                             ('epoch', '1'), ('epoch', False), ('active', 1), ('off', None)]:
            invalid.append({**good, field: value})
        for value in invalid:
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, 'schema'):
                m.validate(capture() + '\nT ' + json.dumps(value), 'T', 4, True)
        with self.assertRaisesRegex(ValueError, 'JSON'):
            m.validate(capture() + '\nT {broken', 'T', 4, True)

    def test_capture_delimiters(self):
        for text in (capture().replace('WWR_BEGIN 1000', 'WWR_BEGIN "1000"'),
                     capture().replace('WWR_END 1100', 'WWR_END null'),
                     capture().replace('WWR_SF_BEGIN', 'TEMP').replace('WWR_SF_END', 'WWR_SF_BEGIN').replace('TEMP', 'WWR_SF_END'),
                     capture() + '\nWWR_BEGIN invalid',
                     capture().replace('WWR_END 1100', 'WWR_END 900')):
            with self.subTest(text=text), self.assertRaises(ValueError):
                m.validate(text, 'T', 4, True)

    def test_first_match_stops_idle_producer(self):
        # Producer emits once then blocks forever: no later write/SIGPIPE is available to reap it.
        # An owned child execs node, so kill/wait targets the producer itself, not a shell grandchild.
        helper = (V / 'resize-first-match.sh').read_text()
        script = helper + '''
logcat() { exec node -e 'console.log("T_ACTIVE"); setInterval(()=>{},1000)' ; }
resize_first_match T || exit 1
printf 'captured\\n'
'''
        result = subprocess.run(['bash', '-c', script], capture_output=True, text=True, timeout=3)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.endswith('WWR_WATCH matched ' + result.stdout.split('WWR_WATCH matched ')[1].split('\n')[0] + '\ncaptured\n'), result.stdout)

    def test_first_match_failure_is_bounded(self):
        helper = 'WWR_WATCH_S=1\n' + (V / 'resize-first-match.sh').read_text()
        script = helper + '''
logcat() { exec node -e 'setInterval(()=>{},1000)' ; }
resize_first_match T && exit 2
exit 0
'''
        result = subprocess.run(['bash', '-c', script], capture_output=True, text=True, timeout=3)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_inactive_device_capture(self):
        # Exact shape of both real files: only console states, no SF/timestamp markers.
        text = 'home LOG :18 WWR_59_241_37939 {"at":1794346946854,"active":false,"epoch":0,"off":false}'
        with self.assertRaisesRegex(ValueError, 'no active resize observed'):
            m.validate(text, 'WWR_59_241_37939', 59, True)
        with self.assertRaisesRegex(ValueError, 'inspect diagnostic.stderr'):
            m.validate('WWR_ERROR no-confirmed-resize\n' + text, 'WWR_59_241_37939', 59, True)

    def test_short_mode_and_owned_input_guards(self):
        script = (V / 'ww-resize.sh').read_text()
        loop = script[script.index('  for g in $GESTURES; do'):]
        short = loop.index('if [ "$DIAG_ONLY" = 1 ]')
        self.assertLess(short, loop.index('k0=$(klines)'))
        self.assertIn('continue', loop[short:loop.index('k0=$(klines)')])
        self.assertIn('already belongs to user; not moved or resized', script)
        diag = script[script.index('diagnostic() {'):script.index('# record <x1')]
        self.assertEqual(diag.count('hit=$(wwhit'), 2)
        self.assertNotIn('input swipe $x2 $y2 $x1 $y1', diag)
        self.assertIn('2> "$OUT/$tag-diagnostic.stderr"', diag)

    def device_run(self, stream_active, watch_s='8', helper_edit=None):
        """Run diag_device_cmd's exact string through adb-shell -> su -c with stubbed device tools."""
        import os, tempfile
        token = 'WWR_61_76_66555'
        raw = 'home LOG :18 ' + token + ' {{"at":{},"active":{},"epoch":{},"off":false}}'
        with tempfile.TemporaryDirectory() as d:
            b = Path(d, 'bin'); b.mkdir()
            stubs = {
                'su': '[ "$1" = -c ] && exec sh -c "$2"',
                # Calls in order: watcher start, matched, BEGIN, END.
                'date': 'case "$1" in +%s%3N) n=$(cat "$D/n" 2>/dev/null || echo 0); echo $((n + 1)) > "$D/n"; case $n in 0) echo 900 ;; 1) echo 950 ;; 2) echo 1000 ;; *) echo 1100 ;; esac ;; *) exec /bin/date "$@" ;; esac',
                'input': 'exit 0',
                'dumpsys': "printf '  Layer [11887] powos-ww-61#11887\\n    bounds={0,0,100,100}\\n    cornerRadius=< 33.15, 33.15 >\\n'",
                # Without -T 1 a real logcat replays its buffer first (the 11-10 23:11/23:14 failure).
                'logcat': 'case "$*" in *-d*) cat "$D/dump"; exit 0 ;; esac; case "$*" in *"-T 1"*) ;; *) cat "$D/backlog" ;; esac; cat "$D/stream"; exec sleep 30',
            }
            for name, body in stubs.items():
                (b / name).write_text('#!/bin/sh\n' + body + '\n'); (b / name).chmod(0o755)
            Path(d, 'stream').write_text(raw.format(990, 'false', 0) + '\n' + raw.format(995, 'true', 1) + '\n'
                                         + (token + '_ACTIVE\n' if stream_active else ''))
            # Verbatim lines of the real 23:11 capture (ww-resize-1110-2311), replayed as logcat's buffer.
            real = ('home LOG :18 WWR_63_88_83918 {"at":1794348772161,"active":false,"epoch":0,"off":false}\n'
                    'home LOG :18 WWR_63_88_83918 {"at":1794348778204,"active":true,"epoch":1,"off":false}\n'
                    'home LOG :18 WWR_63_88_83918 {"at":1794348781179,"active":false,"epoch":2,"off":false}\n')
            Path(d, 'backlog').write_text(real * 40000)
            Path(d, 'dump').write_text(''.join(raw.format(t, 'true', 1) + '\n' for t in (999, 1050, 1101)))
            fn = (V / 'ww-resize.sh').read_text()
            fn = fn[fn.index('diag_device_cmd() {'):]
            fn = fn[:fn.index('\n}\n') + 3]
            if helper_edit:
                v = Path(d, 'verify'); v.mkdir()
                (v / 'resize-first-match.sh').write_text(helper_edit((V / 'resize-first-match.sh').read_text()))
                fn = fn.replace('$here/resize-first-match.sh', str(v / 'resize-first-match.sh'))
            script = f'here={V}\n' + fn + f'diag_device_cmd {token} 1 2 3 4'
            cmd = subprocess.run(['bash', '-c', script], capture_output=True, text=True, check=True).stdout
            env = dict(os.environ, PATH=f'{b}:' + os.environ['PATH'], D=d, TMPDIR=d, WWR_WATCH_S=watch_s)
            out = subprocess.run(['sh', '-c', cmd], capture_output=True, text=True, env=env, timeout=12)
            return token, out

    def test_device_command_matches_real_line(self):
        token, out = self.device_run(True)
        self.assertEqual(out.stderr, '')
        self.assertNotIn('WWR_ERROR', out.stdout)
        self.assertIn('VALID', m.validate(out.stdout, token, 61, True))

    def test_device_command_no_marker_fails_closed(self):
        token, out = self.device_run(False, '1')
        self.assertRegex(out.stdout, r'WWR_WATCH (deadline|read timed out or ended)')
        with self.assertRaisesRegex(ValueError, 'no confirmed resize'):
            m.validate(out.stdout, token, 61, True)

    def test_device_command_reaches_live_lines_past_backlog(self):
        token, out = self.device_run(True, '2')
        self.assertIn('WWR_WATCH matched', out.stdout)
        self.assertIn('VALID', m.validate(out.stdout, token, 61, True))

    def test_backlog_replay_reproduces_deadline(self):
        # The pre-fix watcher (no -T 1): stuck in the replayed buffer, the marker after it never reached in time.
        token, out = self.device_run(True, '2', lambda h: h.replace('logcat -T 1 ', 'logcat '))
        self.assertIn('WWR_WATCH deadline', out.stdout)
        self.assertNotIn('WWR_WATCH matched', out.stdout)
        with self.assertRaisesRegex(ValueError, 'no confirmed resize'):
            m.validate(out.stdout, token, 61, True)

    def test_helper_embeds_in_single_quotes(self):
        # 74811a87 follow-up: a comment apostrophe ended su -c early (syntax error on the device shell).
        self.assertNotIn("\'", (V / 'resize-first-match.sh').read_text())

    def test_observer_actual_schema(self):
        # Lock this observer to entry()/sizeOf()/geometry(), not an invented export.
        source = (ROOT / 'shell/ui/webwindows.tsx').read_text()
        self.assertIn('return `1 ${r.cw} ${r.ch}`', source)
        self.assertIn('...rects, RADIUS * scale, visible ? 1 : 0, px(alpha), px(scale), w.restore ? 1 : 0, mergeOf(w, el), sizeOf(w, body), fillOf()', source)
        observer = (V / 'resize-state.js').read_text().replace('TOKEN', '"T"').replace('WINDOW_ID', '4')
        script = '''let sample, records=[], markers=[]; globalThis.setInterval=f=>(sample=f,1); globalThis.clearInterval=()=>{};
let entry=[4,...Array(12).fill(0),12,1,1,1,0,-1,-1,1,300,200,'ffffff'];
globalThis.__ww={geometry:()=>[2.76,1,...entry].join(' '),lastResize:null};
globalThis.__glassDrag=()=>{};globalThis.__glassDragOff=false;
console.log=x=>x.endsWith('_ACTIVE')?markers.push(x):records.push(JSON.parse(x.slice(2)));
''' + observer + ''';
sample();entry[20]=0;globalThis.__ww.lastResize={id:4};sample();
if(!records[0].active || records[1].active || records[0].epoch===records[1].epoch || markers.join()!=='T_ACTIVE') process.exit(1);
'''
        subprocess.run(['node', '-e', script], check=True)


if __name__ == '__main__':
    unittest.main()
