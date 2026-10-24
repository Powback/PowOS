package dev.omalauncher.system

import android.content.Context
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.Choreographer
import android.view.SurfaceControl

/**
 * Floating windows slide with home's page, frame by frame (unfolded home: every window belongs to a page, like a
 * widget; shell ui/desktops.ts). At a page swipe's start home sends the windows of the page on screen and of its
 * neighbours (task id -> page offset -1/0/1) and the page's width; one [TaskLeash] session takes all their surfaces;
 * each move puts every window at its bounds + offset * width + the track's offset ([move], from the page's finger),
 * the settle runs the page track's own curve here, frame by frame ([settle]: its duration and cubic-bezier, read from
 * the track's CSS transition). Their title bars and grips (their own overlay windows, [WindowFrame]) move in the same
 * transaction. At the end the transition finishes with every window at its real bounds: the ones the page left behind
 * hidden there (their leash hidden, as WM hides an invisible task - nothing is parked off the screen; the next open
 * transition shows it where it belongs) and the page change committed as before ([WindowFrames.desktop]: minimised /
 * raised), after the slide has landed instead of during it.
 *
 * Why not the old way: the page change minimised and raised windows (binder calls and two WM transitions per window)
 * on the main thread the moment the finger let go - the thread home's WebView draws on - so the settle stuttered and
 * the windows popped in/out at the end instead of moving (the user, 2026-10-23/24, three times).
 *
 * Logcat PowosPageSlide: start (windows, offsets), how many frames moved, the end. Main thread only.
 */
object PageSlide {
    private const val TAG = "PowosPageSlide"
    private val main = Handler(Looper.getMainLooper())

    private class Win(val id: Int, val rel: Int, val bounds: Rect, val task: FreeformTasks.Window)

    private var session: TaskLeash.Session? = null
    private var context: Context? = null
    private var wins: List<Win> = emptyList()
    private var width = 0
    private var x = 0f
    private var frames = 0
    private var startedAt = 0L

    // The settle: from [fromX] to [toX] over [ms], on the track's curve; [hide] committed when it lands.
    private var fromX = 0f
    private var toX = 0f
    private var ms = 0L
    private var curve = floatArrayOf(0.2f, 0.9f, 0.3f, 1f)
    private var settleAt = 0L
    private var hide: Set<Int>? = null

    val active get() = session != null

    /** Home's "windows.slide" (ui/desktops.ts): start {rels, width, x} | move x | settle {to, ms, curve, hide} | cancel; CSS px * [d]. */
    fun call(
        context: Context,
        a: org.json.JSONArray,
        d: Float,
    ): Boolean =
        when (a.getString(0)) {
            "start" -> start(context, a.getJSONObject(1), d)
            "move" ->
                true.also {
                    val m = a.optJSONObject(1)
                    m?.let { sent(it.optLong("t")) }
                    move(((m?.getDouble("x") ?: a.getDouble(1)) * d).toFloat())
                }
            "settle" -> true.also { settle(a.getJSONObject(1), d) }
            else -> true.also { cancel("home") }
        }

    private fun start(
        context: Context,
        o: org.json.JSONObject,
        d: Float,
    ): Boolean {
        val r = o.getJSONObject("rels")
        val rels = r.keys().asSequence().associate { it.toInt() to r.getInt(it) }
        return start(context, rels, (o.getDouble("width") * d).toInt(), (o.getDouble("x") * d).toFloat())
    }

    private fun settle(
        o: org.json.JSONObject,
        d: Float,
    ) {
        val c = o.optJSONArray("curve")?.let { j -> FloatArray(j.length()) { j.getDouble(it).toFloat() } }
        val h = o.optJSONArray("hide")
        val hide = (0 until (h?.length() ?: 0)).map { h!!.getInt(it) }.toSet()
        startedAtHome = o.optLong("at")
        settle((o.getDouble("to") * d).toFloat(), o.optLong("ms", 280), c, hide)
    }

    // Evidence for the lag (logged at the end): how late home's moves come (its Date.now() at the move vs ours), how
    // long the leashes took (the windows stand still until then), how late the settle's message came.
    private var lateSum = 0L
    private var lateMax = 0L
    private var lateN = 0
    private var readyAfter = -1L
    private var settleLate = -1L

    /** Home's Date.now() when its track's settle began (0: not given), for the next [settle]. */
    private var startedAtHome = 0L

    private fun sent(t: Long) {
        if (t <= 0) return
        val late = (System.currentTimeMillis() - t).coerceAtLeast(0)
        lateSum += late
        lateN++
        if (late > lateMax) lateMax = late
    }

