package dev.omalauncher.system

import android.content.Context
import android.util.Log
import andro.marchy.RootShell

/**
 * Split screen side by side (left | right) on the unfolded inner screen. The user, 2026-10-29: "it places it like
 * vertical instead of horizontal. So we get like two on top. And bottom instead of one on the left si[de, one on the
 * right]". WM Shell's SplitLayout (OxygenOS 16 SystemUI.apk, dexdump) splits left/right only when the display is
 * landscape - the inner screen is 2268x2440, portrait by a hair, so it split top/bottom - unless
 * SplitScreenUtils.allowLeftRightSplitInPortrait: the FRAMEWORK's bool config_leftRightSplitInPortrait (0x011101e0,
 * android package; no flag gate on this build), false here. With it true, SplitScreenUtils.isLeftRightSplit gives
 * left/right on a large screen (smallest width >= 600 dp: the unfolded one) in portrait, as AOSP's foldables do; the
 * folded cover screen isn't large and keeps top/bottom. OnePlus' own divider already agrees: DividerOrientation.reset
 * forces a vertical divider when unfolded. A real WM Shell split: draggable divider, swap, its own animations.
 *
 * A fabricated runtime resource overlay (com.android.shell:[NAME], root `cmd overlay fabricate`) sets it; it lives
 * in /data/resource-cache and survives reboots. SplitLayout reads the bool once, when SystemUI starts: the first time
 * it is enabled it takes effect after SystemUI's next start (reboot). `cmd overlay disable com.android.shell:$NAME`
 * restores top/bottom.
 *
 * HACK: a framework resource overlay from root, because OxygenOS ships config_leftRightSplitInPortrait false and offers
 * no setting for it. Real fix: the device config (framework-res overlay) shipping it true for the inner display.
 */
object SplitSideBySide {
    private const val TAG = "PowosSplitSideBySide"
    private const val NAME = "PowosSplitSideBySide"
    private const val ID = "com.android.shell:$NAME"
    private const val RES = "android:bool/config_leftRightSplitInPortrait"

    /** Turns it on unless the enabled overlay already says true (one root call), on a worker thread. */
    fun on(context: Context) {
        Thread({
            val listed = RootShell.run("cmd overlay list android | grep -F '$ID'; cmd overlay lookup android $RES").output
            if (listed.contains("[x] $ID") && listed.trim().endsWith("true")) {
                Log.i(TAG, "split side by side already on")
                return@Thread
            }
            // 0x12: TypedValue.TYPE_INT_BOOLEAN, 0xffffffff its true.
            val r = RootShell.run("cmd overlay fabricate --target android --name $NAME $RES 0x12 0xffffffff && cmd overlay enable $ID")
            Log.i(TAG, "split side by side on: rc ${r.code} ${r.output.takeLast(300)}")
        }, "split-side-by-side").start()
    }
}
