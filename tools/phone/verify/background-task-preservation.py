#!/usr/bin/env python3
"""Compare task identity sets; only disappearance of an already-empty exact lock activity is lifecycle."""
import pathlib
import re
import sys

LOCK = 'com.powos.app/dev.omalauncher.shell.PowosLockActivity'
COMPANION = 'com.powos.verifybackground/com.powos.verifybackground.StartActivity'


def records(text):
    result = {}
    for block in re.split(r'(?=^\s*\* Recent #\d+: Task\{)', text, flags=re.M)[1:]:
        block = block.split('Visible recent tasks', 1)[0]
        task = re.search(r'Task\{\S+ #(\d+) ', block)
        component = re.search(r'^\s*mActivityComponent=(\S+)\s*$', block, re.M)
        if not task:
            raise ValueError('task header has no identity')
        name = component.group(1) if component else ''
        if '/.' in name:
            package, activity = name.split('/', 1)
            name = package + '/' + package + activity
        result[task.group(1)] = (name, bool(re.search(r'^\s*Activities=\[\]\s*$', block, re.M)))
    if not result:
        raise ValueError('no task records: cannot prove preservation')
    return result


def compare(before, after):
    notes, failures = [], []
    for task in sorted(before.keys() | after.keys(), key=int):
        old, new = before.get(task), after.get(task)
        if old == new or (old and new and old[0] == new[0]):
            continue
        if old == (LOCK, True) and new is None:
            notes.append(f'lock lifecycle: already-empty {LOCK} task {task} removed; no user activity lost')
        elif (old or new)[0] == COMPANION and not (old and new):
            failures.append(f'companion activity task {task} did not finish cleanly')
        else:
            failures.append(f'task {task} identity changed: {old} -> {new}')
    return notes, failures


if __name__ == '__main__':
    try:
        notes, failures = compare(*(records(pathlib.Path(p).read_text()) for p in sys.argv[1:3]))
        for note in notes:
            print('NOTE: ' + note)
        for failure in failures:
            print('FAIL: ' + failure)
        sys.exit(bool(failures))
    except (ValueError, OSError) as error:
        print('FAIL: task preservation evidence invalid: ' + str(error))
        sys.exit(1)
