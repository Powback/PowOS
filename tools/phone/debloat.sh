#!/bin/bash
# Debloat the PowOS phone (OnePlus Open, OxygenOS 16 CPH2551) - reversible, dry run by default.
# The lists and the reasons behind every entry are in docs/DEBLOAT-AUDIT.md (audit of 2026-10-23).
#
#   tools/phone/debloat.sh [plan]                       print what apply would do (default; touches nothing)
#   tools/phone/debloat.sh apply  [options]             do it; records exactly what changed
#   tools/phone/debloat.sh undo   [options]             reverse the last apply (or --state FILE)
#   tools/phone/debloat.sh status                       which listed packages are enabled/disabled/removed now
#
# Options (apply/undo/plan):
#   --android | --powos       one side only (default: Android only; PowOS needs --powos)
#   --only disable,uninstall  Android classes to act on (default: disable,uninstall)
#   --risky                   also disable the RISKY list (doc: Android "RISKY" table; one at a time is wiser)
#   --keep pkg[,pkg...]       leave these out (e.g. --keep com.oplus.consumerIRApp,com.microsoft.appmanager)
#   --powos-packages          PowOS: also remove the package set (pacman -Rs); default is autostart/indexer only
#   --now                     don't wait for the phone to be idle (default: refuse unless idle>=120 s)
#   --state FILE              undo this record instead of the newest
#
# What it does, and nothing else:
#   Android  DISABLE   pm disable-user --user 0 P           undo: pm enable --user 0 P
#            UNINSTALL pm uninstall -k --user 0 P            undo: cmd package install-existing --user 0 P
#            (user 0 only: the APK stays on /system|/product, data kept (-k); a factory reset restores all)
#   PowOS    autostart: Hidden=true overrides in ~powos/.config/autostart   undo: delete the override
#            baloo:     balooctl6 disable                                      undo: balooctl6 enable
#            packages:  pacman -Rs <set> (--powos-packages)                    undo: pacman -S --needed <removed>
# Never: firmware, partitions (persist/modem/EFS), OTA/anti-rollback, anything not in the lists below, Pi-hole.
# A KEEP guard refuses any list entry PowOS or the phone needs (launcher = oplushook scope, OTA, telephony...).
# Records: ~/.local/state/powos-debloat/<UTC>.state (Mac side), one "<side> <action> <pkg>" line per change.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
ADB="$here/adb.sh"
STATE_DIR="$HOME/.local/state/powos-debloat"

