#!/usr/bin/env python3
"""Packs tools/snapshot-prepare.sh for the snapshot machine's kernel command line (build-snapshot.sh): comments and
blank lines dropped, MASK="<units>" (machine.json's systemd.mask= list) prepended, gzip -9, base64.

    pack-prepare.py snapshot-prepare.sh "<unit> <unit> ..."
"""
import base64, gzip, sys

lines = [l for l in open(sys.argv[1]).read().splitlines() if l.strip() and not l.lstrip().startswith("#")]
body = "\n".join([f'MASK="{sys.argv[2]}"'] + lines) + "\n"
print(base64.b64encode(gzip.compress(body.encode(), 9)).decode())
