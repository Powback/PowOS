package dev.omalauncher.shell

import android.os.Trace
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
 * Newest wins, per channel: a callback for a frame older than one already applied is dropped. Trace: async section
 * "<name> f<id>", receipt to apply.
 */
internal class FrameSync(
    private val web: WebView,
    private val name: String,
) {
    /** The newest id received (port thread writes, main reads) and the newest one put on a draw (main only). */
    @Volatile var received = -1L
        private set
    var applied = -1L

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
        web.postVisualStateCallback(
            id,
            object : WebView.VisualStateCallback() {
                override fun onComplete(requestId: Long) {
                    Trace.endAsyncSection("$name f$id", cookie)
                    if (requestId <= applied) return
                    applied = requestId
                    apply()
                }
            },
        )
    }

    /** Another page (a reload): its frame ids start again at 1. */
    fun reset() {
        received = -1L
        applied = -1L
    }
}
