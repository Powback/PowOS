#!/usr/bin/env python3
"""Validate a diagnostic replay, never the timed gesture. Missing evidence fails closed."""
import json
import re
import sys


def validate(text, token, wid, round_, pause):
    def reject(why):
        raise ValueError(why)
    markers = re.findall(r'^WWR_(?:BEGIN|END|PROP|SF_BEGIN|SF_END)\b[^\n]*$', text, re.M)
    if (len(markers) != 6 or not re.fullmatch(r'WWR_BEGIN [0-9]+', markers[0])
            or not markers[1].startswith('WWR_PROP ') or markers[2] != 'WWR_SF_BEGIN'
            or markers[3] != 'WWR_SF_END' or not markers[4].startswith('WWR_PROP ')
            or not re.fullmatch(r'WWR_END [0-9]+', markers[5])):
        reject('invalid capture delimiters or order')
    stamps = re.findall(r'^WWR_(BEGIN|END) ([0-9]+)$', text, re.M)
    begin, end = [int(s[1]) for s in stamps]
    if end < begin:
        reject('capture clock moved backwards')
    states = []
    for line in text.splitlines():
        if token + ' ' not in line:
            continue
        try:
            state = json.loads(line.split(token + ' ', 1)[1])
        except ValueError:
            reject('invalid page state JSON')
        if (type(state) is not dict or set(state) != {'at', 'active', 'epoch', 'off'}
                or type(state['at']) is not int or state['at'] < 0
                or type(state['epoch']) is not int or state['epoch'] < 0
                or type(state['active']) is not bool or type(state['off']) is not bool):
            reject('invalid page state schema')
        if states and state['at'] < states[-1]['at']:
            reject('page clock moved backwards')
        states.append(state)
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
    if text.count('WWR_SF_BEGIN\n') != 1 or text.count('WWR_SF_END\n') != 1:
        reject('incomplete SF capture')
    sf = text.split('WWR_SF_BEGIN\n', 1)[1].split('WWR_SF_END', 1)[0]
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
