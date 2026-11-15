#!/usr/bin/env python3
"""Device-free execution of launch JS and Chrome ownership/cleanup shell paths."""
import json
import os
from pathlib import Path
import subprocess
import shlex
import unittest
import tempfile

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
CHROME=com.android.chrome CHROME_OWNED=0 SERVER_OWNED=0 FORWARD='' PAGE=''
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
        self.assertIn('CHROME_OWNED=0 SERVER_OWNED=0', TITLE)


class Delivery(unittest.TestCase):
    def test_phone_namespace_and_bounded_owned_server(self):
        server = (VERIFY / 'titlebar-server.py').read_text()
        self.assertNotIn('"$A" reverse', TITLE)
        self.assertNotIn('python3 -m http.server', TITLE)
        self.assertIn('ww_us "mktemp -d /tmp/titlebar-$TOKEN.XXXXXX"', TITLE)
        self.assertIn("setsid -f timeout 245 python3", TITLE)
        self.assertIn("HTTPServer(('127.0.0.1', 0)", server)
        self.assertIn('time.monotonic() + 240', server)
        self.assertIn("(root / 'stop').exists()", server)
        self.assertNotIn('pkill -', TITLE)

    def test_owned_server_and_forward_cleanup_once(self):
        functions = TITLE[TITLE.index('wwc_extra()'):TITLE.index('chrome_claim()')]
        with tempfile.TemporaryDirectory() as tmp:
            r = bash("""
set -u
CHROME_OWNED=0 SERVER_OWNED=1 FORWARD=12345 PAGE=/tmp/owned OUT="$TEST_OUT"
A=adb_stub
adb_stub() { echo "ADB $*" >> "$TEST_OUT/adb.log"; }
ww_us() { echo "PHONE $*" >&2; }
""" + functions + '\nwwc_extra; wwc_extra', TEST_OUT=tmp)
            self.assertEqual(Path(tmp, 'adb.log').read_text().splitlines(), ['ADB forward --remove tcp:12345'])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stderr.count('PHONE '), 1)
        self.assertIn("touch '/tmp/owned/stop'", r.stderr)
        self.assertIn("if [ -f '/tmp/owned/done' ]", r.stderr)

    def test_chrome_socket_and_ordered_preconditions(self):
        self.assertIn('forward tcp:0 localabstract:chrome_devtools_remote', TITLE)
        self.assertIn('cdp_warm_run "$FORWARD"', TITLE)
        self.assertIn('chrome_cdp eval "$URL"', TITLE)
        self.assertLess(TITLE.index('require_page load\nuntil_ 8 laid'), TITLE.index('sh_ "input tap'))
        self.assertLess(TITLE.index('require_page enter\nuntil_'), TITLE.index('until_ 4 hid'))
        self.assertLess(TITLE.index('require_page exit'), TITLE.index('until_ 4 laid'))

    def test_load_gate_rejects_error_missing_and_nonboolean_results(self):
        functions = TITLE[TITLE.index('page_ready()'):TITLE.index('require_page()')]
        with tempfile.TemporaryDirectory() as tmp:
            for result, expected in [('no page chrome-error://chromewebdata/', 1),
                                     ('{"ok":false,"error":"fixture missing"}', 1),
                                     ('{"ok":"true"}', 1), ('{"ok":true}', 0)]:
                r = bash('OUT="$TEST_OUT"; URL=http://test; TOKEN=owned; '
                         'chrome_cdp() { printf "%s" "$RESULT"; };\n' + functions +
                         '\npage_ready load', TEST_OUT=tmp, RESULT=result)
                self.assertEqual(r.returncode, expected, r.stderr)

    def test_document_states_and_real_fullscreen(self):
        html = (VERIFY / 'titlebar-page.html').read_text()
        script = html.split('<script>')[1].split('</script>')[0]
        js = """
const assert=require('node:assert/strict');
const events={}; let reject=false;
global.location={pathname:'/owned/tb.html',href:'http://127.0.0.1:1/owned/tb.html'};
global.window=global;
global.document={readyState:'loading',visibilityState:'visible',fullscreenElement:null,
 body:{}, addEventListener:(k,f)=>events[k]=f,
 documentElement:{requestFullscreen:async()=>{if(reject)throw Error('denied')}},
 exitFullscreen:async()=>{}};
""" + script + """
(async()=>{
 assert.equal(tbProbe('load','owned').ok,false);
 document.readyState='complete';
 assert.equal(tbProbe('load','wrong').ok,false);
 assert.equal(tbProbe('load','owned').ok,true);
 document.visibilityState='hidden'; assert.equal(tbProbe('load','owned').ok,false);
 document.visibilityState='visible';
 await document.body.onclick();
 assert.equal(tbProbe('enter','owned').ok,false); // resolved promise is NOT fullscreen
 document.fullscreenElement={}; events.fullscreenchange();
 assert.equal(tbProbe('enter','owned').ok,true);
 await document.body.onclick();
 assert.equal(tbProbe('exit','owned').ok,false); // promise alone is NOT exit
 document.fullscreenElement=null; events.fullscreenchange();
 assert.equal(tbProbe('exit','owned').ok,true);
 reject=true; await document.body.onclick();
 assert.equal(tbProbe('enter','owned').outcome,'rejected');
 assert.equal(tbProbe('enter','owned').ok,false);
 events.fullscreenerror(); assert.equal(tbProbe('enter','owned').error,'fullscreenerror');
 assert.equal(tbProbe('enter','owned').ok,false);
})().catch(e=>{console.error(e);process.exitCode=1});
"""
        r = subprocess.run(['node', '-e', js], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)


if __name__ == '__main__':
    unittest.main()
