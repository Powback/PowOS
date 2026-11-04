#!/bin/bash
# lanes: phone
# vulkan-freedreno-install.sh MIN [OUT]: installs the newest built vulkan-freedreno-kgsl package (Turnip on KGSL:
# /usr/lib/libvulkan_freedreno.so + its ICD; here, a sibling worktree, or the shared build-inputs cache - the lookup
# xwayland-install.sh uses) if it's newer than the installed one, and FAILs if the installed package ends up older
# than MIN or Vulkan doesn't work with it. xwayland-install.sh's twin for the Vulkan driver.
# The first install replaces Arch's vulkan-freedreno (pacman --ask 4: "remove the conflicting package?" yes), as
# powos-deploy.sh does. No session restart: every NEW Vulkan process loads the installed library; a game already
# running keeps the one it mapped until it restarts.
# PASS = pacman owns the installed files (the library on disk IS the package's), and vulkaninfo as the session user
#        lists the Adreno GPU on driver "turnip" (a trivial Vulkan client; never Steam or a game).
# From 26.3.0-2 also: Turnip logs that it refused KGSL's IOCOHERENT (0002, gfx3d_user isn't dma-coherent here).
# Also prints the KGSL CP AHB bus error rate ("CP_RL_ERROR_DETAILS_0:0x10008e07", BV writing RB_CCU_CNTL, fixed in
# the package's 0001) over the last 10 s - informational: it is 0 when no Vulkan game is drawing either.
# Queue it first against the board task, then the game check that needs the new Turnip:
#   queue.sh add <task> tools/phone/verify/vulkan-freedreno-install.sh 26.3.0-1
# Exit: 0 passed; 1 FAIL; 3 a real touch / no free window / not now (re-queued); 5 can't run.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=${VF_TOOLS:-$here/..}
OUT=${2:-$HOME/.cache/powos-verify/vulkan-freedreno-install-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
[ $# -ge 1 ] || { echo "usage: vulkan-freedreno-install.sh MIN [OUT]"; exit 2; }
. "$here/kwin-up.sh"   # _kw_rs/_kw_sh/_kw_us, KWIN_ROOT
fail() { echo "FAIL: $*"; exit 1; }
log() { echo "$*"; }
min=$1 name=vulkan-freedreno-kgsl
vf_installed() { _kw_rs "pacman -Q $name 2>/dev/null | cut -d\" \" -f2" | tail -1; }

pkg=${VF_PKG:-$(ls -t "$KWIN_ROOT"/targets/android/out/pkgs/$name-*.pkg.tar.* \
  "$KWIN_ROOT"/../*/targets/android/out/pkgs/$name-*.pkg.tar.* \
  "${POWOS_BUILD_INPUTS_CACHE:-$HOME/.cache/powos-build-inputs}"/pkgs/$name-*.pkg.tar.* 2>/dev/null | head -1)}
want=$(basename "${pkg:-none}" | sed -E "s/^$name-([^-]+-[^-]+)-.*/\1/")
had=$(vf_installed)
log "$name installed ${had:-none}, newest package $want (${pkg:-none})"
if [ -n "${pkg:-}" ] && [ "$had" != "$want" ] && [ "$(_kw_rs "vercmp '$want' '${had:-0}'" | tail -1)" -gt 0 ] 2>/dev/null; then
  "$T/adb.sh" push "$pkg" /data/local/tmp/powos-vulkan-freedreno.pkg.tar.xz >/dev/null
  _kw_sh "mv /data/local/tmp/powos-vulkan-freedreno.pkg.tar.xz /data/powos/root/var/tmp/"
  # The rollback: the files the install replaces (Arch's vulkan-freedreno or our older build), as they are now.
  _kw_rs "set -e; mkdir -p /var/cache/powos
tar -cf /var/cache/powos/vulkan-freedreno-before-$want.tar /usr/lib/libvulkan_freedreno.so /usr/share/vulkan/icd.d/freedreno_icd.aarch64.json
pacman -U --noconfirm --ask 4 /var/tmp/powos-vulkan-freedreno.pkg.tar.xz >/dev/null && rm -f /var/tmp/powos-vulkan-freedreno.pkg.tar.xz
pacman -Q $name" | tail -1 | while read -r l; do log "installed: $l"; done
fi
v=$(vf_installed)
[ -n "$v" ] || fail "$name isn't installed (${pkg:-no package found})"
[ "$(_kw_rs "vercmp '$v' '$min'" | tail -1)" -ge 0 ] 2>/dev/null || fail "the installed $name $v is older than $min"
rb="(rollback: tar -xf /var/cache/powos/vulkan-freedreno-before-$v.tar -C /)"
k=$(_kw_rs "pacman -Qkk $name 2>&1 | tail -1")
log "files: $k"
[[ $k == *" 0 altered files"* ]] || fail "the files on disk aren't the package's ($k) $rb"
# A trivial Vulkan client as the session user: the loader picks the ICD, Turnip opens /dev/kgsl-3d0.
vi=$(_kw_us 'timeout 20 vulkaninfo --summary 2>&1 | grep -E "deviceName|driverName|driverInfo|ERROR|IOCOHERENT" | tr -s " " | tr "\n" ";"' | tail -1)
log "vulkaninfo: $vi"
[[ $vi == *driverName*turnip* && $vi == *Adreno* ]] || fail "vulkaninfo doesn't list the Adreno GPU on Turnip ($vi) $rb"
# 26.3.0-2's 0002: this phone's gfx3d_user context bank isn't dma-coherent, so Turnip must refuse KGSL's IOCOHERENT
# (one warning per process) - FEX's tu_override_uncached_as_cache_coherent is then a no-op.
if [ "$(_kw_rs "vercmp '$v' 26.3.0-2" | tail -1)" -ge 0 ] 2>/dev/null; then
  [[ $vi == *"KGSL accepts IOCOHERENT but"* ]] || fail "Turnip $v didn't refuse KGSL's IOCOHERENT (no 0002 warning: $vi) $rb"
  log "IOCOHERENT refused (cached memory non-coherent): yes"
fi
# dmesg's clock leaves suspend out (/proc/uptime doesn't): "now" is the newest line's own time.
e=$(_kw_rs 'dmesg | tac | awk '"'"'NR==1{now=substr($1,2)+0} {t=$1; gsub(/[][]/,"",t)} /AHB bus error/{if (t+0>now-10) n++} /gen7_err_callback: [0-9]+ callbacks suppressed/{if (t+0>now-10) n+=$3} END{print n+0}'"'"'' | tail -1)
log "KGSL CP AHB bus errors in the last 10 s: ${e:-?} (0 expected while a Vulkan game draws with the new Turnip)"
echo "PASS: $name $v installed, Vulkan works on it ($vi)"
