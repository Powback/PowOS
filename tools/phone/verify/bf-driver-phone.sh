# bf-driver-phone.sh: (root inside PowOS; bf-driver.sh runs it while the game is up) which Vulkan driver the game's
# processes really load, and who owns GPU contexts while the CP AHB bus errors come. Read-only.
#  - every process mapping a Vulkan driver / loader / FEX Vulkan thunk: pid, comm, the mapped paths (in the process's
#    own mount namespace: /run/host = the real root, /run/gfx = a pressure-vessel graphics provider) + inode, and the
#    inodes of the candidates on disk to match them against
#  - the Vulkan/FEX/Turnip env of those processes, and where their stderr goes (Turnip's warnings land there)
#  - KGSL's per-process GPU memory owners (debugfs) and the AHB bus error count over 20 s
echo "== candidates (inode size path)"
for f in /usr/lib/libvulkan_freedreno.so /usr/share/fex-emu/RootFS/Fedora_44/usr/lib64/libvulkan_freedreno.so \
  /usr/share/fex-emu/RootFS/Fedora_44/usr/lib/libvulkan_freedreno.so; do echo "$(stat -Lc '%i %s' "$f") $f $(pacman -Qoq "$f" 2>/dev/null)"; done
echo "== processes mapping Vulkan"
ours=$(stat -Lc %i /usr/lib/libvulkan_freedreno.so); game_ours=0 game_other=""
for m in /proc/[0-9]*/maps; do p=${m#/proc/}; p=${p%/maps}
  case $(readlink /proc/$p/exe) in /system/*|/data/*) continue ;; esac   # Android's own apps: their own libvulkan
  hits=$(awk '$6 ~ /freedreno|libvulkan|vulkan-(host|guest)/ {print $5, $6, $7}' "$m" 2>/dev/null | sort -u)
  [ -n "$hits" ] || continue
  echo "-- pid $p $(cat /proc/$p/comm) ppid $(awk '{print $4}' /proc/$p/stat) exe=$(readlink /proc/$p/exe) cmd=$(tr '\0' ' ' < /proc/$p/cmdline | cut -c1-140)"
  echo "$hits" | sed 's/^/   map /'
  tr '\0' '\n' < /proc/$p/environ 2>/dev/null | grep -E '^(VK_|FEX_|TU_|tu_|MESA|PRESSURE_VESSEL_GRAPHICS|LD_LIBRARY_PATH|STEAM_COMPAT_TOOL_PATHS)' | cut -c1-300 | sed 's/^/   env /'
  echo "   stderr -> $(readlink /proc/$p/fd/2)"
  # The game's processes (FEX-run x86 or native Wine, not KWin/Xwayland): whose Turnip they really map, by inode.
  case $(readlink /proc/$p/exe) in *FEX* | *wine*)
    for i in $(echo "$hits" | awk '$2 ~ /vulkan_freedreno/ {print $1}'); do
      [ "$i" = "$ours" ] && game_ours=1 || game_other="$game_other $i"; done ;; esac
done
# bf-driver.sh's verdict: PASS only when the game maps OUR package's Turnip (native aarch64, via FEX's Vulkan thunk
# or ARM64 Proton), not FEX RootFS's emulated x86_64 one.
if [ $game_ours = 1 ]; then echo "== verdict: OURS - the game maps /usr/lib/libvulkan_freedreno.so inode $ours${game_other:+ (also:$game_other)}"
else echo "== verdict: NOT OURS - the game maps inode(s)${game_other:- none} (ours: $ours)"; fi
echo "== KGSL GPU memory owners"
for d in /sys/kernel/debug/kgsl/proc/[0-9]*; do [ -e "$d" ] || { echo "(no kgsl debugfs)"; break; }; p=${d##*/}; [ -d /proc/$p ] && echo "$p $(cat /proc/$p/comm) $(wc -l < $d/mem 2>/dev/null) bos"; done
c() { dmesg | grep -c 'AHB bus error'; }
a=$(c); sleep 20; b=$(c); echo "== AHB bus errors in 20 s (printk-ratelimited, ~10/5 s max): $((b - a))"
