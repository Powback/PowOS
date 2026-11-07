package dev.omalauncher.shell

import android.os.Handler
import android.os.Looper
import android.os.Trace
import android.view.View
import android.view.ViewTreeObserver
import android.webkit.WebView

/**
 * A compositor change bound to the page frame it was measured on (docs/NATIVE-GLASS.md, docs/WEB_WINDOWS.md §2): the
 * page tags what it measured with a frame id ("b.f <id> ..." for the glass, "w.f <id> ..." for the web windows; one id
 * counter in the page, apps/native.ts nextFrameId), and the change goes on the window's draw that first shows that
 * page state. [WebView.postVisualStateCallback] fires once the WebView's next draw holds the renderer's content as of
 * the request (frame <id> or later); the caller's [bind] block then puts its transaction on that draw
 * ([android.view.AttachedSurfaceControl.applyTransactionOnDraw]), so the change and the page's pixels land on the same
 * composited frame. Both channels ride the same draw when the page sent them for the same frame.
 *
 * Newest wins, per channel: a callback for a frame older than one already applied is dropped. Never waits for a draw
 * longer than [MAX_WAIT_MS] (an idle page draws only on damage): applied without one then. Trace: async section
 * "<name> f<id>", receipt to apply.
 *
 * [bind] is at least a frame late, though: the visual-state request reaches the renderer after the page frame that
 * measured the change was already committed (the page sends from its rAF, then commits), so it rides the NEXT commit -
 * the web windows' content trailed their DOM frame by 1-4 frames (2026-10-30, 888 of 932 applies). [next] is exact
 * instead: the WebView is a synchronous compositor (it draws the renderer's newest active frame inside the window's own
 * draw), and the page's message arrives before the commit it measured, so the first window draw after the receipt is
 * the one that shows that page frame. [next] puts the change on that draw.
 */
