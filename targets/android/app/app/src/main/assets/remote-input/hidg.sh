# Remote input's USB side (shell/RemoteInput.kt), run as root: the phone as a USB keyboard and mouse to the computer
# its cable goes to - HID functions on Android's own USB gadget (configfs g1), next to adb, mtp or whatever
# sys.usb.config has.
#
#   hidg.sh up      both functions made and in the gadget's config; prints "kb /dev/hidgN" and "mouse /dev/hidgN"
#   hidg.sh down    taken out again: the gadget as Android set it (rollback)
#   hidg.sh status  "on" / "off", the UDC's state (configured = a computer enumerated it)
#   hidg.sh pipe K M   reports from stdin, a line each: "k <bytes>" to K, "m <bytes>" to M, bytes as \0NNN (mksh print's octal)
#
# Why this survives Android's USB handling (vendor/etc/init/hw/init.qcom.usb.rc, vendor.usb.use_gadget_hal=0 here):
# each sys.usb.config change rewrites the config's links f1..f9 and rebinds the UDC, never touching links of other
# names - ours are "powos_kb"/"powos_mouse", so a mode change (mtp, rndis) or a replug keeps them, and adb's f1 stays
# what init made it. Only a reboot drops them (configfs is in memory): RemoteInput runs `up` again then. Binding goes
# through the UDC file directly, never sys.usb.config=none, which stops adbd (network adb would drop with it).
G=/config/usb_gadget/g1
KB=$G/functions/hid.powos_kb
MS=$G/functions/hid.powos_mouse
CFG=$G/configs/b.1

# The boot-protocol keyboard (HID 1.11 appendix B.1): modifiers, reserved, 6 keys; LEDs out. Works in a BIOS.
KB_DESC='\0005\0001\0011\0006\0241\0001\0005\0007\0031\0340\0051\0347\0025\0000\0045\0001\0165\0001\0225\0010\0201\0002\0225\0001\0165\0010\0201\0001\0225\0005\0165\0001\0005\0010\0031\0001\0051\0005\0221\0002\0225\0001\0165\0003\0221\0001\0225\0006\0165\0010\0025\0000\0045\0145\0005\0007\0031\0000\0051\0145\0201\0000\0300'
# A boot-compatible mouse: 5 buttons, X, Y (relative, -127..127), wheel, horizontal wheel (AC Pan) - 5 bytes.
MS_DESC='\0005\0001\0011\0002\0241\0001\0011\0001\0241\0000\0005\0011\0031\0001\0051\0005\0025\0000\0045\0001\0225\0005\0165\0001\0201\0002\0225\0001\0165\0003\0201\0001\0005\0001\0011\0060\0011\0061\0011\0070\0025\0201\0045\0177\0165\0010\0225\0003\0201\0006\0005\0014\0012\0070\0002\0225\0001\0201\0006\0300\0300'

udc() { getprop sys.usb.controller; }

# The UDC unbound: a config's links can only change then (the kernel refuses them on a bound gadget), and are read
# at the next bind.
unbind() { echo "" > $G/UDC 2>/dev/null; }

# Binds the UDC again, retrying while adbd's functionfs comes back.
bind() {
  c=$(udc)
  i=0
  while [ $i -lt 50 ]; do
    echo "$c" > $G/UDC 2>/dev/null
    [ "$(cat $G/UDC)" = "$c" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  echo "error: UDC $c would not bind" >&2
  return 1
}

# /dev/hidgN of function dir $1 (its "dev" is major:minor; /sys/class/hidg lists the nodes).
node() {
  d=$(cat $1/dev 2>/dev/null)
  for n in /sys/class/hidg/hidg*; do
    [ "$(cat $n/dev 2>/dev/null)" = "$d" ] && { echo /dev/${n##*/}; return 0; }
  done
  return 1
}

make_fn() { # dir protocol report_length desc
  [ -d $1 ] && return 0
  mkdir $1 || return 1
  echo 1 > $1/subclass
  echo $2 > $1/protocol
  echo $3 > $1/report_length
  print -n -- "$4" > $1/report_desc
}

case "$1" in
up)
  [ -d $G ] || { echo "error: no configfs gadget $G" >&2; exit 1; }
  # Made by an older helper with other descriptors: taken down and made anew (they can't change while linked).
  { [ -d $KB ] && ! print -n -- "$KB_DESC" | cmp -s - $KB/report_desc; } && sh "$0" down >/dev/null
  { [ -d $MS ] && ! print -n -- "$MS_DESC" | cmp -s - $MS/report_desc; } && sh "$0" down >/dev/null
  make_fn $KB 1 8 "$KB_DESC" || { echo "error: can't make $KB (CONFIG_USB_CONFIGFS_F_HID?)" >&2; exit 1; }
  make_fn $MS 2 5 "$MS_DESC" || exit 1
  if [ ! -L $CFG/powos_kb ] || [ ! -L $CFG/powos_mouse ]; then
    unbind
    [ -L $CFG/powos_kb ] || ln -s $KB $CFG/powos_kb
    [ -L $CFG/powos_mouse ] || ln -s $MS $CFG/powos_mouse
    bind || exit 1
    [ -L $CFG/powos_kb ] && [ -L $CFG/powos_mouse ] || { echo "error: the gadget refused the HID functions" >&2; exit 1; }
  fi
  i=0
  while ! node $KB >/dev/null || ! node $MS >/dev/null || [ ! -c "$(node $MS)" ]; do
    i=$((i + 1)); [ $i -gt 30 ] && { echo "error: no /dev/hidg nodes" >&2; exit 1; }
    sleep 0.1
  done
  echo "kb $(node $KB)"
  echo "mouse $(node $MS)"
  ;;
down)
  if [ -L $CFG/powos_kb ] || [ -L $CFG/powos_mouse ]; then
    unbind
    rm -f $CFG/powos_kb $CFG/powos_mouse
    bind
  fi
  [ -d $KB ] && rmdir $KB
  [ -d $MS ] && rmdir $MS
  echo off
  ;;
status)
  if [ -L $CFG/powos_kb ]; then echo on; else echo off; fi
  cat /sys/class/udc/$(udc)/state 2>/dev/null || echo unknown
  ;;
pipe)
  # Held open: a report is one write. A computer not reading (unplugged) makes a write fail, not hang (f_hid: the
  # endpoint is disabled), so the next one is tried afresh.
  exec 3>"$2" 4>"$3" || exit 1
  echo ready
  while read -r t d; do
    case "$t" in
      k) print -n -- "$d" >&3 2>/dev/null || { exec 3>&-; exec 3>"$2"; } ;;
      m) print -n -- "$d" >&4 2>/dev/null || { exec 4>&-; exec 4>"$3"; } ;;
      q) exit 0 ;;
    esac
  done
  ;;
*)
  echo "usage: hidg.sh up|down|status|pipe KB MOUSE" >&2
  exit 2
  ;;
esac
