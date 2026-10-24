#!/system/bin/sh
# powos-vpn-keep.sh: the phone's VPN client (the WireGuard app, the PowOS peer 10.13.13.7) may keep running while the
# phone rests. Without it Android and OPlus stop the client once the phone dozes: the tunnel's keepalives stop, the
# hub's handshake goes stale, and everything that reaches the phone over the VPN (adb, the ship service, the verify
# queue, the board) is cut off until the user wakes the phone (drops at ~13:40, 16:0x, 19:5x, 02:56 on 2026-10-23/24).
# Unit vpn-keep (units/phone-android/vpn-keep.json). Root, Android's side. Idempotent: run at every boot by
# powos-start.sh (once Android has booted) and at once by powos-deploy.sh.
#   sh /data/powos/powos-vpn-keep.sh [apply|status|remove]
# What it sets, all Android's own documented switches for "this app runs in the background", nothing patched:
#  - Doze/App Standby: the client on deviceidle's power-save allowlist (`dumpsys deviceidle whitelist +pkg`; Android
#    keeps it in /data/system/deviceidle.xml). An allowlisted app keeps its network in Doze and is App Standby
#    EXEMPT.
#  - Background restriction: appops RUN_ANY_IN_BACKGROUND / RUN_IN_BACKGROUND allow (Settings' "Allow background").
#  - Always-on VPN for the client (no lockdown): the system itself restarts the VPN service if it is killed. Written
#    to Settings.Secure always_on_vpn_app/_lockdown, the keys Settings' own toggle stores; VpnManagerService loads
#    them when the user starts, so a first apply takes effect at the next boot. An always-on app the user picked
#    is never replaced.
POWOS_VPN_PKG=${POWOS_VPN_PKG:-com.wireguard.android}
P=$POWOS_VPN_PKG
say() { echo "powos-vpn-keep: $*"; /system/bin/log -t powos-vpn-keep "$*" 2>/dev/null; }

installed() { pm path "$P" >/dev/null 2>&1; }

apply() {
  installed || { say "$P not installed: nothing to keep"; return 0; }
  dumpsys deviceidle whitelist +"$P" >/dev/null
  cmd appops set "$P" RUN_ANY_IN_BACKGROUND allow
  cmd appops set "$P" RUN_IN_BACKGROUND allow
  cur=$(settings get secure always_on_vpn_app)
  case "$cur" in
    "$P") ;;
    null|"") settings put secure always_on_vpn_app "$P"; settings put secure always_on_vpn_lockdown 0 ;;
    *) say "always-on VPN is $cur, not $P: left as the user set it" ;;
  esac
  say "applied for $P"
}

status() {
  installed || { echo "$P: not installed"; return 0; }
  w=$(dumpsys deviceidle whitelist | grep -c ",$P,")
  echo "deviceidle allowlist: $([ "$w" -gt 0 ] && echo yes || echo NO)"
  echo "appops: $(cmd appops get "$P" RUN_ANY_IN_BACKGROUND | tr -d '\n'); $(cmd appops get "$P" RUN_IN_BACKGROUND | tr -d '\n')"
  echo "standby bucket: $(am get-standby-bucket "$P")"
  echo "always-on VPN: $(settings get secure always_on_vpn_app) (lockdown $(settings get secure always_on_vpn_lockdown))"
  echo "client running: $(pidof "$P" >/dev/null && echo yes || echo NO); tun: $(ip -o addr show 2>/dev/null | awk '/10\.13\.13\./{print $2, $4}')"
}

remove() {
  dumpsys deviceidle whitelist -"$P" >/dev/null 2>&1
  cmd appops set "$P" RUN_ANY_IN_BACKGROUND default 2>/dev/null
  cmd appops set "$P" RUN_IN_BACKGROUND default 2>/dev/null
  [ "$(settings get secure always_on_vpn_app)" = "$P" ] && settings delete secure always_on_vpn_app
  say "removed for $P"
}

case ${1:-apply} in
  apply) apply ;;
  status) status ;;
  remove) remove ;;
  *) echo "usage: powos-vpn-keep.sh [apply|status|remove]" >&2; exit 2 ;;
esac
