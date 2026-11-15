#!/usr/bin/env python3
"""Source-tree layout budgets; canonical browser preview remains the visual gate."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
JAR = ROOT / 'targets/android/app/owl/build/cli/owl.jar'
JAVA = os.environ.get('JAVA') or shutil.which('java')
EXAMPLES = ROOT / 'targets/android/app/app/src/main/assets/widgets/examples'
DATA = ROOT / 'shell/dev/preview/data'
SIZES = [(182, 128), (245, 128), (182, 196), (245, 196), (182, 264),
         (245, 264), (391, 259), (523, 259), (391, 392), (523, 392),
         (391, 526), (523, 526)]


def nodes(node):
    yield node
    for child in node.get('c', []):
        yield from nodes(child)


def unavailable_reason():
    if not JAR.exists():
        return f'cached OWL CLI missing: {JAR}'
    if not JAVA:
        return 'no Java executable found; set JAVA to a usable JVM executable'
    try:
        probe = subprocess.run([JAVA, '-version'], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired) as error:
        return f'Java runtime unavailable ({JAVA}): {error}; set JAVA to a usable JVM executable'
    if probe.returncode:
        detail = (probe.stderr or probe.stdout).strip().splitlines()
        return f'Java runtime unavailable ({JAVA}): {detail[0] if detail else probe.returncode}; set JAVA to a usable JVM executable'
    return ''


UNAVAILABLE = unavailable_reason()


@unittest.skipIf(UNAVAILABLE, UNAVAILABLE)
class ResponsiveFit(unittest.TestCase):
    def trees(self, name):
        variants = [dict(id=str(i), cols=3, rows=3, w=w, h=h)
                    for i, (w, h) in enumerate(SIZES)]
        result = subprocess.run(
            [JAVA, '-jar', str(JAR), 'trees', str(EXAMPLES / f'{name.split("~")[0]}.owl'),
             '--variants', '/dev/stdin', '--data', str(DATA / f'{name}.json')],
            input=json.dumps(variants), text=True, capture_output=True, check=True)
        trees = json.loads(result.stdout)
        self.assertEqual(trees['errors'], [])
        return trees

    def test_weather_and_system_line_widths(self):
        for name in ['50-weather', '50-weather~extreme', '80-system-info']:
            trees = self.trees(name)
            for i, (w, _) in enumerate(SIZES):
                for node in nodes(trees[str(i)]):
                    if node['k'] == 'Text':
                        p = node['p']
                        self.assertLessEqual(len(p['text']) * p['fontSize'] * .62, w - 24,
                                             (name, i, p))

    def test_media_keeps_metadata_and_controls(self):
        for name in ['97-now-playing', '97-now-playing~broken-art']:
            trees = self.trees(name)
            for i, (w, _) in enumerate(SIZES):
                ns = list(nodes(trees[str(i)]))
                texts = [n['p'] for n in ns if n['k'] == 'Text']
                self.assertTrue(any(p.get('text') == 'Weightless' for p in texts))
                self.assertTrue(any(p.get('text') == 'Marconi Union · Weightless' for p in texts))
                self.assertTrue(any(p.get('text') == '3:34' for p in texts))
                self.assertTrue(any(p.get('text') == '8:00' for p in texts))
                controls = [n for n in ns if n['k'] == 'Box' and 'onTap' in n.get('h', [])]
                self.assertEqual(len(controls), 3)
                self.assertTrue(all(n['p']['size'] >= 24 for n in controls))
                for p in texts:
                    if p.get('text') == 'Weightless':
                        self.assertLessEqual(len(p['text']) * p['fontSize'] * .62, w - 24)


if __name__ == '__main__':
    unittest.main()
