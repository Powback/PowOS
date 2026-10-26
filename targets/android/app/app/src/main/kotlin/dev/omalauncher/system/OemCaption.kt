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
 * overlay shrinks it to [CAPTION_PX] (1 px): no caption to see, no caption insets worth the name. NOT 0: the caption's
 * input window (WindowDecoration.updateViewHierarchy: a SurfaceControlViewHost window as high as the caption, no
 * touchable region of its own, so WM uses its crop) then has an EMPTY crop, which SurfaceFlinger treats as no crop -
 * its touchable region became the whole task (dumpsys input, 2026-10-23: "Caption of Task=2476" frame 0x0, touchable
 * [336,285][1696,1993]) and its root view is the caption's drag handle (CaptionTouchEventListener: any move drags the
 * task), so a swipe anywhere in the app dragged the window (desk-probe r2a) and the app got no touches. At 1 px the
 * caption's input is its own 1 px row at the task's top, which PowOS's bar window covers ([WindowFrame] reaches
 * [CAPTION_PX] into the task): no touch ever reaches it. The overlay lives in /data/resource-cache and survives
 * reboots; `cmd overlay disable com.android.shell:PowosNoCaption` brings the caption back. `cmd overlay fabricate`
 * can't write a dimension (int types only), so [main] registers it through the framework's FabricatedOverlay, run as
 * root with app_process from this APK. The same decoration also puts its own drag-resize input handles around every
 * freeform task (DragResizeInputListener: 15 dp edges, 44 dp corners, partly outside the task), which resize the task
 * behind PowOS's frame; their sizes ([HANDLES]) go to 0 dp in the same overlay (their listener sets an explicit
 * region, empty at 0: dumpsys input shows it <empty>), so only PowOS's grip resizes.
 *
 * HACK: a resource overlay on SystemUI from root (hidden FabricatedOverlay.setOwningPackage/IOverlayManager), the caption
 * kept 1 px high under PowOS's bar because SystemUI offers no way to drop its input window. Real fix: PowOS as the window
 * decor provider (WM Shell without a caption for PowOS-framed tasks: no decor window, no input), which needs SystemUI.
 */
object OemCaption {
    private const val TAG = "PowosOemCaption"
    private const val NAME = "PowosNoCaption"
    private const val TARGET = "com.android.systemui"
    private const val ID = "com.android.shell:$NAME"

    /** The caption's height under the overlay, px: [WindowFrame]'s bar reaches this far into the task to cover it. */
    const val CAPTION_PX = 1

    /** How `cmd overlay dump` shows it: a complex dimension, [CAPTION_PX] px (mantissa << 8, unit 0 = px). */
    private val CAPTION_DUMP = "dimension 0x%08x (dimen/freeform_decor_caption_height)".format(CAPTION_PX shl 8)

    /** WM Shell's drag-resize handle sizes (DragResizeWindowGeometry), 0 dp with the caption's height. */
    private val HANDLES =
        listOf("freeform_resize_handle", "freeform_edge_handle_outset", "freeform_edge_handle_inset", "freeform_resize_corner", "desktop_mode_corner_resize_large")

    /** Turns the caption off unless the enabled overlay already has every value (one root call), on a worker thread. */
    fun off(context: Context) {
        val apk = context.applicationInfo.sourceDir
        Thread({
            val listed = RootShell.run("cmd overlay list $TARGET | grep -F '$ID'; cmd overlay dump $ID | grep -F 'dimen/'").output
            if (listed.contains("[x] $ID") && listed.contains(CAPTION_DUMP) && HANDLES.all { listed.contains("dimen/$it)") }) {
                Log.i(TAG, "system caption already off")
                return@Thread
            }
            val r = RootShell.run("CLASSPATH=$apk app_process /system/bin ${OemCaption::class.java.name} && cmd overlay enable $ID")
            Log.i(TAG, "system caption off: rc ${r.code} ${r.output.takeLast(300)}")
        }, "oem-caption").start()
    }

    /** Root, from app_process: registers the overlay (caption [CAPTION_PX] px, [HANDLES] 0 dp), owned by the shell. */
    @JvmStatic
    fun main(args: Array<String>) {
        val fo = Class.forName("android.content.om.FabricatedOverlay")
        val overlay = fo.getConstructor(String::class.java, String::class.java).newInstance(NAME, TARGET)
        fo.getMethod("setOwningPackage", String::class.java).invoke(overlay, "com.android.shell")
        val set = fo.getMethod("setResourceValue", String::class.java, Float::class.javaPrimitiveType, Int::class.javaPrimitiveType, String::class.java)
        set.invoke(overlay, "$TARGET:dimen/freeform_decor_caption_height", CAPTION_PX.toFloat(), 0 /* TypedValue.COMPLEX_UNIT_PX */, null)
        for (name in HANDLES) {
            set.invoke(overlay, "$TARGET:dimen/$name", 0f, 1 /* TypedValue.COMPLEX_UNIT_DIP */, null)
        }
        val tx = Class.forName("android.content.om.OverlayManagerTransaction")
        val transaction = tx.getMethod("newInstance").invoke(null)
        tx.getMethod("registerFabricatedOverlay", fo).invoke(transaction, overlay)
        val binder = Class.forName("android.os.ServiceManager").getMethod("getService", String::class.java).invoke(null, "overlay") as IBinder
        val om = Class.forName("android.content.om.IOverlayManager\$Stub").getMethod("asInterface", IBinder::class.java).invoke(null, binder)!!
        om.javaClass.getMethod("commit", tx).invoke(om, transaction)
        println("registered $ID")
    }
}