    /**
     * A page swipe started: [rels] (task id -> its page's offset from the page on screen: -1, 0, 1), the page [w]idth
     * and the track's offset [x0] (screen px). False: nothing to slide (no window on these pages, folded, no leash).
     */
    fun start(
        context: Context,
        rels: Map<Int, Int>,
        w: Int,
        x0: Float,
    ): Boolean {
        landNow()
        cancel("a new slide")
        if (!AppWindows.floating(context) || !TaskLeash.enabled(context) || w <= 0) return false
        val list = slideWins(context, rels)
        if (list.isNullOrEmpty()) return false
        reset(context, list, w, x0)
        if (!begin(context, list)) {
            wins = emptyList()
            return false
        }
        // Their bars and grips (WindowFrames): framed for the slide, moved in [draw]'s transaction.
        WindowFrames.current?.slideStart(list.map { it.task })
        Log.i(TAG, "start: ${list.joinToString { "${it.id}${if (it.rel != 0) "@${it.rel}" else ""}" }} width $w x $x")
        return true
    }

    /** A finger down again mid-settle: that one lands at once (its change committed), the new one starts from there. */
    private fun landNow() {
        if (session == null || settleAt == 0L) return
        x = toX
        draw()
        land()
    }

    private fun reset(
        context: Context,
        list: List<Win>,
        w: Int,
        x0: Float,
    ) {
        this.context = context.applicationContext
        width = w
        x = x0.takeIf { kotlin.math.abs(it) >= 1f } ?: 1f
        wins = list
        frames = 0
        startedAt = SystemClock.uptimeMillis()
        lateSum = 0
        lateMax = 0
        lateN = 0
        readyAfter = -1
        settleLate = -1
        hide = null
    }

    /**
     * The windows that slide, with WM's bounds (home's list has none for a window away on another page), top-most
     * first: brought up bottom-most first, so they keep their order. Null: no frames (folded).
     */
    private fun slideWins(
        context: Context,
        rels: Map<Int, Int>,
    ): List<Win>? {
        WindowFrames.current ?: return null
        val running = WindowFrames.running.value.associateBy { it.id }
        return FreeformTasks.list(context).asReversed().mapNotNull { t ->
            val rel = rels[t.id] ?: return@mapNotNull null
            val r = running[t.id] ?: return@mapNotNull null
            // A window the user minimised stays in the dock; the page's own ones must be showing.
            val skip = r.minimised || (rel == 0 && (r.away || !t.visible)) || t.bounds.isEmpty
            if (skip) null else Win(t.id, rel.coerceIn(-1, 1), Rect(t.bounds), t)
        }
    }

    /** One leash session over [list]; false when the transition couldn't start. */
    private fun begin(
        context: Context,
        list: List<Win>,
    ): Boolean {
        val s = TaskLeash.Session(context, list.map { it.id }, "page slide", TaskLeash.SLIDE_MODES)
        s.onReady = { ok -> ready(s, ok) }
        // WM's bounds where each window is on the glass now (a real change for each: an unchanged task isn't in the
        // transition, so it gets no leash); another page's window comes up from under home in the same transition.
        val started =
            s.start { wct, token ->
                for (win in list) {
                    val tok = token(win.id) ?: continue
                    if (win.rel != 0) TaskLeash.reorder(wct, tok, true)
                    TaskLeash.setBounds(wct, tok, at(win))
                }
            }
        if (!started) return false
        session = s
        // Where the leashes go the moment they come (TaskLeash applies the last frame given).
        val t = SurfaceControl.Transaction()
        list.forEach { s.frame(t, it.id, at(it)) }
        return true
    }

    /** The leashes came ([ok]) or never will, for session [s]. */
    private fun ready(
        s: TaskLeash.Session,
        ok: Boolean,
    ) {
        if (session !== s) return
        readyAfter = SystemClock.uptimeMillis() - startedAt
        if (ok) draw() else cancel("no leash")
    }

    /** The track's offset [x0] (screen px) under the finger. */
    fun move(x0: Float) {
        if (session == null || settleAt != 0L) return
        x = x0
        draw()
    }

    /**
     * The finger let go: the track goes to [to] (screen px; 0 = the page it started on, -width = the next) over [d]
     * ms on cubic-bezier [c]; then [hidden] (home's hide list for the page it lands on) is committed. From
     * [startedAtHome] (home's Date.now() when its track's settle began): the curve runs from then, not from when this message came (it came a
     * main-thread hop or more later, and the windows trailed the page all through the settle and landed after it).
     */
    fun settle(
        to: Float,
        d: Long,
        c: FloatArray?,
        hidden: Set<Int>,
    ) {
        val at = startedAtHome.also { startedAtHome = 0 }
        if (session == null) {
            // Nothing slid (no leash): the change as before, but once the page has landed, not under its settle.
            main.postDelayed({ WindowFrames.current?.desktop(hidden) }, d.coerceIn(0, 2000))
            return
        }
        fromX = x
        toX = to
        ms = d.coerceIn(0, 2000)
        if (c != null && c.size == 4) curve = c
        hide = hidden
        val late = if (at > 0) (System.currentTimeMillis() - at).coerceIn(0, ms) else 0
        settleLate = late
        settleAt = SystemClock.uptimeMillis() - late
        // This frame already where the track is now, not one frame later.
        tick.doFrame(System.nanoTime())
    }

