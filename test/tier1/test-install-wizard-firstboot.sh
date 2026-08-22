#!/bin/bash
# test-install-wizard-firstboot.sh - Tier-1 tests for placing install.conf on
# the freshly installed system.
#
# This step decides whether a completed install has a user account at all. It
# was broken in two independent ways at once and failed silently:
#
#   * the root partition was looked up by FILESYSTEM label "PowOS", which
#     nothing ever sets (bootc labels the root fs "root"; the alongside path
#     sets only a GPT PARTLABEL), so the lookup was always empty; and
#   * the config was written to <partition>/etc, while on an ostree/bootc
#     system the booted /etc lives inside the DEPLOYMENT.
#
# Either one alone produces an install that boots to a login prompt with no
# account to log in as. These tests pin both.
#
# Runs anywhere, no root, no real disks: mount/umount/lsblk/blkid are shadowed
# and "partitions" are directory trees.
#
# Usage:  bash test/tier1/test-install-wizard-firstboot.sh

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB=$(cd "$HERE/../../lib" && pwd)/install-wizard.sh
[[ -f "$LIB" ]] || LIB="/usr/lib/powos/install-wizard.sh"

PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1"; FAIL=$((FAIL+1)); [[ -n "${2:-}" ]] && echo "         $2"; }

# shellcheck source=/dev/null
source "$LIB" 2>/dev/null || { echo "cannot source $LIB"; exit 1; }

# ── Shadows ────────────────────────────────────────────────────────────────
# Each "partition" is a directory tree. mount copies it into the mountpoint,
# umount copies it back, so the test can inspect what the code wrote.
declare -A FAKEFS=()
PARTS=""
MOUNTED=""

lsblk() { printf '%s\n' "${IWZ_DISK:-/dev/fake}"; printf '%s\n' $PARTS; }
blkid() { return 1; }
mount() {
    local src="$1" dst="$2" fake="${FAKEFS[$1]:-}"
    [[ -n "$fake" ]] || return 1
    cp -a "$fake/." "$dst/" 2>/dev/null || return 1
    MOUNTED="$dst|$fake"; return 0
}
umount() {
    [[ -n "$MOUNTED" ]] || return 0
    local dst="${MOUNTED%%|*}"
    cp -a "$dst/." "${MOUNTED##*|}/" 2>/dev/null
    rm -rf "${dst:?}"/* 2>/dev/null
    MOUNTED=""; return 0
}
# The candidate list normally comes from lsblk on the target disk; feed it the
# fakes directly so the test does not need real devices.
iwz__target_partitions() { printf '%s\n' $PARTS; }

SCRATCH=""
setup() {
    SCRATCH=$(mktemp -d); FAKEFS=(); PARTS=""; MOUNTED=""
    IWZ_CONFIG_PATH="$SCRATCH/install.conf"
    printf 'POWOS_USER=powos\n' > "$IWZ_CONFIG_PATH"
    IWZ_DISK="/dev/fake"
}
teardown() { rm -rf "$SCRATCH"; }

# Build a partition tree containing an ostree deployment at $2 (relative).
mk_part() {
    local dev="$1" rel="$2" d
    d="$SCRATCH/$(echo "$dev" | tr / _)"
    mkdir -p "$d/$rel/etc"
    FAKEFS["$dev"]="$d"
    PARTS="$PARTS $dev"
}
mk_blank_part() {
    local dev="$1" d
    d="$SCRATCH/$(echo "$dev" | tr / _)"
    mkdir -p "$d/lost+found"
    FAKEFS["$dev"]="$d"
    PARTS="$PARTS $dev"
}
placed_at() { find "$SCRATCH" -path '*/powos/install.conf' | head -1; }

# ── Tests ──────────────────────────────────────────────────────────────────

t_writes_into_the_deployment() {
    setup
    mk_part /dev/fake3 "ostree/deploy/default/deploy/abc123.0"
    if iwz_copy_config_to_target >/dev/null 2>&1; then
        local got; got=$(placed_at)
        if [[ "$got" == *"/deploy/abc123.0/etc/powos/install.conf" ]]; then
            ok "install.conf lands inside the ostree deployment's /etc"
        else
            bad "install.conf lands inside the ostree deployment's /etc" "got '${got:-<nothing>}'"
        fi
    else
        bad "install.conf lands inside the ostree deployment's /etc" "copy reported failure"
    fi
    teardown
}

t_not_at_partition_root() {
    setup
    mk_part /dev/fake3 "ostree/deploy/default/deploy/abc123.0"
    iwz_copy_config_to_target >/dev/null 2>&1
    if [[ ! -e "$SCRATCH/_dev_fake3/etc/powos/install.conf" ]]; then
        ok "nothing is written to the top of the partition (the booted system never sees it)"
    else
        bad "nothing is written to the top of the partition"
    fi
    teardown
}

t_nested_subvolume_layout() {
    setup
    mk_part /dev/fake3 "root/ostree/deploy/default/deploy/def456.0"
    if iwz_copy_config_to_target >/dev/null 2>&1 && \
       [[ "$(placed_at)" == *"/deploy/def456.0/etc/powos/install.conf" ]]; then
        ok "a btrfs-subvolume layout (one level deeper) is found too"
    else
        bad "a btrfs-subvolume layout is found too" "got '$(placed_at)'"
    fi
    teardown
}

t_skips_partitions_without_a_deployment() {
    setup
    mk_blank_part /dev/fake1
    mk_blank_part /dev/fake2
    mk_part       /dev/fake3 "ostree/deploy/default/deploy/abc123.0"
    if iwz_copy_config_to_target >/dev/null 2>&1 && \
       [[ "$(placed_at)" == *"_dev_fake3/"*"/etc/powos/install.conf" ]]; then
        ok "ESP and boot partitions are skipped; the deployment partition wins"
    else
        bad "ESP and boot partitions are skipped" "got '$(placed_at)'"
    fi
    teardown
}

t_no_deployment_is_a_loud_failure() {
    setup
    mk_blank_part /dev/fake1
    if iwz_copy_config_to_target >/dev/null 2>&1; then
        bad "finding no deployment reports failure" "returned success"
    else
        ok "finding no deployment reports FAILURE rather than passing silently"
    fi
    teardown
}

t_config_contents_survive() {
    setup
    mk_part /dev/fake3 "ostree/deploy/default/deploy/abc123.0"
    iwz_copy_config_to_target >/dev/null 2>&1
    if grep -q '^POWOS_USER=powos$' "$(placed_at)" 2>/dev/null; then
        ok "the copied config is the wizard's config, byte for byte"
    else
        bad "the copied config is the wizard's config"
    fi
    teardown
}

t_writes_into_the_deployment
t_not_at_partition_root
t_nested_subvolume_layout
t_skips_partitions_without_a_deployment
t_no_deployment_is_a_loud_failure
t_config_contents_survive

echo ""
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