# ---- Android lists (docs/DEBLOAT-AUDIT.md, Android tables) ---------------------------------------------------------
DISABLE=(
  com.oplus.statistics.rom com.heytap.htms com.heytap.mcs com.oplus.stdid com.oplus.stdsp
  com.oplus.deepthinker com.oplus.metis com.oplus.pantanal.ums com.oplus.crashbox com.oplus.onetrace
  com.oplus.beaconlink com.oplus.dmp com.coloros.activation com.coloros.bootreg com.coloros.systemclone
  com.oplus.sau com.oplus.sauhelper com.oplus.cota com.cota.notification com.coloros.colordirectservice
  com.coloros.assistantscreen com.coloros.smartsidebar com.oplus.melody com.oneplus.account com.heytap.accessory
  com.google.android.apps.wellbeing com.android.hotwordenrollment.okgoogle com.android.hotwordenrollment.xgoogle
  com.google.android.feedback com.qualcomm.qti.devicestatisticsservice
)
UNINSTALL=(
  com.facebook.appmanager com.facebook.services com.facebook.system
  com.microsoft.appmanager com.microsoft.deviceintegrationservice com.microsoftsdk.crossdeviceservicebroker
  com.nearme.instant.platform com.oppo.quicksearchbox com.heytap.pictorial com.heytap.mydevices
  com.oneplus.store net.oneplus.forums com.oneplus.membership com.oneplus.brickmode net.oneplus.widget
  com.oneplus.backuprestore com.oplus.upgradeguide com.oplus.contentportal com.oplus.appsense com.oplus.logkit
  com.oplus.aimemory com.oplus.aiwriter com.oplus.games com.oplus.eid com.oplus.securepay com.oplus.consumerIRApp
  com.coloros.translate com.coloros.translate.engine com.coloros.operationManual com.coloros.childrenspace
  com.coloros.compass2 com.coloros.video com.coloros.ocrscanner com.coloros.floatassistant
  com.google.android.apps.googleassistant com.google.android.apps.bard com.google.android.projection.gearhead
  com.google.ar.core com.google.ar.lens
  com.android.egg com.android.bookmarkprovider com.android.providers.partnerbookmarks
  com.android.email.partnerprovider com.android.dreams.basic
)
# RISKY: disable only (never uninstall), only with --risky. Mainline ad-services modules are NOT here: turn them off
# in Settings > Privacy > Ads (pm on an APEX module fights the module updater).
RISKY=(
  com.oplus.athena com.oplus.phonemanager com.oplus.aiunit com.aiunit.aon com.oplus.romupdate com.oplus.wallpapers
  com.qualcomm.location
)
# Refused even if someone adds them to a list above.
GUARD=(
  android com.android.launcher com.powos.app com.powos.oplushook com.powos.config.recents com.topjohnwu.magisk
  com.oplus.ota com.android.phone com.android.server.telecom com.android.systemui
  com.android.settings com.android.providers.telephony com.android.nfc com.android.se com.android.bluetooth
  org.codeaurora.ims com.google.android.gms com.google.android.gsf com.android.vending com.google.android.webview
  com.google.android.tts com.android.chrome com.oplus.battery com.oplus.screenrecorder com.oplus.eyeprotect
  com.oneplus.oshare com.oplus.linker com.oplus.cast com.oplus.camera com.coloros.ocs.opencapabilityservice
  com.oplus.securitypermission com.oplus.safecenter com.oplus.apprecover com.wireguard.android
)

# ---- PowOS lists (docs/DEBLOAT-AUDIT.md, PowOS tables) -------------------------------------------------------------
# Session autostarts that do nothing on a phone (kdeconnectd: phone-in-phone, LAN mDNS broadcasts; kaccess:
# accessibility daemon; gmenudbusmenuproxy: GTK global menu, no global menu here). baloo is handled with balooctl6.
POWOS_AUTOSTART_OFF=(org.kde.kdeconnect.daemon kaccess gmenudbusmenuproxy)
# Dev toolchains, docs, network managers Android owns, Omarchy leftovers, apps with an Android equivalent.
POWOS_REMOVE=(
  mesa-docs cmake meson vulkan-headers glm wayland-protocols xorg-font-util xtrans po4a byacc patchelf python-ply
  lutris kdeconnect krdp netctl dhcpcd mkinitcpio-busybox noise-suppression-for-voice python-pip yad gum fish okular
)

# ---- args -----------------------------------------------------------------------------------------------------------
cmd=${1:-plan}; [ $# -gt 0 ] && shift
sides=android only=disable,uninstall risky=0 keep="" powpk=0 now=0 statefile=""
while [ $# -gt 0 ]; do
  case $1 in
    --android) sides=android ;; --powos) sides=powos ;; --both) sides=both ;;
    --only) only=$2; shift ;; --risky) risky=1 ;; --keep) keep=$2; shift ;;
    --powos-packages) powpk=1 ;; --now) now=1 ;; --state) statefile=$2; shift ;;
    *) sed -n '2,20p' "$0"; exit 1 ;;
  esac; shift
done
case $cmd in plan|apply|undo|status) ;; *) sed -n '2,20p' "$0"; exit 1 ;; esac
want_side() { [ "$sides" = both ] || [ "$sides" = "$1" ]; }
kept() { [[ ",$keep," == *",$1,"* ]]; }
guarded() { local g; for g in "${GUARD[@]}"; do [ "$g" = "$1" ] && return 0; done; return 1; }

