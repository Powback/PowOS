package dev.omalauncher.shell

import android.app.ActivityOptions
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import android.view.InputDevice
import android.view.InputEvent
import android.view.MotionEvent
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import org.json.JSONObject

/**
 * Web windows: an Android app's window as an element of PowOS home (unfolded, `Settings.Global powos_web_windows` = 1;
 * off by default).
 *
 * Why - the user, 2026-10-29: "its because we arent doing it natively inside powos. like the powos home typescript
 * should deal with the windows and their content", "it should be pinned to a page properly natively", "idk why you do
 * this overlay shit". So the window is home's: its position, size, page, z-order and title bar are DOM and state in the
 * page (shell/ui/webwindows.tsx); only its content is the app's.
 *
 * How: one private VirtualDisplay per window (as AppWidgets.kt hosts a widget, and as DeX / scrcpy --new-display host
 * apps), launched into with ActivityOptions.setLaunchDisplayId (root `am start --display` if that's refused). Its
 * surface is a SurfaceView's that is a child of home's own view hierarchy, BEHIND the home WebView: the WebView is
 * transparent there (the window's body is an unpainted hole in the DOM), so the app shows exactly where the element is
 * and anything home paints over the element (the drawer, a panel, another window's title bar) covers it, as DOM does.
 * The page reports the element's screen rect every animation frame it changes ("webwindows.place"), so the content
 * follows a page swipe, a drag and a resize; a new size resizes the display in place.
 *
 * Input: the page owns the touches over the hole (they reach the WebView first, it is on top) and forwards them
 * ("webwindows.input"); they are injected on the window's display - InputManager.injectInputEvent through reflection
 * with MotionEvent.setDisplayId, else root `input -d <id> motionevent` (each logged once as "input path").
 * Keyboard: the display's IME policy is set to the default display (WindowManagerService.setDisplayImePolicy, by
 * reflection; logged).
 *
 * HACK: the root `input` fallback spawns a process per event (moves coalesced): taps work, drags are coarse. Real fix:
 * hold INJECT_EVENTS (privapp allow-list in the image) so the reflective injection path is always the one used.
 * HACK: z-order between two windows' surfaces is only two levels (setZOrderMediaOverlay on the top one). Real fix:
 * order the SurfaceViews' SurfaceControls relative to each other (SurfaceControl.Transaction.setRelativeLayer).
 * Not yet: the app finishing its task on the display does not emit "webwindows.closed" (only close() and a display
 * removed do) - real fix: a TaskStackListener watching the windows' display ids.
 *
 * Doesn't touch the freeform windows (system/WindowFrames.kt): with the setting off nothing here runs.
 */