internal class FrameSync(
    private val web: WebView,
    private val name: String,
) {
    /** The newest id received (port thread writes, main reads) and the newest one put on a draw (main only). */
    @Volatile var received = -1L
        private set
    var applied = -1L

    /** The window's draws so far (main thread writes; the port thread reads it at receipt). */
    @Volatile private var draws = 0L

    /** When each of the last [RING] draws ran (monotonic ms, System.nanoTime's clock; main thread only). */
    private val drawAt = DoubleArray(RING)
    private val counter =
        ViewTreeObserver.OnDrawListener {
            drawAt[(draws % RING).toInt()] = System.nanoTime() / 1e6
            draws++
        }

    /** Main, ahead of a pending traversal's sync barrier (a plain post runs after that draw: a frame late). */
    private val ui = Handler.createAsync(Looper.getMainLooper())

    /** [next]'s applies by window draws between receipt and apply: 0 (the same draw as the page frame), 1, 2, 3+. */
    val lag = LongArray(4)

    /**
     * [next]'s applies by window draws between the PAGE frame (its rAF's vsync time, the page's clock) and the apply: 0 =
     * nothing drew since the page frame began (the transaction rides the draw that shows it), 1, 2, 3+ (that many draws
     * went out first: the content trailed the DOM by up to that many frames). Unlike [lag], it sees a draw that ran
     * before the message reached the host at all.
     */
    val pageLag = LongArray(4)

    /**
     * N2 (docs/WEB_WINDOWS.md "Native-glued windows"): [ahead]'s applies by window draws between the PREDICTED page frame
     * (the frame the geometry is for, one after the one that sent it) and the apply - 0 = on the draw that shows it.
     */
    val aheadLag = LongArray(4)

    /** Sum of (receipt - page frame) ms over [pageLag]'s applies: how long the message took to reach the host. */
    var receiptMs = 0.0

    init {
        // A view's observer is merged into its window's on attach and lost on detach: counted on each window it joins.
        if (web.isAttachedToWindow) web.viewTreeObserver.addOnDrawListener(counter)
        web.addOnAttachStateChangeListener(
            object : View.OnAttachStateChangeListener {
                override fun onViewAttachedToWindow(v: View) = v.viewTreeObserver.addOnDrawListener(counter)

                override fun onViewDetachedFromWindow(v: View) = v.viewTreeObserver.removeOnDrawListener(counter)
            },
        )
    }

    /**
     * On the port's thread, right at receipt of page frame [id] ([receive]'s [cookie]): [apply] runs on the main thread
     * before the window's next draw - the draw that shows that page frame (see the class) - and puts its transaction on
     * it ([android.view.AttachedSurfaceControl.applyTransactionOnDraw]). It asks for no draw itself (that could draw
     * before the page's commit is ready, the content then a frame AHEAD): the page's commit asks for one; one whose
     * change paints nothing (an idle page) gets one after [MAX_WAIT_MS].
     */
    fun next(
        id: Long,
        cookie: Int,
        pageEpochMs: Double = Double.NaN,
        apply: () -> Unit,
    ) {
        val at = draws
        val nowMs = System.nanoTime() / 1e6
        // The page's rAF time (performance.timeOrigin + its timestamp: wall-clock ms) on the monotonic clock.
        val page = pageEpochMs - (System.currentTimeMillis() - nowMs)
        ui.post {
            Trace.endAsyncSection("$name f$id", cookie)
            if (id <= applied) return@post staleOnce(id)
            applied = id
            lag[(draws - at).coerceIn(0, 3).toInt()]++
            if (!page.isNaN()) countPageLag(page, nowMs)
            apply()
            val then = draws
            ui.postDelayed({ if (draws == then) web.invalidate() }, MAX_WAIT_MS)
        }
    }

    /** Main: the draws since page frame time [page] (monotonic ms) into [pageLag]; its receipt at [receivedMs]. */
    private fun countPageLag(
        page: Double,
        receivedMs: Double,
    ) {
        pageLag[drawsSince(page).coerceAtMost(3)]++
        receiptMs += receivedMs - page
    }

    /** Main: the window's draws that ran after [page] (monotonic ms), of the last [RING]. */
    private fun drawsSince(page: Double): Int {
        var since = 0
        val n = minOf(draws, RING.toLong()).toInt()
        while (since < n && drawAt[((draws - 1 - since) % RING).toInt()] > page) since++
        return since
    }

    /**
     * N2, on the port's thread: geometry the page measured for its NEXT frame (a main-thread transition sampled one
     * frame ahead, ui/webwindows.tsx ahead) - [id] sent from page frame k, for frame k+1 at [pageEpochMs]. The
     * visual-state request is posted now, while frame k is still being committed, so it rides commit k+1 - the one
     * that shows this geometry - and its callback runs right before the draw that shows it: [apply] lands on exactly
     * that draw whatever the raster/activation time (where [next] guesses "the first draw after receipt"). Newest wins
     * with [next]'s ids; never waits longer than [MAX_WAIT_MS] (applied then, as [bind]).
     */
    fun ahead(
        id: Long,
        cookie: Int,
        pageEpochMs: Double,
        apply: () -> Unit,
    ) {
        val page = pageEpochMs - (System.currentTimeMillis() - System.nanoTime() / 1e6)
        val p = Pending(id, cookie, apply)
        synchronized(this) { pending = p }
        ui.post {
            // How long before its frame's vsync the request went to the renderer: under ~0 it can't ride that commit.
            if (!page.isNaN()) {
                leadMs += page - System.nanoTime() / 1e6
                leads++
            }
            val fire = { applyAhead(p, page) }
            web.postVisualStateCallback(
                id,
                object : WebView.VisualStateCallback() {
                    override fun onComplete(requestId: Long) = fire()
                },
            )
            web.postDelayed({ fire() }, MAX_WAIT_MS)
        }
    }

    /**
     * N2, on the port's thread: the page's own measure of the frame it predicted with [ahead], which came out different
     * (the page's frame ran late - the prediction assumed one period, 11-07 on the phone: dt 16.7 / 33 / 50 ms at 120 Hz
     * against 8.3 - or a sub-pixel miss). That frame's commit is the one the pending [ahead]'s visual-state request
     * rides, so this geometry takes the prediction's place on the same draw. Before, it went to [next] as a newer id:
     * applied at once (on whatever draw came next) and the pending prediction dropped as older - of 341 predictions
     * sent on the phone 4 were applied. When the prediction's draw already went: [next], as before.
     */
    fun correct(
        id: Long,
        cookie: Int,
        pageEpochMs: Double,
        apply: () -> Unit,
    ) {
        synchronized(this) {
            val p = pending
            if (p != null && !p.fired && p.id < id) {
                Trace.endAsyncSection("$name f${p.id}", p.cookie)
                p.id = id
                p.cookie = cookie
                p.apply = apply
                corrected++
                return
            }
        }
        correctedLate++
        next(id, cookie, pageEpochMs, apply)
    }

    /** An [ahead] waiting for its draw: its id, cookie and apply ([correct] replaces them until it fires). */
    private class Pending(
        var id: Long,
        var cookie: Int,
        var apply: () -> Unit,
    ) {
        var fired = false
    }

    /** The newest [ahead] (port thread writes, [correct] reads; guarded by this). */
    private var pending: Pending? = null

    /** [correct]s that took a pending prediction's place / that came after its draw (went to [next]). */
    var corrected = 0L
        private set
    var correctedLate = 0L
        private set

    /** [ahead]s dropped because a newer frame was applied first (a [next] of a frame the page didn't predict). */
    var aheadLost = 0L
        private set

    /**
     * Sums over [ahead]: ms from posting its visual-state request to its frame's vsync ([leadMs], over [leads]), and
     * from that vsync to the callback ([fireMs], over [aheadLag]'s count) - which commit the request rode, in ms.
     */
    var leadMs = 0.0
        private set
    var leads = 0L
        private set
    var fireMs = 0.0
        private set

    /** Main: [ahead]'s apply, once, unless a newer frame went first; counted into [aheadLag] from its frame [page]. */
    private fun applyAhead(
        p: Pending,
        page: Double,
    ) {
        val (id, cookie, apply) =
            synchronized(this) {
                if (p.fired) return
                p.fired = true
                if (pending === p) pending = null
                Triple(p.id, p.cookie, p.apply)
            }
        Trace.endAsyncSection("$name f$id", cookie)
        if (id <= applied) {
            aheadLost++
            return
        }
        applied = id
        if (!page.isNaN()) {
            aheadLag[drawsSince(page).coerceAtMost(3)]++
            fireMs += System.nanoTime() / 1e6 - page
        }
        apply()
    }

    /** On the port's thread: [id] arrived. The cookie for [bind]. */
    fun receive(id: Long): Int {
        val cookie = id.toInt()
        Trace.beginAsyncSection("$name f$id", cookie)
        if (id > received) received = id
        return cookie
    }

    /**
     * On the main thread: [apply] runs on the draw that shows page frame [id] (or never, when a newer one went first).
     * [now]: skip the wait (the caller's own fallback path) - [apply] runs at once.
     */
    fun bind(
        id: Long,
        cookie: Int,
        now: Boolean = false,
        apply: () -> Unit,
    ) {
        if (now) {
            Trace.endAsyncSection("$name f$id", cookie)
            apply()
            return
        }
        var done = false
        val fire = { why: String ->
            if (!done) {
                done = true
                Trace.endAsyncSection("$name f$id", cookie)
                if (id > applied) {
                    applied = id
                    if (why != "draw") android.util.Log.i("PowosFrameSync", "$name f$id: no draw in $MAX_WAIT_MS ms, applied without one")
                    apply()
                }
            }
        }
        web.postVisualStateCallback(
            id,
            object : WebView.VisualStateCallback() {
                override fun onComplete(requestId: Long) = fire("draw")
            },
        )
        // The callback fires on the WebView's next draw, and an idle page whose change paints nothing (a web window's
        // element is invisible: the host draws it) asks for none - the window waited for an unrelated redraw (a touch,
        // 15-20 s, 2026-10-30 20:40). So: a draw now, and the change applied anyway if none came in [MAX_WAIT_MS].
        web.invalidate()
        web.postDelayed({ fire("timeout") }, MAX_WAIT_MS)
    }

    companion object {
        /** A bound change waits at most this long for its draw (two frames at 60 Hz plus slack). */
        const val MAX_WAIT_MS = 50L

        /** A frame this far behind the applied one is no reordering: [staleOnce] logs it. */
        private const val STALE_GAP = 30L

        /** Draw times kept for [pageLag]. */
        private const val RING = 8
    }

    /** Another page (a reload): its frame ids start again at 1. */
    fun reset() {
        received = -1L
        applied = -1L
        staleSaid = false
        synchronized(this) { pending = null }
    }

    /** [next] dropped page frame [id] as older than the last applied: said once per page (a missed [reset] shows). */
    private var staleSaid = false

    private fun staleOnce(id: Long) {
        if (staleSaid || applied - id < STALE_GAP) return
        staleSaid = true
        android.util.Log.w("PowosFrameSync", "$name f$id dropped: f$applied applied already (a page reload without reset?)")
    }
}
