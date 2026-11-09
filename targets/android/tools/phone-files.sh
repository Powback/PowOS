#!/bin/sh
# phone-files.sh [install-powos-android.sh] - the phone's own PowOS files (session scripts, shims, play/ launchers) as
# "<mode> <source under targets/android> <destination>" lines, read from install-powos-android.sh's own `install`
# lines, so the image build and the powos-core package (build-powos-core.sh: how those files reach an installed phone
# as a package update, docs/PHONE-UPDATES.md) can never disagree about where a file goes. Only plain
# `install [-D]m MODE "$P/<session|shims|play>/<file>" <dest>` lines count; anything else stays the image's.
f=${1:-$(dirname "$0")/../install-powos-android.sh}
sed -En 's@^install -D?m ([0-7]+) "\$P/((session|shims|play)/[^"]+)" ([^ ]+).*@\1 \2 \4@p' "$f"