class WebWindows(
    private val context: Context,
    private val web: WebView,
    private val emit: (String, Any?) -> Unit,
) {
    private val main = Handler(Looper.getMainLooper())
    private val dm = context.getSystemService(DisplayManager::class.java)
    private val wins = LinkedHashMap<Int, Win>()
    private var nextId = 1
    private var lastPlaceLog = 0L
    private val io by lazy { Handler(HandlerThread("powos-webwindows").apply { start() }.looper) }

    /** Off unless `settings put global powos_web_windows 1`. */
    fun enabled(): Boolean = runCatching { Settings.Global.getInt(context.contentResolver, SETTING, 0) == 1 }.getOrDefault(false)

    private val displayListener =
        object : DisplayManager.DisplayListener {
            override fun onDisplayAdded(displayId: Int) {}

            override fun onDisplayChanged(displayId: Int) {}

            override fun onDisplayRemoved(displayId: Int) {
                wins.values.firstOrNull { it.displayId == displayId }?.let { w ->
                    Log.i(TAG, "display $displayId removed: window ${w.id} closed")
                    drop(w)
                }
            }
        }

    init {
        runCatching { dm.registerDisplayListener(displayListener, main) }
    }

    private fun density() = context.resources.displayMetrics.density

    /** A page rect (CSS px, the WebView's viewport) in the WebView's parent (px). */
    private fun parentRect(o: JSONObject): android.graphics.Rect {
        val d = density()
        val l = (o.optDouble("left") * d).toInt() + web.left
        val t = (o.optDouble("top") * d).toInt() + web.top
        val w = (o.optDouble("width") * d).toInt().coerceAtLeast(1)
        val h = (o.optDouble("height") * d).toInt().coerceAtLeast(1)
        return android.graphics.Rect(l, t, l + w, t + h)
    }

    /** A window for [component] at [rect] (CSS px): its id, or -1 (setting off, no parent to host it, no display). */
    fun open(
        component: ComponentName,
        rect: JSONObject,
    ): Int {
        if (!enabled()) return -1.also { Log.w(TAG, "open ${component.packageName}: $SETTING is off") }
        val parent = web.parent as? ViewGroup ?: return -1.also { Log.w(TAG, "open: the WebView has no parent to host a surface") }
        val r = parentRect(rect)
        val win =
            runCatching { Win(nextId++, component, r.width(), r.height()) }.getOrElse {
                Log.w(TAG, "open ${component.packageName}: no virtual display", it)
                return -1
            }
        wins[win.id] = win
        // Behind the WebView: the page's transparent hole shows it, whatever the page paints over it covers it.
        parent.addView(win.view, parent.indexOfChild(web).coerceAtLeast(0), ViewGroup.LayoutParams(r.width(), r.height()))
        win.view.x = r.left.toFloat()
        win.view.y = r.top.toFloat()
        imePolicy(win.displayId)
        launch(win)
        raise(win.id)
        return win.id
    }

    /** The element moved, resized, or went out of (or back into) sight. */
    fun place(
        id: Int,
        rect: JSONObject,
        visible: Boolean,
    ): Boolean {
        val w = wins[id] ?: return false
        val r = parentRect(rect)
        w.view.x = r.left.toFloat()
        w.view.y = r.top.toFloat()
        if (r.width() != w.w || r.height() != w.h) {
            w.w = r.width()
            w.h = r.height()
            w.view.layoutParams = w.view.layoutParams.apply {
                width = w.w
                height = w.h
            }
            runCatching { w.display.resize(w.w, w.h, dpi) }.onFailure { Log.w(TAG, "resize $id failed", it) }
        }
        val vis = if (visible) View.VISIBLE else View.INVISIBLE
        if (w.view.visibility != vis) w.view.visibility = vis
        val now = SystemClock.uptimeMillis()
        if (now - lastPlaceLog > PLACE_LOG_MS) {
            lastPlaceLog = now
            Log.i(TAG, "place $id display ${w.displayId} at $r visible=$visible")
        }
        return true
    }

    /** On top of the other windows (home's z-order: the page raised its element). */
    fun raise(id: Int): Boolean {
        if (id !in wins) return false
        // HACK: two levels only (see the class note).
        wins.values.forEach { runCatching { it.view.setZOrderMediaOverlay(it.id == id) } }
        return true
    }

    /** A touch on the element's body (CSS px from its top-left): injected on its display. */
    fun input(
        id: Int,
        action: String,
        x: Double,
        y: Double,
    ): Boolean {
        val w = wins[id] ?: return false
        val d = density()
        val px = (x * d).toFloat()
        val py = (y * d).toFloat()
        val act =
            when (action) {
                "down" -> MotionEvent.ACTION_DOWN
                "move" -> MotionEvent.ACTION_MOVE
                "up" -> MotionEvent.ACTION_UP
                else -> MotionEvent.ACTION_CANCEL
            }
        val now = SystemClock.uptimeMillis()
        if (act == MotionEvent.ACTION_DOWN) w.downAt = now
        if (injectWorks != false && injectReflect(w.displayId, w.downAt, now, act, px, py)) {
            if (injectWorks == null) Log.i(TAG, "input path: InputManager.injectInputEvent (reflection, setDisplayId)").also { injectWorks = true }
            return true
        }
        if (injectWorks != false) Log.i(TAG, "input path: root `input -d <id> motionevent` (reflection refused)").also { injectWorks = false }
        injectRoot(w.displayId, act, px, py)
        return true
    }

    /** Gone: its display released (its task with it), "webwindows.closed" for the page. */
    fun close(id: Int): Boolean {
        val w = wins[id] ?: return false
        drop(w)
        return true
    }

    fun closeAll() {
        wins.values.toList().forEach(::drop)
        runCatching { dm.unregisterDisplayListener(displayListener) }
    }

    private fun drop(w: Win) {
        if (wins.remove(w.id) == null) return
        (w.view.parent as? ViewGroup)?.removeView(w.view)
        runCatching { w.display.release() }
        Log.i(TAG, "closed window ${w.id} (display ${w.displayId}, ${w.component.packageName})")
        emit("webwindows.closed", w.id)
    }

    private val dpi get() = context.resources.displayMetrics.densityDpi

    /** One window: its display, and the SurfaceView in home's hierarchy whose surface the display draws into. */
    private inner class Win(
        val id: Int,
        val component: ComponentName,
        var w: Int,
        var h: Int,
    ) : SurfaceHolder.Callback {
        val view = SurfaceView(context)
        val display: VirtualDisplay =
            dm.createVirtualDisplay("powos-webwindow-$id", w, h, dpi, null, FLAGS)
                ?: throw IllegalStateException("createVirtualDisplay returned null")
        val displayId: Int = display.display.displayId
        var downAt = 0L

        init {
            view.holder.addCallback(this)
            Log.i(TAG, "created display $displayId ${w}x$h dpi $dpi for window $id (${component.packageName})")
        }

        override fun surfaceCreated(holder: SurfaceHolder) {
            display.surface = holder.surface
        }

        override fun surfaceChanged(
            holder: SurfaceHolder,
            format: Int,
            width: Int,
            height: Int,
        ) {
            display.surface = holder.surface
        }

        override fun surfaceDestroyed(holder: SurfaceHolder) {
            display.surface = null
        }
    }

    private fun launch(w: Win) {
        val intent =
            Intent(Intent.ACTION_MAIN)
                .addCategory(Intent.CATEGORY_LAUNCHER)
                .setComponent(w.component)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            val opts = ActivityOptions.makeBasic().setLaunchDisplayId(w.displayId)
            context.startActivity(intent, opts.toBundle())
            Log.i(TAG, "launched ${w.component.flattenToShortString()} on display ${w.displayId} (ActivityOptions)")
        } catch (e: Exception) {
            Log.w(TAG, "ActivityOptions launch on display ${w.displayId} refused: ${e.message}; trying root am start")
            io.post {
                val r = runCatching { andro.marchy.RootShell.run("am start --display ${w.displayId} -f 0x10000000 -n ${w.component.flattenToShortString()}") }.getOrNull()
                Log.i(TAG, "launched ${w.component.flattenToShortString()} on display ${w.displayId} (root am start): code ${r?.code} ${r?.output?.take(200)}")
            }
        }
    }

    /** The keyboard for this display shows on the default display (DISPLAY_IME_POLICY_FALLBACK_DISPLAY). */
    private fun imePolicy(displayId: Int) {
        val result =
            runCatching {
                val wms = Class.forName("android.view.WindowManagerGlobal").getMethod("getWindowManagerService").invoke(null)!!
                wms.javaClass.getMethod("setDisplayImePolicy", Int::class.javaPrimitiveType, Int::class.javaPrimitiveType).invoke(wms, displayId, IME_POLICY_FALLBACK_DISPLAY)
            }
        if (result.isSuccess) Log.i(TAG, "IME policy of display $displayId: fallback to default display (ok)")
        else Log.w(TAG, "IME policy of display $displayId not set: ${result.exceptionOrNull()?.let { it.cause ?: it }}")
    }

    // null: not tried yet; false: refused once, root from then on.
    private var injectWorks: Boolean? = null
    private val injectMethod by lazy {
        runCatching { android.hardware.input.InputManager::class.java.getMethod("injectInputEvent", InputEvent::class.java, Int::class.javaPrimitiveType) }.getOrNull()
    }
    private val setDisplayId by lazy { runCatching { MotionEvent::class.java.getMethod("setDisplayId", Int::class.javaPrimitiveType) }.getOrNull() }

    private fun injectReflect(
        displayId: Int,
        downAt: Long,
        now: Long,
        action: Int,
        x: Float,
        y: Float,
    ): Boolean {
        val inject = injectMethod ?: return false
        val setId = setDisplayId ?: return false
        val ev = MotionEvent.obtain(downAt, now, action, x, y, 0)
        return try {
            ev.source = InputDevice.SOURCE_TOUCHSCREEN
            setId.invoke(ev, displayId)
            val im = context.getSystemService(android.hardware.input.InputManager::class.java)
            inject.invoke(im, ev, 0) as? Boolean ?: false // INJECT_INPUT_EVENT_MODE_ASYNC
        } catch (e: Exception) {
            Log.w(TAG, "injectInputEvent refused: ${(e.cause ?: e)}")
            false
        } finally {
            ev.recycle()
        }
    }

    // Root fallback: moves coalesced to the latest, downs and ups in order.
    private val moveLock = Any()
    private var pendingMove: String? = null

    private fun injectRoot(
        displayId: Int,
        action: Int,
        x: Float,
        y: Float,
    ) {
        val verb =
            when (action) {
                MotionEvent.ACTION_DOWN -> "DOWN"
                MotionEvent.ACTION_MOVE -> "MOVE"
                MotionEvent.ACTION_UP -> "UP"
                else -> "CANCEL"
            }
        val cmd = "input -d $displayId touchscreen motionevent $verb ${x.toInt()} ${y.toInt()}"
        if (action == MotionEvent.ACTION_MOVE) {
            val queued = synchronized(moveLock) { (pendingMove != null).also { pendingMove = cmd } }
            if (queued) return
            io.post {
                val c = synchronized(moveLock) { pendingMove.also { pendingMove = null } }
                if (c != null) runCatching { andro.marchy.RootShell.run(c) }
            }
            return
        }
        io.post { runCatching { andro.marchy.RootShell.run(cmd) }.onFailure { Log.w(TAG, "root input failed", it) } }
    }

    companion object {
        private const val TAG = "PowosWebWindows"
        const val SETTING = "powos_web_windows"
        private const val PLACE_LOG_MS = 1000L
        private const val IME_POLICY_FALLBACK_DISPLAY = 1

        // VIRTUAL_DISPLAY_FLAG_DESTROY_CONTENT_ON_REMOVAL (@hide, 1 shl 8): closing the window ends its task instead of
        // Android moving it onto the main screen.
        private const val FLAG_DESTROY_CONTENT_ON_REMOVAL = 1 shl 8
        private const val FLAGS =
            DisplayManager.VIRTUAL_DISPLAY_FLAG_PUBLIC or DisplayManager.VIRTUAL_DISPLAY_FLAG_OWN_CONTENT_ONLY or FLAG_DESTROY_CONTENT_ON_REMOVAL
    }
}
