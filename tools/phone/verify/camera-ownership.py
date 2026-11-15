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


def empty_camera_clients(text):
    """Only the completed INITIAL service-global section is client evidence.

    Provider static metadata can time out much later. Keep that raw diagnostic,
    but don't confuse it with an incomplete initial active-client snapshot.
    """
    lines = text.splitlines()
    while lines and not lines[0].strip():
        lines.pop(0)  # dumpsys may prefix its first section with blank lines
    start = '== Service global info: =='
    boundary = '== Camera service events log (most recent at top): =='
    if not lines or lines[0] != start:
        raise ValueError('camera global-info start missing/unknown; protected')
    end = next((i for i in range(1, len(lines)) if lines[i].startswith('== ')), None)
    if end is None or lines[end] != boundary:
        raise ValueError('camera global-info boundary incomplete/unknown; protected')
    initial = '\n'.join(lines[:end])
    if re.search(r'error|permission|deni(?:ed|al)|SecurityException|timeout|timed out|'
                 r'deadlock|no[ -]+(?:camera[ -]+)?HAL|Can.t find service|warning', initial, re.I):
        raise ValueError('camera initial client snapshot reported an error; protected')
    headers = [i for i in range(1, end) if lines[i] == 'Active Camera Clients:']
    if len(headers) != 1:
        raise ValueError('camera client header missing/ambiguous; protected')
    # No arbitrary text or second header between the empty list and the next
    # section: the allowed-users line proves this is a completed global snapshot.
    tail = '\n'.join(lines[headers[0]:end])
    if not re.fullmatch(r'Active Camera Clients:\n\[\]\nAllowed user IDs: [0-9]+(?:,? [0-9]+)*\n*', tail):
        raise ValueError('camera clients present/incomplete/ambiguous; protected')


def evidence(directory):
    d = Path(directory)
    texts = {k: (d / (k + '.txt')).read_text() for k in
             ('tasks', 'activities', 'recents', 'windows', 'clients', 'process')}
    empty_camera_clients(texts['clients'])
    for k, text in texts.items():
        if k == 'clients':
            continue  # validated through the initial events-log boundary above
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
