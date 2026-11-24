#!/usr/bin/env python3
"""rm-drive.py APP [SETTLE_S]: (comp container, as u) drive the focused app through the measurement phases with wtype
(a virtual keyboard on sway) and write the phase boundaries (wall-clock ms) to /tmp/run/phases.json.
  idle 10 s | typing: 60 letters, 150-300 ms apart (seeded) | scroll: Firefox F8 (page.js: 12 px/frame for 10 s),
  Kate/Dolphin: Down held 8 s (sway repeat 60/s: 60 lines/items per s; Page_Down hit the end of the file within 1 s)"""
import json, os, random, subprocess, sys, time
app = sys.argv[1]; settle = float(sys.argv[2]) if len(sys.argv) > 2 else 20
env = dict(os.environ, WAYLAND_DISPLAY='wayland-1')
ph = {}
now = lambda: time.time() * 1000
# Each wtype run is a new virtual keyboard with a new keymap, and the app drops the first key after a keymap change
# (measured: `wtype hello` typed "ello"), so every run starts with a throw-away Shift_L tap.
wt = lambda *a: subprocess.run(['wtype', '-k', 'Shift_L', '-s', '150', *a], env=env, check=True)
time.sleep(settle)
ph['idle'] = [now()]; time.sleep(10); ph['idle'].append(now())
rnd = random.Random(1)
seq = []
for _ in range(60):
    seq += [rnd.choice('abcdefghijklmnopqrstuvwxyz'), '-s', str(rnd.randint(150, 300))]
ph['typing'] = [now()]; wt(*seq); ph['typing'].append(now())
time.sleep(1.5)
if app == 'firefox':
    ph['scroll'] = [now()]; wt('-k', 'F8'); time.sleep(10); ph['scroll'].append(now()); wt('-k', 'F9')
else:
    ph['scroll'] = [now()]; wt('-P', 'Down', '-s', '8000', '-p', 'Down'); ph['scroll'].append(now())
time.sleep(1)
json.dump(ph, open('/tmp/run/phases.json', 'w'))
print(json.dumps({k: round((v[1] - v[0]) / 1000, 2) for k, v in ph.items()}))
