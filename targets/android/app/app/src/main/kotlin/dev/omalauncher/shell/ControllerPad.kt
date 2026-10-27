package dev.omalauncher.shell

import android.content.Context
import android.graphics.PixelFormat
import android.os.Build
import android.provider.Settings
import android.view.Gravity
import android.view.WindowManager
import andro.marchy.GamepadOverlay
import andro.marchy.DirWatch
import andro.marchy.SessionService
import android.os.FileObserver
import java.io.File

/** The control-center pad belongs above windows, independently of the Linux display activity. */
object ControllerPad {
    private var view: GamepadOverlay? = null
    private var manager: WindowManager? = null
    private var focus: DirWatch.Handle? = null

    fun shown(): Boolean = view?.parent != null

    fun show(context: Context, on: Boolean): Boolean {
        if (!on) {
            focus?.stop()
            focus = null
            view?.setShown(false)
            view?.let { manager?.removeViewImmediate(it) }
            view = null
            manager = null
            return false
        }
        if (shown()) return true
        check(Settings.canDrawOverlays(context)) { "Allow PowOS to display over other apps first" }
        check(Build.VERSION.SDK_INT >= 33) { "Controller overlay requires Android 13 or newer" }
        val ctx = context.createWindowContext(WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY, null)
        val wm = ctx.getSystemService(WindowManager::class.java)
        val pad = GamepadOverlay(ctx, "@powos.padd")
        pad.setFloating(true)
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.LEFT
            title = "PowOS controller"
        }
        wm.addView(pad, params)
        andro.marchy.MainActivity.padShow(context, false)
        manager = wm
        view = pad
        watchGame(context, pad)
        return shown()
    }

    private fun watchGame(context: Context, pad: GamepadOverlay) {
        val file = File(SessionService.runDir(context), "focused-window")
        fun update() = pad.setGame(runCatching { file.readText().trim() }.getOrDefault(""))
        update()
        focus = DirWatch.watch(file.parentFile, FileObserver.CLOSE_WRITE or FileObserver.MOVED_TO) { _, path ->
            if (path == file.name) pad.post { update() }
        }
    }

    fun edit(): Boolean {
        val pad = view ?: return false
        pad.setEditing(true)
        return true
    }

    fun covers(x: Float, y: Float): Boolean {
        val pad = view ?: return false
        val at = IntArray(2)
        pad.getLocationOnScreen(at)
        return pad.controlRegion().contains(x.toInt() - at[0], y.toInt() - at[1])
    }
}