    private val tick =
        object : Choreographer.FrameCallback {
            override fun doFrame(frameTimeNanos: Long) {
                if (session == null || settleAt == 0L) return
                val f = if (ms <= 0) 1f else ((frameTimeNanos / 1_000_000 - settleAt).toFloat() / ms).coerceIn(0f, 1f)
                x = fromX + (toX - fromX) * bezier(f)
                draw()
                if (f >= 1f) land() else Choreographer.getInstance().postFrameCallback(this)
            }
        }

    /** Each window where the track has its page; bars and grips with them (only once the content is ours too). */
    private fun draw() {
        val s = session ?: return
        val t = SurfaceControl.Transaction()
        var moved = false
        for (w in wins) {
            if (s.frame(t, w.id, at(w))) moved = true
        }
        if (moved) {
            WindowFrames.current?.slideMove(t, wins.associate { it.id to dx(it).toFloat() })
            frames++
        }
        t.apply()
    }

    /** The slide has landed: the transition finished with every window at its real bounds, then the page change. */
    private fun land() {
        val s = session ?: return
        val hidden = hide.orEmpty()
        finish(s, hidden, "landed")
        main.post { WindowFrames.current?.desktop(hidden) }
    }

    /**
     * Home's hide list changed while the slide settles (home's page changed after it sent the settle - job
     * 20261024-190606-57880: the swipe back settled with page 2's list [3001], home was on page 1 before it landed, and
     * the landing's stale list hid page 1's window over the newer one): the newest list is the one committed when it
     * lands. True: taken (main thread, as [WindowFrames.desktop] posts it).
     */
    fun later(hidden: Set<Int>): Boolean {
        if (session == null || settleAt == 0L) return false
        hide = hidden
        newer = true
        return true
    }

    /** [later] took a list the landing has not committed yet. */
    private var newer = false

    /** Stopped before it landed (a new slide, the page reloaded, no leash): everything back where WM has it. */
    fun cancel(why: String) {
        val s = session ?: return
        val pending = hide.takeIf { newer }
        finish(s, emptySet(), why)
        // Home's list that came during the settle: committed still, after the windows went back.
        if (pending != null) main.post { WindowFrames.current?.desktop(pending) }
        // The other pages' windows it brought up go back under home (home's hide list is unchanged).
        val back = wins.filter { it.rel != 0 }.map { it.id }.toSet()
        val c = context ?: return
        if (back.isNotEmpty()) main.post { back.forEach { FreeformTasks.minimise(c, it) } }
    }

    private fun finish(
        s: TaskLeash.Session,
        hidden: Set<Int>,
        why: String,
    ) {
        session = null
        settleAt = 0L
        newer = false
        Choreographer.getInstance().removeFrameCallback(tick)
        val gone = wins.filter { it.id in hidden || (why != "landed" && it.rel != 0) }.map { it.id }.toSet()
        WindowFrames.current?.slideEnd(gone, why == "landed")
        s.hidden = gone
        // The windows left on another page go under home in the transition's own finish change (what a minimise
        // does), the same moment their leash is hidden: before, only their bounds went in it, WM showed them again as
        // it finished and the minimise came a transition later - the old page's windows flashed on the new one.
        s.finish(wins.associate { it.id to Rect(it.bounds) }) { wct, token ->
            for (w in wins) {
                val tok = token(w.id) ?: continue
                TaskLeash.setBounds(wct, tok, w.bounds)
                if (w.id in gone) TaskLeash.reorder(wct, tok, false)
            }
        }
        Log.i(
            TAG,
            "end ($why) after ${SystemClock.uptimeMillis() - startedAt} ms: $frames frames, x $x, hidden ${gone.ifEmpty { "none" }}, " +
                "leash after $readyAfter ms, moves late avg ${if (lateN > 0) lateSum / lateN else -1} max $lateMax ms ($lateN), settle late $settleLate ms at ${SystemClock.elapsedRealtime()}",
        )
        wins = emptyList()
    }

    private fun at(w: Win): Rect = Rect(w.bounds).apply { offset(dx(w), 0) }

    /** Window [w]'s offset now (screen px): its leash's, and its bar's and grip's. */
    private fun dx(w: Win): Int = (w.rel * width + x).toInt()

    /** CSS cubic-bezier(x1, y1, x2, y2) at time [t] (0..1). */
    private fun bezier(t: Float): Float {
        val (x1, y1, x2, y2) = curve.toList()
        var u = t
        repeat(8) {
            val bx = 3 * (1 - u) * (1 - u) * u * x1 + 3 * (1 - u) * u * u * x2 + u * u * u
            val dx = 3 * (1 - u) * (1 - u) * x1 + 6 * (1 - u) * u * (x2 - x1) + 3 * u * u * (1 - x2)
            if (kotlin.math.abs(dx) < 1e-5f) return@repeat
            u = (u - (bx - t) / dx).coerceIn(0f, 1f)
        }
        return 3 * (1 - u) * (1 - u) * u * y1 + 3 * (1 - u) * u * u * y2 + u * u * u
    }
}
