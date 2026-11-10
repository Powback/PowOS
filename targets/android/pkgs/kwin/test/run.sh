#!/usr/bin/env bash
# kwin anland unit tests in a throwaway gcc container, against the patched tree src-tree.sh builds (no Qt, no KWin
# build): reconnect-test.c = 0059's non-blocking try_exit_fallback(); xnativesnap-test.cpp = 0065's 1-px snap;
# task-policy-test.cpp = 0066's prompt-over-game and restore-watch decisions, 0068's own-frame vs borderless one;
# fullscreenleave-test.cpp = 0069 + 0072: the stale-size leave refusal and its grace after a task resize.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
tree=$("$here/src-tree.sh" "${KWIN_TREE:-$here/out/src-tree}" | grep '^/' | head -1 | cut -d' ' -f1)
docker run --rm -v "$here/test:/test:ro" -v "$tree/src/backends/anland:/anland:ro" -v "$tree/src/utils:/utils:ro" -w /tmp gcc:14 sh -c \
  'gcc -std=gnu11 -Wall -Wextra -I/anland -o r /test/reconnect-test.c /anland/display_producer.c /anland/socket_utils.c -lpthread && ./r && g++ -std=c++17 -Wall -Wextra -Werror -I/utils -o s /test/xnativesnap-test.cpp && ./s && g++ -std=c++17 -Wall -Wextra -Werror -I/anland -o t /test/task-policy-test.cpp && ./t && g++ -std=c++17 -Wall -Wextra -Werror -I/utils -o f /test/fullscreenleave-test.cpp && ./f'