# One adb call for the whole package state: "<pkg> enabled|disabled|removed|absent" (user 0).
android_state() {
  "$ADB" shell 'all=$(pm list packages -u | sed s/^package://); on=$(pm list packages | sed s/^package://);
    off=$(pm list packages -d | sed s/^package://);
    for p in '"$*"'; do
      if ! echo "$all" | grep -qx "$p"; then echo "$p absent";
      elif ! echo "$on" | grep -qx "$p"; then echo "$p removed";
      elif echo "$off" | grep -qx "$p"; then echo "$p disabled";
      else echo "$p enabled"; fi; done'
}

# Build the Android action list: "<action> <pkg>" for every package not already in its target state.
android_plan() {
  local list=() p
  [[ ",$only," == *",disable,"* ]] && list+=("${DISABLE[@]}")
  [[ ",$only," == *",uninstall,"* ]] && list+=("${UNINSTALL[@]}")
  [ $risky = 1 ] && list+=("${RISKY[@]}")
  [ ${#list[@]} -gt 0 ] || return 0
  # (macOS bash 3.2: no associative arrays) one "<pkg> <state>" line per package
  local states; states=$(android_state "${list[@]}" | tr -d '\r')
  for p in "${DISABLE[@]}" "${UNINSTALL[@]}" "${RISKY[@]}"; do
    [[ " ${list[*]} " == *" $p "* ]] || continue
    kept "$p" && { echo "# keep (--keep) $p"; continue; }
    guarded "$p" && { echo "# REFUSED (guard) $p"; continue; }
    case $(echo "$states" | awk -v p="$p" '$1==p{print $2}') in
      absent|"") echo "# not on this phone: $p" ;;
      removed) echo "# already removed for user 0: $p" ;;
      disabled) [[ " ${UNINSTALL[*]} " == *" $p "* ]] && echo "uninstall $p" || echo "# already disabled: $p" ;;
      enabled) [[ " ${UNINSTALL[*]} " == *" $p "* ]] && echo "uninstall $p" || echo "disable $p" ;;
    esac
  done
}

wait_idle() {
  [ $now = 1 ] && return 0
  local l; l=$("$here/idle.sh")
  local i=${l#idle=}; i=${i%% *}
  [ "${i:-0}" -ge 120 ] || { echo "refused: the phone is in use ($l). Retry when idle, or --now." >&2; exit 1; }
}

android_cmd() {  # action pkg -> the adb shell command
  case $1 in
    disable) echo "pm disable-user --user 0 $2" ;;
    uninstall) echo "pm uninstall -k --user 0 $2" ;;
    enable) echo "pm enable --user 0 $2" ;;
    restore) echo "cmd package install-existing --user 0 $2" ;;
  esac
}

# ---- PowOS helpers (scripts written under $HOME: Colima shares only the home directory with adb.sh's container) ---
powos_user_script() {  # $1 = apply|undo
  local f; f=$(mktemp "$HOME/.cache/powos-debloat-user.XXXXXX"); {
    echo 'set -u; d=$HOME/.config/autostart; mkdir -p "$d"'
    for a in "${POWOS_AUTOSTART_OFF[@]}"; do
      if [ "$1" = apply ]; then
        echo "[ -e \"\$d/$a.desktop\" ] || { printf '[Desktop Entry]\\nHidden=true\\n# powos-debloat\\n' > \"\$d/$a.desktop\"; echo 'autostart off: $a'; }"
      else
        echo "grep -q powos-debloat \"\$d/$a.desktop\" 2>/dev/null && rm -f \"\$d/$a.desktop\" && echo 'autostart restored: $a'"
      fi
    done
    [ "$1" = apply ] && echo 'balooctl6 disable >/dev/null 2>&1 && echo "baloo indexer off"' \
                     || echo 'balooctl6 enable >/dev/null 2>&1 && echo "baloo indexer on"'
    echo 'true'
  } > "$f"; echo "$f"
}

powos_root_script() {  # $1 = apply|undo, $2 = removed-list (undo)
  local f; f=$(mktemp "$HOME/.cache/powos-debloat-root.XXXXXX"); {
    echo 'set -eu; export LC_ALL=C'
    if [ "$1" = apply ]; then
      echo "set=\"\$(for p in ${POWOS_REMOVE[*]}; do pacman -Q \$p >/dev/null 2>&1 && echo \$p; done)\""
      echo '[ -n "$set" ] || { echo "nothing to remove"; exit 0; }'
      echo 'pacman -Rsp --print-format "%n" $set > /tmp/powos-debloat-removed.txt'
      echo 'echo "REMOVED: $(tr "\n" " " < /tmp/powos-debloat-removed.txt)"'
      echo 'pacman -Rs --noconfirm $set'
    else
      echo "pacman -S --needed --noconfirm $2"
    fi
  } > "$f"; echo "$f"
}

