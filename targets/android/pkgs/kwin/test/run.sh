#!/usr/bin/env bash
# kwin anland unit tests in a throwaway gcc container, against the patched tree src-tree.sh builds (no Qt, no KWin
# build): reconnect-test.c = 0059's non-blocking try_exit_fallback().
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
tree=$("$here/src-tree.sh" "${KWIN_TREE:-$here/out/src-tree}" | grep '^/' | head -1 | cut -d' ' -f1)
docker run --rm -v "$here/test:/test:ro" -v "$tree/src/backends/anland:/anland:ro" -w /tmp gcc:14 sh -c \
  'gcc -std=gnu11 -Wall -Wextra -I/anland -o r /test/reconnect-test.c /anland/display_producer.c /anland/socket_utils.c -lpthread && ./r'
