#!/usr/bin/env bash
# Compile and run the KGSL import-check (0010), copy-wait (0011), import-cache (0012) and flip-stats (0013) tests in a throwaway gcc container (no X server, no EGL).
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
docker run --rm -v "$here:/src:ro" -w /tmp gcc:14 sh -c \
  'gcc -std=c11 -Wall -Wextra -Werror -o t /src/test/import-check-test.c && ./t && gcc -std=c11 -Wall -Wextra -Werror -o c /src/test/copy-wait-test.c && ./c && gcc -std=c11 -Wall -Wextra -Werror -o i /src/test/import-cache-test.c && ./i && gcc -std=c11 -Wall -Wextra -Werror -o f /src/test/flip-stats-test.c && ./f'
