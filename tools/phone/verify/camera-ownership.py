#!/usr/bin/env python3
"""Fail-closed policy for inner-rotation-back's saved Android evidence (no device IO).

A process is NOT evidence of an active camera. We nevertheless decline cached-only
cases: OEM camera-client/task dumps have not been validated as an absence proof.
"""
import re
import sys
from pathlib import Path

PKG = 'com.oplus.camera'


def tasks(text):
    """am stack list: retain root identity; stack remove takes a ROOT, not task id."""
    if re.search(r'Permission Denial|SecurityException|Error:|DUMP TIMEOUT|Can.t find service', text, re.I):
        raise ValueError('task probe reported an error')
    result = {}
    root = None
    roots = set()
    for line in text.splitlines():
        m = re.match(r'\s*(?:RootTask|Stack) id=(\d+)\b', line)
        if m:
            root = m[1]
            roots.add(root)
        elif 'taskId=' in line:
            m = re.match(r'\s*taskId=(\d+): (\S+).*\bvisible=(true|false)\b', line)
            if not m or root is None or m[1] in result:
                raise ValueError('unknown task-list format')
            result[m[1]] = (m[2], root)
    if not roots or not result:
        raise ValueError('empty/unknown task inventory')
    return result, roots


def evidence(directory):
    d = Path(directory)
    texts = {k: (d / (k + '.txt')).read_text() for k in
             ('tasks', 'activities', 'recents', 'windows', 'clients', 'process')}
    for k, text in texts.items():
        if re.search(r'Permission Denial|SecurityException|Error:|DUMP TIMEOUT|Can.t find service', text, re.I):
            raise ValueError(k + ' probe reported an error')
    inventory, roots = tasks(texts['tasks'])
    for key, marker in [('activities', 'ACTIVITY MANAGER ACTIVITIES'),
                        ('recents', 'ACTIVITY MANAGER RECENT TASKS'),
                        ('windows', 'WINDOW MANAGER WINDOWS')]:
        if marker not in texts[key]:
            raise ValueError(key + ' dump unrecognized')
    return texts, inventory, roots


def guard(directory):
    text, _, _ = evidence(directory)
    if any(PKG in text[k] for k in ('tasks', 'activities', 'recents', 'windows')):
        raise ValueError('preexisting camera task/window/reference protected')
    # Require an explicit empty active-client list, not absence of the package
    # name in a potentially partial/unsupported dump. Any camera client is protected.
    if not re.search(r'Active Camera Clients:\s*\[\s*\]', text['clients']):
        raise ValueError('camera clients present or unknown; protected')
    if text['process'].strip() != 'ABSENT':
        raise ValueError('camera process present or unknown (may be cached, NOT proof of active use); protected')
    print('camera absent in recognized snapshots; no process/client to reuse')


def owned(before, after):
    _, old, _ = evidence(before)
    now, _ = tasks(Path(after).read_text())
    candidates = [i for i, (component, _) in now.items()
                  if component.startswith(PKG + '/') and i not in old]
    if len(candidates) != 1:
        raise ValueError('new camera task identity absent/ambiguous')
    return candidates[0]


def cleanup(before, after, task):
    _, old, oldroots = evidence(before)
    now, _ = tasks(Path(after).read_text())
    if task in old or task not in now or not now[task][0].startswith(PKG + '/'):
        raise ValueError('cleanup identity not owned')
    root = now[task][1]
    # am stack remove removes a whole root. Only use it for a NEW root whose
    # sole child is this exact owned task; never a shared/preexisting root.
    if root in oldroots or [i for i in now if now[i][1] == root] != [task]:
        raise ValueError('cleanup root preexisting/shared; leaving task untouched')
    print(root)


def main():
    try:
        mode, *args = sys.argv[1:]
        if mode == 'guard':
            guard(*args)
        elif mode == 'owned':
            print(owned(*args))
        elif mode == 'cleanup':
            cleanup(*args)
        else:
            raise ValueError('unknown policy operation')
    except (ValueError, OSError) as e:
        print(str(e), file=sys.stderr)
        return 3
    return 0


if __name__ == '__main__':
    sys.exit(main())