# adb.sh runs `docker run -i`: inside a `| while read` loop it would swallow the loop's input, hence </dev/null.
# ---- commands -------------------------------------------------------------------------------------------------------
case $cmd in
status)
  android_state "${DISABLE[@]}" "${UNINSTALL[@]}" "${RISKY[@]}" | tr -d '\r' | sort -k2 | awk '{print $2"\t"$1}'
  ;;
plan)
  if want_side android; then
    echo "== Android (dry run: nothing is changed)"
    android_plan | while read -r a p; do
      case $a in '#'*) echo "$a $p" ;; *) echo "adb shell $(android_cmd "$a" "$p")" ;; esac
    done
  fi
  if want_side powos; then
    echo "== PowOS (dry run)"
    for a in "${POWOS_AUTOSTART_OFF[@]}"; do echo "autostart off: ~powos/.config/autostart/$a.desktop (Hidden=true)"; done
    echo "baloo: balooctl6 disable"
    [ $powpk = 1 ] && echo "pacman -Rs ${POWOS_REMOVE[*]}  (closure measured 2026-10-23: 150 packages, ~800 MB)" \
                   || echo "(packages: add --powos-packages to also remove: ${POWOS_REMOVE[*]})"
  fi
  ;;
apply)
  wait_idle
  mkdir -p "$STATE_DIR"; rec="$STATE_DIR/$(date -u +%Y%m%dT%H%M%SZ).state"; : > "$rec"
  if want_side android; then
    android_plan | while read -r a p; do
      case $a in '#'*) echo "$a $p"; continue ;; esac
      c=$(android_cmd "$a" "$p"); out=$("$ADB" shell "$c" 2>&1 </dev/null | tr -d '\r') || true
      echo "$c -> $out"
      case $out in *rror*|*xception*|*ailure*) ;; *) echo "android $a $p" >> "$rec" ;; esac
    done
  fi
  if want_side powos; then
    f=$(powos_user_script apply); "$here/user.sh" "$f" | tee -a /dev/stderr | sed -n 's/^autostart off: /powos autostart /p' >> "$rec" || true
    rm -f "$f"; echo "powos baloo off" >> "$rec"
    if [ $powpk = 1 ]; then
      f=$(powos_root_script apply); out=$("$here/root.sh" "$f" 2>&1) || true; rm -f "$f"; echo "$out"
      r=$(echo "$out" | sed -n 's/^REMOVED: //p'); [ -n "$r" ] && echo "powos packages $r" >> "$rec"
    fi
  fi
  echo "recorded: $rec   (undo: $0 undo --state $rec)"
  ;;
undo)
  rec=${statefile:-$(ls -t "$STATE_DIR"/*.state 2>/dev/null | head -1)}
  [ -n "$rec" ] && [ -f "$rec" ] || { echo "no record to undo in $STATE_DIR" >&2; exit 1; }
  wait_idle
  echo "undoing $rec"
  # Android, newest change first (tail -r on macOS, tac elsewhere).
  {   tail -r "$rec" 2>/dev/null || tac "$rec"; } | while read -r side a rest; do
    [ "$side" = android ] || continue
    case $a in disable) c=$(android_cmd enable "$rest") ;; uninstall) c=$(android_cmd restore "$rest") ;; *) continue ;; esac
    want_side android && { echo "$c -> $("$ADB" shell "$c" 2>&1 </dev/null | tr -d '\r')"; }
  done
  if want_side powos && grep -q '^powos ' "$rec"; then
    r=$(sed -n 's/^powos packages //p' "$rec")
    if [ -n "$r" ]; then f=$(powos_root_script undo "$r"); "$here/root.sh" "$f"; rm -f "$f"; fi
    f=$(powos_user_script undo); "$here/user.sh" "$f"; rm -f "$f"
  fi
  mv "$rec" "$rec.undone"; echo "done; record kept as $rec.undone"
  ;;
esac
