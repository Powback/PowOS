#!/usr/bin/env python3
"""Device-free execution of launch JS and Chrome ownership/cleanup shell paths."""
import json
import os
from pathlib import Path
import subprocess
import shlex
import unittest

ROOT = Path(__file__).resolve().parents[2]
VERIFY = ROOT / 'tools/phone/verify'
TITLE = (VERIFY / 'titlebar-autohide.sh').read_text()


def bash(code, **env):
    return subprocess.run(['bash', '-c', code], text=True, capture_output=True,
                          env={**os.environ, **env})


class Launch(unittest.TestCase):
    def launch(self, key, apps, reject=False, live=True):
        # ev executes the actual generated expression in Node, not a canned answer.
        js = """
const m={apps:{value:JSON.parse(process.env.APPS)},launch:async k=>{
 console.error('PAGE '+k); if(process.env.REJECT==='1')throw Error('rejected');
}};
global.importShim=async p=>{if(p!=='./state.ts')throw Error(p);return m};
let text='';process.stdin.on('data',c=>text+=c);
process.stdin.on('end',async()=>{try{console.log(await eval(text))}catch(e){console.error(e);process.exitCode=1}});
"""
        code = f'''
. {json.dumps(str(VERIFY / 'ww-lib.sh'))}
ev() {{ printf '%s' "$1" | node -e {shlex.quote(js)}; }}
hcall() {{ echo "BRIDGE $*" >&2; echo ok; }}
wwids() {{ echo "IDS $1" >&2; [ "$SEEN" = 0 ] || echo w7; }}
# sleep runs in the parent; wwids command substitutions do not retain shell writes.
SEEN=0
sleep() {{ SEEN=1; }}
wwel() {{ echo "LIVE $*" >&2; echo "$LIVE"; }}
ww_open {shlex.quote(key)} 2
'''
        return bash(code, APPS=json.dumps([{'key': k} for k in apps]),
                    REJECT=str(int(reject)), LIVE='live' if live else 'placeholder')

    def test_package_resolution_and_page_launch(self):
        r = self.launch('a:com.android.chrome', ['a:com.android.chrome.beta/Main', 'a:com.android.chrome/Main'])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(r.stdout.strip(), 'w7')
        self.assertIn('PAGE a:com.android.chrome/Main', r.stderr)
        self.assertIn('IDS a:com.android.chrome/Main', r.stderr)
        self.assertNotIn('BRIDGE', r.stderr)
        self.assertIn('.webwindow-body.live', r.stderr)

    def test_full_key_is_exact(self):
        r = self.launch('a:pkg/Second', ['a:pkg/First', 'a:pkg/Second'])
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn('PAGE a:pkg/Second', r.stderr)

    def test_absent_component_or_package_fails_without_launch(self):
        for key in ['a:pkg', 'a:pkg/Missing']:
            r = self.launch(key, ['a:pkg.other/Main'])
            self.assertEqual(r.returncode, 1)
            self.assertIn('ERR app absent', r.stdout)
            self.assertNotIn('PAGE', r.stderr)
            self.assertNotIn('BRIDGE', r.stderr)

    def test_rejected_launch_fails_explicitly(self):
        r = self.launch('a:pkg', ['a:pkg/Main'], reject=True)
        self.assertEqual(r.returncode, 1)
        self.assertIn('ERR Error: rejected', r.stdout)
        self.assertNotIn('LIVE', r.stderr)

    def test_placeholder_does_not_pass(self):
        r = self.launch('a:pkg', ['a:pkg/Main'], live=False)
        self.assertEqual(r.returncode, 1)
        self.assertIn('placeholder', r.stdout)

    def test_linux_keeps_bridge_path(self):
        r = self.launch('l:org.kde.kate', [])
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("BRIDGE apps.launch ['l:org.kde.kate']", r.stderr)
        self.assertNotIn('PAGE', r.stderr)
        self.assertIn('.webwindow-body.live', r.stderr)


class Ownership(unittest.TestCase):
    def cleanup(self, mode, claim=True):
        functions = TITLE[TITLE.index('wwc_extra()'):TITLE.index('until_()')]
        code = '''
set -uo pipefail
CHROME=com.android.chrome CHROME_OWNED=0 REVERSE_OWNED=0 SRV='' PAGE='' PORT=8765
pidof() {
 case "$MODE" in
 stopped) return 1 ;; running) echo 123; return 0 ;;
 diagnostic) echo 'pidof: permission denied'; return 1 ;;
 broken) return 127 ;; esac
}
sh_() {
 case "$1" in
 'am force-stop '*) echo STOP >&2 ;;
 *) [ "$MODE" != transport ] || return 1
    if [ "$MODE" = truncated ]; then echo stopped; return 1; fi
    eval "$1" ;;
 esac
}
wwc_skip() { echo "SKIP $*"; wwc_extra; exit 3; }
''' + functions + '\ntrap wwc_extra EXIT\n'
        if claim:
            code += 'chrome_claim\necho LAUNCH\n'
        code += 'wwc_extra\nwwc_extra\n'
        return bash(code, MODE=mode)

    def test_preexisting_chrome_never_stopped(self):
        r = self.cleanup('running')
        self.assertEqual(r.returncode, 3)
        self.assertNotIn('STOP', r.stderr)
        self.assertNotIn('LAUNCH', r.stdout)

    def test_unknown_chrome_never_stopped(self):
        for mode in ['transport', 'truncated', 'diagnostic', 'broken']:
            r = self.cleanup(mode)
            self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
            self.assertIn('unknown', r.stdout)
            self.assertNotIn('STOP', r.stderr)
            self.assertNotIn('LAUNCH', r.stdout)

    def test_owned_cleanup_once_even_on_exit(self):
        r = self.cleanup('stopped')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stderr.splitlines(), ['STOP'])
        self.assertIn('LAUNCH', r.stdout)

    def test_exit_before_claim_cannot_stop_chrome(self):
        r = self.cleanup('stopped', claim=False)
        self.assertEqual(r.returncode, 0)
        self.assertNotIn('STOP', r.stderr)

    def test_claim_precedes_launch_in_parent(self):
        self.assertIn('chrome_claim   # parent shell', TITLE)
        self.assertLess(TITLE.index('\nchrome_claim   #'), TITLE.index('\nWID=$(ww_open'))
        self.assertIn('CHROME_OWNED=0 REVERSE_OWNED=0', TITLE)


if __name__ == '__main__':
    unittest.main()
