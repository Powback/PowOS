#!/bin/bash
# The composer's headless render check (docs/COMPOSER.md): the Hue room-status widget composed from plain words (the
# word match, no AI), built (apps/build.sh: the shared apps/composed module is copied in, not rebuilt) and rendered by
# the widget preview at every size from its minSize to 4x4, on both screens, in two themes, against App API's mocked
# answers (shell/dev/preview/data/local.hue-rooms*.json: live rooms, Hue not linked, and the last rooms greyed).
# Nothing reaches a Hue bridge or the phone. Exit 1 on a fit problem; the contact sheets land in DIR/preview.
#   tools/compose/render-check.sh [DIR]        default ~/.cache/powos-compose-check/hue-rooms
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
D=${1:-$HOME/.cache/powos-compose-check/hue-rooms}
cd "$ROOT"
[ -f apps/composed/out/module.wasm ] && [ -f apps/composed/out/.module.sha ] || apps/build.sh composed
rm -rf "$D"
POWOS_COMPOSE_AI=off python3 lib/apps/powos-compose widget "which Hue rooms are on" --no-install --dir "$D"
apps/build.sh "$D"
shell/dev/preview.sh --no-defaults --app "$D" --only '^local\.hue-rooms\.' --out "$D/preview"
