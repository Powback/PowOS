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
    private val counter = ViewTreeObserver.OnDrawListener { draws++ }

    /** Main, ahead of a pending traversal's sync barrier (a plain post runs after that draw: a frame late). */
    private val ui = Handler.createAsync(Looper.getMainLooper())

    /** [next]'s applies by window draws between receipt and apply: 0 (the same draw as the page frame), 1, 2, 3+. */
    val lag = LongArray(4)

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
        apply: () -> Unit,
    ) {
        val at = draws
        ui.post {
            Trace.endAsyncSection("$name f$id", cookie)
            if (id <= applied) return@post
            applied = id
            lag[(draws - at).coerceIn(0, 3).toInt()]++
            apply()
            val then = draws
            ui.postDelayed({ if (draws == then) web.invalidate() }, MAX_WAIT_MS)
        }
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
    }

    /** Another page (a reload): its frame ids start again at 1. */
    fun reset() {
        received = -1L
        applied = -1L
    }
}
