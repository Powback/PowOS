#!/bin/bash
# lint fixture: the fixed forms stay quiet
prog=$(cat <<'PY'
import json, sys
p = json.load(sys.stdin)
print(f"{p['n']} headers")
PY
)
echo '{"n": 2}' | python3 -c "$prog"
echo '{"n": 2}' | python3 -c 'import json, sys; p = json.load(sys.stdin); print(f"{p}\n", "{\"a\"}")'
python3 -c 'print('\''it'\'')'
sh_ "python3 -c 'print(\"remote, left alone\")'"
python3 -c 'if True print(1)'  # lint-ok: fixture escape
