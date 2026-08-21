#!/bin/bash
# test-iso-kickstart.sh - the installer ISO must not auto-wipe every disk.
#
# bootc-image-builder's `--type anaconda-iso` generates its OWN kickstart:
#
#     clearpart --all
#     autopart --nohome --type=btrfs
#     reboot --eject
#
# and boots it with inst.ks=hd. `clearpart --all` has no --drives restriction,
# so it erases EVERY ATTACHED DISK with no prompt and no selection. Verified by
# booting a real ISO: it started installing unattended, and the kickstart is
# readable at /osbuild.ks on the media. On a Steam Deck booted with its microSD
# inserted, that takes the card and the games on it — which is exactly what
# happened, and why this test exists.
#
# build-iso.sh therefore mounts build/iso-config/config.toml, whose
# [customizations.installer.kickstart] contents REPLACE those directives. With
# no partitioning directives Anaconda stops at the storage spoke and asks.
#
# These are static checks on the config and the build script, so they run
# anywhere in a second. The empirical check that the directives really do
# disappear is a manifest diff, documented in the build-iso.sh comment.
#
# Usage:  bash test/tier1/test-iso-kickstart.sh

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CFG="$ROOT/build/iso-config/config.toml"
ISO_SH="$ROOT/build/build-iso.sh"

PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1"; FAIL=$((FAIL+1)); [[ -n "${2:-}" ]] && echo "         $2"; }

echo "== installer kickstart config =="

if [[ -f "$CFG" ]]; then
    ok "build/iso-config/config.toml exists"
else
    bad "build/iso-config/config.toml exists" "without it the ISO auto-wipes every disk"
    echo ""; echo "== Results: $PASS passed, $FAIL failed =="; exit 1
fi

grep -q '\[customizations.installer.kickstart\]' "$CFG" \
    && ok "declares [customizations.installer.kickstart]" \
    || bad "declares [customizations.installer.kickstart]"

# The whole point: our kickstart must NOT reintroduce the destructive commands.
for bad_directive in 'clearpart' 'autopart' 'zerombr'; do
    if grep -qE "^[[:space:]]*${bad_directive}\b" "$CFG"; then
        bad "config must not contain an active '$bad_directive' directive" \
            "$(grep -nE "^[[:space:]]*${bad_directive}\b" "$CFG" | head -1)"
    else
        ok "no active '$bad_directive' directive"
    fi
done

# reboot --eject would reboot mid-flow on a machine the user is still driving.
if grep -qE '^[[:space:]]*reboot\b' "$CFG"; then
    bad "config must not force a reboot"
else
    ok "no forced reboot"
fi

echo ""
echo "== build-iso.sh wires the config in =="

grep -q 'iso-config/config.toml:/config.toml' "$ISO_SH" \
    && ok "the anaconda-iso build mounts config.toml" \
    || bad "the anaconda-iso build mounts config.toml" \
           "without the mount the generated kickstart wins and wipes every disk"

# Guard against the mount being added for one image type but not the ISO one.
if awk '/--type anaconda-iso/{found=1} END{exit !found}' "$ISO_SH"; then
    ok "an anaconda-iso build target still exists"
else
    bad "an anaconda-iso build target still exists"
fi

# The stale comment claiming Anaconda asks by default was how this went
# unnoticed; make sure it does not come back.
if grep -q 'no kickstart/auto-wipe config is layered on' "$ISO_SH"; then
    bad "the disproven 'no kickstart is layered on' comment is back" \
        "bootc-image-builder generates one; it was measured"
else
    ok "no disproven claim that the ISO ships without a kickstart"
fi

echo ""
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
