package dev.omalauncher.system

import android.content.Context
import android.os.IBinder
import android.util.Log
import andro.marchy.RootShell

/**
 * The system's own caption on floating windows, off: PowOS draws every window's frame itself ([WindowFrame]), so
 * each one showed TWO title bars (2026-10-23: back, minimise, maximise, close under PowOS's bar). That caption is
 * AOSP WM Shell's CaptionWindowDecoration in SystemUI: CaptionWindowDecorViewModel.shouldShowWindowDecor is true for
 * EVERY freeform task, and updateRelayoutParams makes it visible for every freeform task - no flag or launch option
 * turns it off (dexdump of OxygenOS 16's SystemUI.apk). Its height is SystemUI's resource
 * dimen/freeform_decor_caption_height (42 dp; SystemUI declares no overlayables), so a fabricated runtime resource
 * overlay sets it to 0 dp: no caption surface, no caption insets, nothing to touch. The overlay lives in
 * /data/resource-cache and survives reboots; `cmd overlay disable com.android.shell:PowosNoCaption` brings the caption
 * back. `cmd overlay fabricate` can't write a dimension (int types only), so [main] registers it through the
 * framework's FabricatedOverlay, run as root with app_process from this APK.
 *
 * HACK: a resource overlay on SystemUI from root (hidden FabricatedOverlay.setOwningPackage/IOverlayManager). Real fix:
 * PowOS as the window decor provider (its own WM Shell decor, or a preinstalled static overlay in /product/overlay).
 */
object OemCaption {
    private const val TAG = "PowosOemCaption"
    private const val NAME = "PowosNoCaption"
    private const val TARGET = "com.android.systemui"
    private const val ID = "com.android.shell:$NAME"

    /** Turns the caption off unless it already is (one root `cmd overlay list`), on a worker thread. */
    fun off(context: Context) {
        val apk = context.applicationInfo.sourceDir
        Thread({
            val listed = RootShell.run("cmd overlay list $TARGET")
            if (listed.output.lineSequence().any { it.trim() == "[x] $ID" }) {
                Log.i(TAG, "system caption already off")
                return@Thread
            }
            val r = RootShell.run("CLASSPATH=$apk app_process /system/bin ${OemCaption::class.java.name} && cmd overlay enable $ID")
            Log.i(TAG, "system caption off: rc ${r.code} ${r.output.takeLast(300)}")
        }, "oem-caption").start()
    }

    /** Root, from app_process: registers the overlay (dimen/freeform_decor_caption_height = 0 dp), owned by the shell. */
    @JvmStatic
    fun main(args: Array<String>) {
        val fo = Class.forName("android.content.om.FabricatedOverlay")
        val overlay = fo.getConstructor(String::class.java, String::class.java).newInstance(NAME, TARGET)
        fo.getMethod("setOwningPackage", String::class.java).invoke(overlay, "com.android.shell")
        fo
            .getMethod("setResourceValue", String::class.java, Float::class.javaPrimitiveType, Int::class.javaPrimitiveType, String::class.java)
            .invoke(overlay, "$TARGET:dimen/freeform_decor_caption_height", 0f, 1 /* TypedValue.COMPLEX_UNIT_DIP */, null)
        val tx = Class.forName("android.content.om.OverlayManagerTransaction")
        val transaction = tx.getMethod("newInstance").invoke(null)
        tx.getMethod("registerFabricatedOverlay", fo).invoke(transaction, overlay)
        val binder = Class.forName("android.os.ServiceManager").getMethod("getService", String::class.java).invoke(null, "overlay") as IBinder
        val om = Class.forName("android.content.om.IOverlayManager\$Stub").getMethod("asInterface", IBinder::class.java).invoke(null, binder)!!
        om.javaClass.getMethod("commit", tx).invoke(om, transaction)
        println("registered $ID")
    }
}
