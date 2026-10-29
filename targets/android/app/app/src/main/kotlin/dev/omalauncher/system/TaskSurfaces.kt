package dev.omalauncher.system

import android.app.ActivityManager
import android.content.Context
import android.graphics.Point
import android.graphics.Rect
import android.hardware.display.DisplayManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Display
import android.view.SurfaceControl
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Every desktop window's surface: task id -> the task's SurfaceControl (its leash), as WM Shell hands it to PowOS in a
 * transition (docs/DESKTOP-NATIVE.md, "Desktop windows inside the web shell", step 2). Fed by every [TaskLeash] session
 * (a drag, maximise, page slide: a task's first move records it) and by TaskLeash's permanent open remote (a freeform
 * task opened or brought to front). An entry goes when its task does (FreeformTasks.listen), when its surface is no
 * longer valid, and all of them on a display change or fold (the next open/move records them again).
 *
 * The in-task frames (step 4) parent their SurfaceControlViewHost under [get]; [listen] says when one comes or goes.
 * Thread-safe; listeners run on the main thread.
 */
object TaskSurfaces {
    private const val TAG = "PowosTaskSurfaces"

    private val surfaces = ConcurrentHashMap<Int, SurfaceControl>()
    private val listeners = CopyOnWriteArrayList<(Int, SurfaceControl?) -> Unit>()
    private val main = Handler(Looper.getMainLooper())

    @Volatile private var app: Context? = null
    private var stopTasks: (() -> Unit)? = null
    private var screen: String? = null

    /** Task [id]'s surface, or null: not seen in a transition yet (or dropped since). */
    fun get(id: Int): SurfaceControl? = surfaces[id]?.takeIf { it.isValid }

    /**
     * Task [ids]' surfaces shown ([on]) or hidden in [t] (the caller applies it): a window of a page off the screen
     * stays a live, drawn task above home - only its leash is hidden, so the app keeps its buffer and is there at once
     * when its page returns (reordered under home it stopped, dropped its buffer and came back blank until touched).
     * Returns the ids PowOS holds no surface of (the caller falls back to WM: minimise / raise).
     */
    fun show(
        t: SurfaceControl.Transaction,
        ids: Collection<Int>,
        on: Boolean,
    ): Set<Int> =
        ids.filterTo(mutableSetOf()) { id ->
            val leash = get(id) ?: return@filterTo true
            hide(t, leash, !on)
            if (on) hiddenLeashes.remove(id) else hiddenLeashes.add(id)
            false
        }.also { none -> if (ids.isNotEmpty()) Log.i(TAG, "${if (on) "shown" else "hidden"} ${ids - none}, no leash $none") }

    /**
     * Task leash [leash] hidden ([off]) or shown in [t]: the picture only, at once. Out of touch and kept hidden is
     * WM's job - the caller also hides the task in WM (FreeformTasks.away, PageSlide's finish: WCT.setHidden), so its
     * input windows are NOT_VISIBLE and WM Shell's decor, which re-shows a VISIBLE task's surface on each relayout,
     * hides it instead. Shown sets alpha 1 too: builds before WM hiding left alpha 0 on hidden leashes.
     */
    fun hide(
        t: SurfaceControl.Transaction,
        leash: SurfaceControl,
        off: Boolean,
    ) {
        t.setVisibility(leash, !off)
        if (!off) t.setAlpha(leash, 1f)
    }

    /** Tasks whose leash PowOS hid ([show] false): shown again before PowOS lets go of the leash ([dropAll], [undress]). */
    private val hiddenLeashes = ConcurrentHashMap.newKeySet<Int>()

    /** The task ids PowOS holds a surface of. */
    fun ids(): Set<Int> = surfaces.keys.toSet()

    /** Calls [changed] (main thread) with a task id and its new surface, or null when it was dropped; a handle to stop. */
    fun listen(changed: (Int, SurfaceControl?) -> Unit): () -> Unit {
        listeners.add(changed)
        return { listeners.remove(changed) }
    }

    /**
     * Starts dropping entries as tasks vanish and on display changes; idempotent (PowosRecentsService, once SystemUI
     * connects). Without it entries still come and go by [record] and an invalid surface reads as none.
     */
    fun start(context: Context) {
        main.post {
            if (app != null) return@post
            val c = context.applicationContext
            app = c
            stopTasks = FreeformTasks.listen { prune() }
            dressLeashes(c)
            val dm = c.getSystemService(DisplayManager::class.java)
            screen = screenKey(dm)
            dm.registerDisplayListener(
                object : DisplayManager.DisplayListener {
                    override fun onDisplayAdded(displayId: Int) {}

                    override fun onDisplayRemoved(displayId: Int) {}

                    override fun onDisplayChanged(displayId: Int) {
                        if (displayId != Display.DEFAULT_DISPLAY) return
                        val now = screenKey(dm)
                        if (now == screen) return
                        Log.i(TAG, "display changed ($screen -> $now): all shown, undressed and dropped")
                        screen = now
                        // A fold makes every window full screen: a leash PowOS hid (its page off the screen) or cropped
                        // to its window size must not stay so once PowOS forgets it - Chrome came back on the cover as
                        // an empty surface (hidden leash, nothing ever showed it again). The unfold's next open/move
                        // records the leashes again and the window look comes back with them.
                        releaseAll()
                        dropAll("display change")
                    }
                },
                main,
            )
            Log.i(TAG, "watching tasks and the display")
        }
    }

    /** The leashes a transition handed over ([from]: which one, for the log). */
    fun record(
        leashes: Map<Int, SurfaceControl>,
        from: String,
    ) {
        for ((id, leash) in leashes) {
            if (!leash.isValid) continue
            val old = surfaces.put(id, leash)
            if (old === leash) continue // (SurfaceControl.isSameSurface is @hide: a re-handed copy of the same leash logs again)
            Log.i(TAG, "registered task $id ($from)${if (old != null) ", replaced" else ""}")
            say(id, leash)
        }
    }

    /** Task [id]'s entry gone ([why]: for the log). */
    fun drop(
        id: Int,
        why: String,
    ) {
        if (surfaces.remove(id) == null) return
        sizes.remove(id)
        hiddenLeashes.remove(id)
        Log.i(TAG, "dropped task $id ($why)")
        say(id, null)
    }

    /** Every held leash shown, uncropped, square and without shadow: as WM left it before PowOS touched it. */
    private fun releaseAll() {
        if (surfaces.isEmpty()) return
        runCatching {
            val t = SurfaceControl.Transaction()
            for ((id, leash) in surfaces) if (leash.isValid) plain(t, id, leash)
            t.apply()
        }.onFailure { Log.w(TAG, "can't release the leashes", it) }
    }

    /** Leash [leash] of task [id] back to WM's own state in [t]: shown, no crop, no corners or shadow. */
    private fun plain(
        t: SurfaceControl.Transaction,
        id: Int,
        leash: SurfaceControl,
    ) {
        if (hiddenLeashes.remove(id)) Log.i(TAG, "task $id: hidden leash shown again")
        hide(t, leash, false)
        t.setCrop(leash, null)
        runCatching {
            cornerRadius?.invoke(t, leash, 0f)
            shadowRadius?.invoke(t, leash, 0f)
        }
    }

    private fun dropAll(why: String) {
        for (id in surfaces.keys.toList()) drop(id, why)
    }

    /** Binder thread (the task stack listener): entries whose task is gone or whose surface died go. */
    private fun prune() {
        if (surfaces.isEmpty()) return
        val c = app ?: return
        val running =
            runCatching {
                @Suppress("DEPRECATION")
                c.getSystemService(ActivityManager::class.java).getRunningTasks(MAX_TASKS).map { it.taskId }.toSet()
            }.onFailure { Log.w(TAG, "can't list tasks", it) }.getOrNull() ?: return
        for ((id, leash) in surfaces.entries.toList()) {
            when {
                id !in running -> drop(id, "task gone")
                !leash.isValid -> drop(id, "surface released")
            }
        }
    }

    private fun say(
        id: Int,
        surface: SurfaceControl?,
    ) {
        if (listeners.isEmpty()) return
        main.post { for (l in listeners) runCatching { l(id, surface) }.onFailure { Log.w(TAG, "a listener failed", it) } }
    }

    /** Every leash that comes gets PowOS's window look at once (the size known by then, else at the next [dress]). */
    private fun dressLeashes(c: Context) {
        density = c.resources.displayMetrics.density
        // Only a window WindowFrames dressed ([sizes]) gets the look: a leash recorded for any other task (full screen,
        // a fixed-size app in OnePlus's compat box) stays exactly as WM left it - no crop, corners or shadow.
        listen { id, leash ->
            if (leash == null) return@listen
            if (sizes.containsKey(id)) look(id, leash, on = true) else Log.i(TAG, "task $id: not a PowOS window, its surface left as WM placed it")
        }
    }

    /** Task id -> the window's size (px) last [dress]ed: the crop its rounded corners are cut at. */
    private val sizes = ConcurrentHashMap<Int, Point>()

    /** Tasks shown full screen ([undress]): no corners, no shadow until [dress]ed again. */
    private val bare = ConcurrentHashMap.newKeySet<Int>()

    @Volatile private var density = 1f

    /**
     * One PowOS look on desktop window [id] at [bounds] (screen px): the shell's window radius (`--radius`,
     * shell/theme.css) and a soft shadow on its leash. Cheap and idempotent: WindowFrames calls it on every refresh, so a
     * resize re-cuts the crop and a re-handed leash is dressed again. Main thread.
     */
    fun dress(
        id: Int,
        bounds: Rect,
    ) {
        if (bounds.isEmpty) return
        sizes[id] = Point(bounds.width(), bounds.height())
        bare.remove(id)
        get(id)?.let { look(id, it, on = true) }
    }

    /**
     * Task [id] full screen: square corners, no shadow, no crop - and shown, if PowOS had hidden its leash (a window of
     * a page off the screen going full screen must not stay invisible) (FreeformTasks.setFullScreen).
     */
    /** Tasks wearing PowOS's window look now ([dress]). */
    fun dressed(): Set<Int> = sizes.keys.toSet()

    fun undress(id: Int) {
        bare.add(id)
        sizes.remove(id)
        val leash = get(id) ?: return
        runCatching { SurfaceControl.Transaction().also { plain(it, id, leash) }.apply() }
            .onFailure { Log.w(TAG, "task $id: can't undress", it) }
    }

    /**
     * HACK: SurfaceControl.Transaction.setCornerRadius / setShadowRadius are hidden (WM Shell's desktop mode makes the
     * same calls on its task leashes); reflected, and skipped for good where they aren't there. The corners are cut at a
     * crop of the window's last known size, re-set on every WindowFrames refresh - a live resize may show the old crop
     * for a frame. Real fix: none for an app (WM Shell's own desktop decor would do it, which PowOS replaces).
     */
    private fun look(
        id: Int,
        leash: SurfaceControl,
        on: Boolean,
    ) {
        if (!leash.isValid) return
        val radius = if (on) WINDOW_RADIUS_DP * density else 0f
        val shadow = if (on) WINDOW_SHADOW_DP * density else 0f
        val size = sizes[id]
        runCatching {
            val t = SurfaceControl.Transaction()
            if (on && size != null) t.setCrop(leash, Rect(0, 0, size.x, size.y)) else if (!on) t.setCrop(leash, null)
            cornerRadius?.invoke(t, leash, radius)
            shadowRadius?.invoke(t, leash, shadow)
            t.apply()
        }.onFailure {
            Log.w(TAG, "no window look for task $id", it)
            cornerRadius = null
            shadowRadius = null
        }
    }

    private var cornerRadius: java.lang.reflect.Method? = hidden("setCornerRadius")
    private var shadowRadius: java.lang.reflect.Method? = hidden("setShadowRadius")

    private fun hidden(name: String): java.lang.reflect.Method? =
        runCatching {
            HiddenApi.allow()
            SurfaceControl.Transaction::class.java.getMethod(name, SurfaceControl::class.java, Float::class.javaPrimitiveType)
        }.onFailure { Log.w(TAG, "no Transaction.$name", it) }.getOrNull()

    /** The shell's window radius (shell/theme.css `--radius: 12px`, CSS px = dp). */
    private const val WINDOW_RADIUS_DP = 12f

    /** A soft shadow, as the shell's lifted panels. */
    private const val WINDOW_SHADOW_DP = 18f

    /** Size + rotation of the main display: a fold swaps the panel behind display 0, a rotation turns it. */
    private fun screenKey(dm: DisplayManager): String {
        val d = dm.getDisplay(Display.DEFAULT_DISPLAY) ?: return ""
        val p = Point()
        @Suppress("DEPRECATION")
        d.getRealSize(p)
        return "${p.x}x${p.y}@${d.rotation}"
    }

    /** Enough to list every desktop window (a task past it would be dropped wrongly, so it is generous). */
    private const val MAX_TASKS = 64
}
