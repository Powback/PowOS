#!/usr/bin/env python3
"""user-tasks.py < `dumpsys activity recents`: print one line per task the switcher-empty check must not run beside.

The refuse-on-user-tasks guard of switcher-empty.sh: an empty switcher can only be shown on a device where nobody has
a task, and the check never closes anything to make one. Every recent task counts as the user's - live or with no
activities left (Termux's backgrounded task on the phone is exactly that) - except PowOS's own (home, lock, shell:
package com.powos.app), the check's companion (com.powos.verifybackground) and Android's boot-time FallbackHome.
Exit 0 with the list (empty = no user tasks); exit 2 when the dump can't be read (no task headers): the caller SKIPs,
since "can't tell" must never read as "nobody's there".
"""
import re
import sys

OWN = ('com.powos.app/', 'com.powos.verifybackground/', 'com.android.settings/.FallbackHome',
       'com.android.settings/com.android.settings.FallbackHome')


def user_tasks(text):
    blocks = re.split(r'(?=^\s*\* Recent #\d+: Task\{)', text, flags=re.M)[1:]
    if not blocks:
        raise ValueError('no task records in the recents dump')
    found = []
    for block in blocks:
        block = block.split('Visible recent tasks', 1)[0]
        head = re.search(r'Task\{\S+ #(\d+) [^}]*\}', block)
        comp = re.search(r'^\s*(?:mActivityComponent|realActivity|origActivity)=(\S+)\s*$', block, re.M)
        name = comp.group(1) if comp else ''
        if not name:
            # No component line: the header's affinity still names the owner; unknown stays the user's.
            aff = re.search(r' (?:A|I)=(?:\d+:)?(\S+?)[ }]', head.group(0)) if head else None
            name = (aff.group(1) if aff else '?') + '/?'
        if name.startswith(OWN):
            continue
        found.append(f"#{head.group(1) if head else '?'} {name}")
    return found


if __name__ == '__main__':
    try:
        print('\n'.join(user_tasks(sys.stdin.read())))
    except ValueError as e:
        print(f'cannot read tasks: {e}', file=sys.stderr)
        sys.exit(2)
