#!/bin/bash
# lint fixture: each python3 -c below is one py-c hit (3)
echo '{"n": 2}' | python3 -c '
import json, sys
p = json.load(sys.stdin)
print(f"{p[\"n\"]} headers")
'
python3 -c 'x = {"a": 1}; print(f"{chr(10).join([\"a\"])}")'
python3 -I -c 'if True print(1)'
