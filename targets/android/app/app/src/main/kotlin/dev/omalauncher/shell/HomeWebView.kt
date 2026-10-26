package dev.omalauncher.shell

import android.content.Context
import android.view.MotionEvent
import android.webkit.WebView
import dev.omalauncher.system.PageSlide

/**
 * Raising an incoming desktop's task can remove home's window focus even with that task non-focusable. Android
 * still delivers the finger's moves and UP, but WebView cancels the DOM touch stream on focus loss. Hold that
 * notification until the page swipe ends so the page and its windows follow the whole swipe, including its release.
 * Only a page slide with a finger down qualifies; real touch cancellation still reaches WebView immediately.
 */
class HomeWebView(context: Context) : WebView(context) {
    private var touching = false
    private var deferredFocusLoss = false

    override fun onWindowFocusChanged(hasWindowFocus: Boolean) {
        if (!hasWindowFocus && touching && PageSlide.dragging) {
            deferredFocusLoss = true
            return
        }
        deferredFocusLoss = false
        super.onWindowFocusChanged(hasWindowFocus)
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (event.actionMasked == MotionEvent.ACTION_DOWN) touching = true
        val handled = super.onTouchEvent(event)
        if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL) {
            touching = false
            // Let the release reach Chromium before delivering the focus change that would cancel the touch.
            post { flushFocusLoss() }
        }
        return handled
    }

    private fun flushFocusLoss() {
        if (!deferredFocusLoss || touching) return
        deferredFocusLoss = false
        super.onWindowFocusChanged(hasWindowFocus())
    }
}
