package dev.omalauncher.shell

import android.content.Context
import android.graphics.PixelFormat
import android.os.Build
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.WindowManager
import andro.marchy.GamepadOverlay
import andro.marchy.DirWatch
import andro.marchy.SessionService
import android.os.FileObserver
import java.io.File

/**
 * The control-center pad belongs above windows, independently of the Linux display activity.
 *
 * Its on/off is the user's, kept on disk ([PREFS]) and put back when the app starts again ([restore]): it used to live
 * only in this process, so every app restart (an update, a crash, the session's restart) took the controls off a
 * running game with nothing saying so. 11-06 14:12 Broforce: the 13:59 update ended the process, the tile's overlay
 * was gone and nothing brought it back (the per-game set, PadApps, is emptied when the tile turns on); the game sat on
 * its "press any button" title, which touches don't pass, and the user said "basically frozen" - padd got no press
 * from 14:08:35 until 14:12:45, the first one seated the pad in Steam and play went on (~100 presses a minute).
 */
object ControllerPad {
    private const val TAG = "ControllerPad"
    private const val PREFS = "powos_controller_pad"
    private const val KEY_ON = "on"
    private var view: GamepadOverlay? = null
    private var manager: WindowManager? = null
    private var focus: DirWatch.Handle? = null

    fun shown(): Boolean = view?.parent != null

    /** What the user last set on the tile (on disk: survives the process). */
    fun saved(context: Context): Boolean =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_ON, false)

    /** Whether [restore] puts the overlay back: the user left it on, it isn't up, and it can be drawn. */
    internal fun restoreWanted(saved: Boolean, shown: Boolean, canDraw: Boolean, sdk: Int): Boolean =
        saved && !shown && canDraw && sdk >= 33

    /**
     * The app (re)started (the home page's host is made): the overlay comes back as the user left it. Never turns it
     * off, never asks for the overlay permission (the tile does that).
     */
    fun restore(context: Context) {
        val want = restoreWanted(saved(context), shown(), Settings.canDrawOverlays(context), Build.VERSION.SDK_INT)
        if (!want) return
        runCatching { show(context, true) }
            .onSuccess { Log.i(TAG, "controller overlay restored (left on by the user)") }
            .onFailure { Log.w(TAG, "controller overlay not restored", it) }
    }

    fun show(context: Context, on: Boolean): Boolean {
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(KEY_ON, on).apply()
        Log.i(TAG, "controller overlay " + if (on) "on" else "off")
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
