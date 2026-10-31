#!/system/bin/sh
# Android split screen's "horizontal / vertical" item in the divider menu (tap the handle's middle), for every app.
#
# OxygenOS's SystemUI enables that item only when both apps are on its "vSplit" list
# (DividerOrientationController.canToggleDividerOrientation -> supportLandscapeOrientation -> SplitScreenAppConfig,
# read from config/sys_wms_split_app.xml or /system_ext/oplus/sys_wms_split_app_ps.xml, the higher <version> wins).
# This phone's configs carry no <vSplit> element at all (only <vSplitPs>, which SystemUI doesn't read), so the item
# is greyed out for every pair. The rest of the gate is already on: the props (persist.sys.force_*_enable) are unset
# (= true) and oplus.hardware.type.fold makes the unfolded split force-oriented (DividerOrientation.reset).
#
#   post-fs-data: split-orientation.sh build   the stock file + one <vSplit> per app, at a version above both
#                                              configs, into the module's system/ (Magisk mounts it next)
#   service:      split-orientation.sh list    after boot: the installed packages, for the next boot's build
#
# Apps: the stock <vSplitPs> list (OnePlus's own) + every installed package (LIST, refreshed each boot, so a new
# app is on it from the boot after it's installed). Kept outside the module dir: a module update replaces that dir.
# Off: delete the module's system/system_ext (or disable the module) and reboot.
MODDIR=${0%/*}
STOCK=/system_ext/oplus/sys_wms_split_app_ps.xml
CLOUD=/data/oplus/os/config/sys_wms_split_app.xml
OUT=$MODDIR/system/system_ext/oplus/sys_wms_split_app_ps.xml
LIST=/data/adb/powos-split-apps.txt

case $1 in
list)
    pm list packages 2>/dev/null | sed -n 's/^package://p' > "$LIST.new" && [ -s "$LIST.new" ] &&
        chmod 600 "$LIST.new" && mv "$LIST.new" "$LIST"
    rm -f "$LIST.new"
    ;;
build)
    rm -f "$OUT"
    # Before Magisk's mount: $STOCK is still OnePlus's file here, never our previous copy.
    [ -f "$STOCK" ] || exit 0
    ver() { sed -n 's:.*<version>\([0-9]*\)</version>.*:\1:p' "$1" 2>/dev/null | head -1; }
    v=$(ver "$STOCK"); c=$(ver "$CLOUD")
    [ -n "$v" ] || exit 0
    [ -n "$c" ] && [ "$c" -gt "$v" ] && v=$c
    v=$((v + 1))
    mkdir -p "${OUT%/*}"
    {
        sed -e '/^<\/settings>$/d' -e "s:<version>[0-9]*</version>:<version>$v</version>:" "$STOCK"
        { sed -n 's:.*<vSplitPs attr="\([^"]*\)".*:\1:p' "$STOCK"; cat "$LIST" 2>/dev/null; } |
            grep -E '^[A-Za-z0-9_.]+$' | sort -u | sed 's:.*:    <vSplit attr="&"/>:'
        echo '</settings>'
    } > "$OUT.new"
    # Only a whole file: a broken one would empty SystemUI's split config (its parser drops everything on an error).
    if [ "$(grep -c '^</settings>$' "$OUT.new")" = 1 ] && grep -q "<version>$v</version>" "$OUT.new"; then
        chmod 644 "$OUT.new" && mv "$OUT.new" "$OUT"
        log -t powos-system "split orientation: $(grep -c '<vSplit ' "$OUT") apps, config version $v"
    fi
    rm -f "$OUT.new"
    ;;
esac
