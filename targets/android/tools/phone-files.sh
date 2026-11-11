#!/bin/sh
# phone-files.sh [install-powos-android.sh] - the phone's own PowOS files (session scripts, shims, play/ launchers) as
# "<mode> <source under targets/android> <destination>" lines, read from install-powos-android.sh's own `install`
# lines, so the image build and the powos-core package (build-powos-core.sh: how those files reach an installed phone
# as a package update, docs/PHONE-UPDATES.md) can never disagree about where a file goes. Only plain
# `install [-D]m MODE "$P/<session|shims|play>/<file>" <dest>` lines count, and `"$P/current/src/<config|units>/<file>"`
# ones (repo files outside targets/android, e.g. the Claude endpoint's profile.d and its unit: mapped as ../../<path>,
# so the 11-10 fix reached installed phones and not only fresh base installs); anything else stays the image's.
f=${1:-$(dirname "$0")/../install-powos-android.sh}
sed -En -e 's@^install -D?m ([0-7]+) "\$P/((session|shims|play)/[^"]+)" ([^ ]+).*@\1 \2 \4@p' \
  -e 's@^install -D?m ([0-7]+) "\$P/current/src/((config|units)/[^"]+)" ([^ ]+).*@\1 ../../\2 \4@p' "$f"
