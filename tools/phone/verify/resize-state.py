#!/usr/bin/env python3
"""Validate a diagnostic replay, never the timed gesture. Missing evidence fails closed."""
import json
import re
import sys


def validate(text, token, wid, round_, pause):
    def reject(why):
        raise ValueError(why)
    stamps = re.findall(r'^WWR_(BEGIN|END) (\d+)$', text, re.M)
    if len(stamps) != 2 or [s[0] for s in stamps] != ['BEGIN', 'END']:
        reject('missing device capture timestamps')
    begin, end = [int(s[1]) for s in stamps]
    if end < begin:
        reject('capture clock moved backwards')
    states = []
    for line in text.splitlines():
        if token + ' ' not in line:
            continue
        try:
            states.append(json.loads(line.split(token + ' ', 1)[1]))
        except (ValueError, IndexError):
            continue
    before = [s for s in states if s['at'] <= begin]
    after = [s for s in states if s['at'] >= end]
    if not before or not after:
        reject('capture not bracketed by page state')
    a, b = max(before, key=lambda s: s['at']), min(after, key=lambda s: s['at'])
    span = [s for s in states if a['at'] <= s['at'] <= b['at']]
    if begin - a['at'] > 250 or b['at'] - end > 250:
        reject('stale page state')
    span.sort(key=lambda s: s['at'])
    if any(y['at'] - x['at'] > 250 for x, y in zip(span, span[1:])):
        reject('gap in resize observation')
    if any(not s['active'] or s['epoch'] != a['epoch'] for s in span):
        reject('outside one confirmed resize')
    if any(s['off'] is not (not pause) for s in span):
        reject('wrong glass override')
    props = re.findall(r'^WWR_PROP (.*)$', text, re.M)
    if props != [str(int(round_)), str(int(round_))]:
        reject('wrong corner property')
    sf = text.split('WWR_SF_BEGIN\n', 1)[-1].split('WWR_SF_END', 1)[0]
    blocks = re.findall(r'^  Layer \[\d+\] powos-ww-' + str(wid) + r'#[^\n]*\n(.*?)(?=^  Layer |\Z)', sf, re.M | re.S)
    if not blocks:
        reject('missing exact window container')
    radii = [float(v) for block in blocks for v in re.findall(r'cornerRadius=<\s*([0-9.]+)', block)]
    # SF omits the radius line for zero. Require the container, not a similarly named buffer/mirror.
    radius = max(radii, default=0.0)
    if (radius > 0) != round_:
        reject('applied radius differs from requested arm')
    blur = bool(re.search(r'blurRegions.size\(\)=[1-9]', sf))
    if pause and blur:
        reject('blur remains while pause requested')
    return f'VALID diagnostic only: window={wid} round={int(round_)} pause={int(pause)} radius={radius} blur={int(blur)} capture={begin}..{end}'


if __name__ == '__main__':
    try:
        print(validate(open(sys.argv[1]).read(), sys.argv[2], int(sys.argv[3]), bool(int(sys.argv[4])), bool(int(sys.argv[5]))))
    except (ValueError, KeyError, IndexError) as e:
        print(f'INCONCLUSIVE diagnostic: {e}')
        sys.exit(1)
