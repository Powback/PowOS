package dev.omalauncher.shell

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.graphics.Typeface
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.GestureDetector
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.ViewGroup
import android.view.inputmethod.InputMethodManager
import android.webkit.WebView
import android.widget.FrameLayout
import androidx.compose.ui.graphics.toArgb
import com.termux.terminal.RemoteSessionBridge
import com.termux.terminal.TerminalEmulator
import com.termux.terminal.TerminalSession
import com.termux.terminal.TerminalSessionClient
import com.termux.terminal.TextStyle
import com.termux.view.TerminalView
import com.termux.view.TerminalViewClient
import dev.omalauncher.ui.Palette
import dev.omalauncher.ui.PtyTerminal
import org.json.JSONObject

/**
 * The web shell's terminals drawn by PowTerm's terminal (the user 11-08, third "doesn't work anything like PowTerm":
 * "I can honestly just use the Powterm source"): Termux's TerminalView and emulator at PowTerm's version (libs
 * termux-terminal v0.118.1, as android-app-dev/projects/powterm/app/build.gradle.kts), fed through PowTerm's own
 * RemoteSessionBridge - compiled from PowTerm's repo (app/build.gradle.kts powtermJava), not a copy. So the renderer,
 * the font metrics, the IME (visible-password, char based), scrolling and its fling, the scrollback, mouse reports to
 * tmux, long-press selection and OSC 52 are PowTerm's code, not xterm.js imitating them.
 *
 * Bytes: the pty stays [ShellTerminals]' (one shell per terminal id, shared with the page): its output, frame by frame,
 * is appended to the emulator here ([output]); what the view sends (keys, IME text, mouse wheel, the emulator's
 * replies) leaves the session's input queue for the pty ([drain]). The pty follows the view's columns and rows.
 *
 * Where: the page places each slot over its terminal element (shell/ui/terminal.tsx `nativeView`): a view in the
 * page's parent, above the page. A slot in "page" mode hands every touch to the page as it was (a home tile's swipes,
 * its tap to focus); in "native" mode (focused, or a view-only session that scrolls) the touches are the terminal's.
 * Taps and pinches go back to the page ("term.tap", "term.pinch"), which owns focus and the text size setting.
 * HACK: placed by bridge calls from the page's rAF, so during a page swipe the view can trail its element by a frame,
 * and the page hides it whenever something of its own covers the element; real fix: a child surface placed by the
 * page's frame-synced geometry (FrameSync, as web windows' "w.f") below the page with a hole, see
 * docs/REMOTE-POWOS.md §4.
 */
class ShellTermViews(
    private val context: Context,
    private val runtime: dev.omalauncher.Runtime,
    private val web: WebView,
    private val terminals: ShellTerminals,
    private val emit: (String, Any?) -> Unit,
) {
    private val main = Handler(Looper.getMainLooper())
    private val slots = HashMap<String, Slot>()

    /** The extra keys' sticky modifiers (the page's): 0 off, 1 for the next key, 2 locked. */
    private var ctrl = 0
    private var alt = 0

    /** The terminal id whose view has the keys, if any. */
    private var focused: String? = null

    init {
        terminals.onOutput = { id, bytes -> slots[id]?.append(bytes) }
        terminals.onRun = { id -> slots[id]?.restart() }
    }

    /**
     * Places terminal [id]'s view as the page's TermPlace [p] (shell/types.ts): the element's rect x,y,w,h (CSS px at
     * dpr), its text textPx CSS px, mode 0 hidden, 1 the page's touches, 2 the terminal's; bg the page's terminal
     * background (#rrggbbaa); pinch: a pinch sizes the text.
     */
    fun view(
        id: String,
        p: JSONObject,
    ): Boolean {
        val dpr = p.getDouble("dpr").toFloat()
        val slot = slots.getOrPut(id) { Slot(id) }
        val px = { k: String -> (p.getDouble(k) * dpr).toFloat() }
        slot.place(px("x"), px("y"), px("w"), px("h"))
        slot.look(px("textPx"), p.optString("bg"), p.optBoolean("pinch", true))
        slot.mode(p.getInt("mode"))
        return true
    }

    fun unview(id: String) {
        if (focused == id) focus(id, false)
        slots.remove(id)?.remove()
    }

    /**
     * The keys to [id]'s view (on) or back to the page's (off). While a terminal has them the page can't take the focus
     * on a touch (its extra keys, the bar): Chromium requests it on every press, and the view lost its input
     * connection - the keyboard closed under the extra keys. The page lets go ([on] false) on a press elsewhere.
     */
    fun focus(
        id: String,
        on: Boolean,
    ) {
        val slot = slots[id] ?: return
        val imm = context.getSystemService(InputMethodManager::class.java)
        if (on) {
            focused = id
            // Desktop mode: home is non-focusable while windows show; typing lifts that (as ShellBridge.keyboard).
            dev.omalauncher.system.FreeformTasks.homeTyping(context, true)
            web.isFocusableInTouchMode = false
            slot.term.isFocusable = true
            slot.term.isFocusableInTouchMode = true
            slot.term.requestFocus()
            imm.showSoftInput(slot.term, 0)
        } else if (focused == id) {
            focused = null
            imm.hideSoftInputFromWindow(slot.term.windowToken, 0)
            slot.term.isFocusable = false
            slot.term.isFocusableInTouchMode = false
            web.isFocusableInTouchMode = true
            dev.omalauncher.system.FreeformTasks.homeTyping(context, false)
            web.requestFocus()
        }
    }

    /**
     * An extra key ([name]: ExtraKeys' names) into [id] as PowTerm's onExtraKey: a key code through Termux's key
     * handling (the program's cursor and keypad modes, the sticky Ctrl/Alt as meta), a character as typed.
     */
    fun key(
        id: String,
        name: String,
    ) {
        val slot = slots[id] ?: return
        val code = KEYS[name]
        if (code == null) {
            name.codePoints().forEach { slot.term.inputCodePoint(it, ctrl != 0, alt != 0) }
            return
        }
        var meta = 0
        if (ctrl != 0) meta = meta or KeyEvent.META_CTRL_ON or KeyEvent.META_CTRL_LEFT_ON
        if (alt != 0) meta = meta or KeyEvent.META_ALT_ON or KeyEvent.META_ALT_LEFT_ON
        val now = android.os.SystemClock.uptimeMillis()
        slot.term.onKeyDown(code, KeyEvent(now, now, KeyEvent.ACTION_DOWN, code, 0, meta))
    }

    fun mods(
        ctrl: Int,
        alt: Int,
    ) {
        this.ctrl = ctrl
        this.alt = alt
    }

    /** The clipboard into [id], bracketed when the program asked for it (PowTerm's paste). */
    fun paste(id: String) {
        val text = clipboard().primaryClip?.getItemAt(0)?.coerceToText(context)?.toString() ?: return
        slots[id]?.session?.emulator?.paste(text)
    }

    /** What's selected in [id] (Termux's long-press selection), to the clipboard; the selection ends. */
    fun copy(id: String): String? {
        val slot = slots[id] ?: return null
        val text = slot.selection()
        slot.term.stopTextSelectionMode()
        text?.let { clipboard().setPrimaryClip(ClipData.newPlainText("PowOS terminal", it)) }
        return text
    }

    fun removeAll() {
        focused?.let { focus(it, false) }
        slots.values.forEach { it.remove() }
        slots.clear()
    }

    private fun clipboard() = context.getSystemService(ClipboardManager::class.java)

    /** One terminal id's view and its emulator. Main thread. */
    private inner class Slot(
        val id: String,
    ) {
        private val sessionClient = SessionClient(this)
        val session =
            TerminalSession("/system/bin/sh", "/", arrayOf(), arrayOf(), TRANSCRIPT_ROWS, sessionClient).also {
                RemoteSessionBridge.install(it, COLS, ROWS, TRANSCRIPT_ROWS)
            }
        val term = TerminalView(context, null)
        private val frame = Frame(context, this)
        private var mode = -1
        private var textPx = 0
        private var bg: Int? = null
        private var sentSize = ""
        private var removed = false

        /** The view pinches the terminal text size (no size of its own). */
        var pinches = true

        init {
            term.setTerminalViewClient(ViewClient(this))
            term.isFocusable = false
            term.isFocusableInTouchMode = false
            frame.addView(term, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
            val parent = web.parent as? ViewGroup
            parent?.addView(frame, parent.indexOfChild(web) + 1, FrameLayout.LayoutParams(1, 1)) ?: Log.w(TAG, "$id: the page has no parent to put a terminal in")
            term.attachSession(session)
            terminals.history(id)?.let(::append)
            colors()
            term.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> main.post(::syncSize) }
            Thread(::drain, "powos-term-in[$id]").apply { isDaemon = true }.start()
        }

        fun place(
            x: Float,
            y: Float,
            w: Float,
            h: Float,
        ) {
            val lp = frame.layoutParams
            val pw = w.toInt().coerceAtLeast(1)
            val ph = h.toInt().coerceAtLeast(1)
            if (lp.width != pw || lp.height != ph) {
                lp.width = pw
                lp.height = ph
                frame.layoutParams = lp
            }
            // Whole device pixels, as Termux draws into the view's own pixels.
            frame.x = Math.round(x).toFloat()
            frame.y = Math.round(y).toFloat()
        }

        fun look(
            px: Float,
            background: String,
            pinch: Boolean,
        ) {
            pinches = pinch
            val size = Math.round(px).coerceAtLeast(1)
            if (size != textPx) {
                textPx = size
                // Size first: it creates the renderer, which setTypeface reads.
                term.setTextSize(size)
                term.setTypeface(typeface())
                main.post(::syncSize)
            }
            val color = parseColor(background)
            if (color != bg) {
                bg = color
                colors()
            }
        }

        fun mode(m: Int) {
            if (m == mode) return
            mode = m
            frame.visibility = if (m == 0) android.view.View.INVISIBLE else android.view.View.VISIBLE
            frame.toPage = m != 2
        }

        fun append(bytes: ByteArray) {
            if (!removed) RemoteSessionBridge.append(session, bytes, bytes.size)
        }

        /** A new run of the shell (restarted): a clean screen, then its output. */
        fun restart() {
            session.emulator?.reset()
            session.emulator?.clearScrollCounter()
            sentSize = ""
            term.onScreenUpdated()
            main.post(::syncSize)
        }

        /** The pty takes the view's columns and rows (Termux sized the emulator on layout), once they settle. */
        fun syncSize() {
            val e = session.emulator ?: return
            val size = "${e.mColumns}x${e.mRows}"
            if (removed || size == sentSize) return
            sentSize = size
            main.removeCallbacks(resize)
            main.postDelayed(resize, RESIZE_SETTLE_MS)
        }

        private val resize = Runnable { session.emulator?.let { terminals.resize(id, it.mColumns, it.mRows) } }

        /** The theme's colours (PtyTerminal's), the background the page's. */
        fun colors() {
            val c = session.emulator?.mColors?.mCurrentColors ?: return
            for (i in 0 until 16) Palette.named("color$i")?.let { c[i] = it.toArgb() }
            c[TextStyle.COLOR_INDEX_FOREGROUND] = Palette.foreground.toArgb()
            c[TextStyle.COLOR_INDEX_BACKGROUND] = bg ?: Palette.background.toArgb()
            c[TextStyle.COLOR_INDEX_CURSOR] = (Palette.named("cursor") ?: Palette.foreground).toArgb()
            term.invalidate()
        }

        /** PowTerm's face (Typeface.MONOSPACE) unless the user picked a terminal font of their own. */
        private fun typeface(): Typeface {
            val family = runtime.terminalFont.family
            if (family == dev.omalauncher.theme.Style.TERMINAL_FONT.default) return Typeface.MONOSPACE
            return PtyTerminal.typeface(context, family) { term.setTypeface(typeface()) }
        }

        /** The view's input (keys, IME text, wheel, the emulator's replies) to the pty, as PowTerm's Tab.drain. */
        private fun drain() {
            val buf = ByteArray(4096)
            while (true) {
                val n = RemoteSessionBridge.readInput(session, buf)
                if (n < 0) return
                val bytes = buf.copyOf(n)
                main.post { if (!removed) terminals.writeBytes(id, bytes) }
            }
        }

        /** Termux's selection (its long press): the text between its handles, else null. */
        fun selection(): String? {
            if (!term.isSelectingText) return null
            // HACK: TerminalView.getTextSelectionCursorController is package-private in terminal-view v0.118.1 (its
            // own floating Copy reaches it; the extra keys' copy can't), so it's read by reflection. Real fix: a public
            // getter upstream (or the selected text on TerminalView).
            val c =
                runCatching {
                    TerminalView::class.java.getDeclaredMethod("getTextSelectionCursorController").apply { isAccessible = true }.invoke(term)
                }.getOrNull() as? com.termux.view.textselection.TextSelectionCursorController ?: return null
            val sel = IntArray(4)
            c.getSelectors(sel)
            // getSelectors: y1, y2, x1, x2.
            return session.emulator?.getSelectedText(sel[2], sel[0], sel[3], sel[1])?.takeIf { it.isNotEmpty() }
        }

        /** The link under [e] (a terminal touch), opened in the phone's browser; whether there was one. */
        fun openLinkAt(e: MotionEvent): Boolean {
            val url = linkAt(e) ?: return false
            runCatching {
                context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }.onFailure { Log.w(TAG, "$id: no app opens $url", it) }
            return true
        }

        /** The link under [e]: its rows (and the ones it wraps onto) read from the emulator, see [linkAt]. */
        private fun linkAt(e: MotionEvent): String? {
            val emu = session.emulator ?: return null
            val screen = emu.screen
            val (col, row) = term.getColumnAndRow(e, true).let { it[0] to it[1] }
            val from = (row - LINK_ROWS).coerceAtLeast(-screen.activeTranscriptRows)
            val to = (row + LINK_ROWS).coerceAtMost(emu.mRows - 1)
            if (row !in from..to) return null
            val rows = (from..to).map { screen.getSelectedText(0, it, emu.mColumns - 1, it) ?: "" }
            val wraps = (from..to).map { screen.getLineWrap(it) }
            return linkAt(Rows(rows, wraps, emu.mColumns), row - from, col)
        }

        /**
         * Termux's long-press selection (its handles and floating Copy) from [e], in either mode: the view takes focus
         * for it (TerminalView.startTextSelectionMode does nothing without), which an unfocused terminal's view didn't
         * have - so a long press selected nothing and the user couldn't copy the sign-in link (11-09). The focus goes
         * back when the selection ends ([selectionEnded]).
         */
        fun startSelection(e: MotionEvent): Boolean {
            if (term.isSelectingText || session.emulator == null) return term.isSelectingText
            term.isFocusable = true
            term.isFocusableInTouchMode = true
            term.performHapticFeedback(android.view.HapticFeedbackConstants.LONG_PRESS)
            term.startTextSelectionMode(e)
            if (!term.isSelectingText) selectionEnded()
            return term.isSelectingText
        }

        /** The selection's done: the keys stay where they were (the page's, unless this terminal has them). */
        fun selectionEnded() {
            if (focused == id) return
            term.isFocusable = false
            term.isFocusableInTouchMode = false
            web.requestFocus()
        }

        fun remove() {
            removed = true
            main.removeCallbacks(resize)
            RemoteSessionBridge.close(session)
            (frame.parent as? ViewGroup)?.removeView(frame)
        }
    }

    /**
     * The slot's box: in "page" mode its touches are the page's, at the same place on the page - except a long press,
     * which selects in the terminal (the page gets a cancel; the terminal has the touches while its selection shows),
     * and a tap on a link, which opens it (the page still gets the tap: it focuses the terminal as before).
     */
    private inner class Frame(
        context: Context,
        private val slot: Slot,
    ) : FrameLayout(context) {
        var toPage = true

        /** This gesture is the terminal's: a long press took it, or it began on a showing selection. */
        private var terminalHas = false

        /** A long press took the gesture mid-way: the rest of it (to the finger's lift) goes nowhere. */
        private var swallow = false

        private val gestures =
            GestureDetector(
                context,
                object : GestureDetector.SimpleOnGestureListener() {
                    override fun onLongPress(e: MotionEvent) {
                        if (!toPage || !slot.startSelection(e)) return
                        swallow = true
                        toWeb(MotionEvent.obtain(e).apply { action = MotionEvent.ACTION_CANCEL })
                    }

                    override fun onSingleTapUp(e: MotionEvent): Boolean {
                        if (toPage) slot.openLinkAt(e)
                        return false
                    }
                },
            )

        override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
            if (!toPage) return super.dispatchTouchEvent(ev)
            val end = ev.actionMasked == MotionEvent.ACTION_UP || ev.actionMasked == MotionEvent.ACTION_CANCEL
            if (ev.actionMasked == MotionEvent.ACTION_DOWN) {
                swallow = false
                terminalHas = slot.term.isSelectingText
            }
            if (terminalHas) {
                super.dispatchTouchEvent(ev)
                if (end) terminalHas = false
                return true
            }
            gestures.onTouchEvent(ev)
            if (swallow) {
                if (end) swallow = false
                return true
            }
            toWeb(MotionEvent.obtain(ev))
            return true
        }

        /** [e] (a copy, recycled here) to the page, at the same place on it. */
        private fun toWeb(e: MotionEvent) {
            e.offsetLocation(x - web.x, y - web.y)
            web.dispatchTouchEvent(e)
            e.recycle()
        }
    }

    private inner class ViewClient(
        private val slot: Slot,
    ) : TerminalViewClient {
        /** PowTerm's pinch: a step of text size per noticeable change of scale; the page saves it and sizes every view. */
        override fun onScale(scale: Float): Float {
            if (scale in 0.9f..1.1f || !slot.pinches) return if (slot.pinches) scale else 1f
            emit("term.pinch", JSONObject().put("id", slot.id).put("dir", if (scale > 1f) 1 else -1))
            return 1f
        }

        /** A tap on a link opens it; anywhere else it's the page's (focus). */
        override fun onSingleTapUp(e: MotionEvent) {
            if (!slot.openLinkAt(e)) emit("term.tap", JSONObject().put("id", slot.id))
        }

        override fun shouldBackButtonBeMappedToEscape() = false

        override fun shouldEnforceCharBasedInput() = true

        override fun shouldUseCtrlSpaceWorkaround() = false

        override fun isTerminalViewSelected() = true

        override fun copyModeChanged(copyMode: Boolean) {
            if (!copyMode) slot.selectionEnded()
        }

        override fun onKeyDown(
            keyCode: Int,
            e: KeyEvent,
            session: TerminalSession,
        ) = false

        override fun onKeyUp(
            keyCode: Int,
            e: KeyEvent,
        ) = false

        /** Termux's selection, focus or not ([Slot.startSelection]); true: handled here. */
        override fun onLongPress(event: MotionEvent): Boolean {
            slot.startSelection(event)
            return true
        }

        override fun readControlKey() = ctrl != 0

        override fun readAltKey() = alt != 0

        override fun readShiftKey() = false

        override fun readFnKey() = false

        /** A typed character took a latched (not locked) modifier: the page lets go of it. */
        override fun onCodePoint(
            codePoint: Int,
            ctrlDown: Boolean,
            session: TerminalSession,
        ): Boolean {
            if (ctrl == 1 || alt == 1) {
                if (ctrl == 1) ctrl = 0
                if (alt == 1) alt = 0
                emit("term.consumed", null)
            }
            return false
        }

        override fun onEmulatorSet() = slot.colors()

        override fun logError(
            tag: String,
            message: String,
        ) {
            Log.e(tag, message)
        }

        override fun logWarn(
            tag: String,
            message: String,
        ) {
            Log.w(tag, message)
        }

        override fun logInfo(
            tag: String,
            message: String,
        ) = Unit

        override fun logDebug(
            tag: String,
            message: String,
        ) = Unit

        override fun logVerbose(
            tag: String,
            message: String,
        ) = Unit

        override fun logStackTraceWithMessage(
            tag: String,
            message: String,
            e: Exception,
        ) {
            Log.e(tag, message, e)
        }

        override fun logStackTrace(
            tag: String,
            e: Exception,
        ) {
            Log.e(tag, "", e)
        }
    }

    /** PowTerm's Tab.client: OSC 52 and the selection's copy into the clipboard, paste, redraws. */
    private inner class SessionClient(
        private val slot: Slot,
    ) : TerminalSessionClient {
        override fun onTextChanged(changedSession: TerminalSession) = slot.term.onScreenUpdated()

        override fun onTitleChanged(changedSession: TerminalSession) = Unit

        override fun onSessionFinished(finishedSession: TerminalSession) = Unit

        override fun onCopyTextToClipboard(
            session: TerminalSession,
            text: String,
        ) {
            clipboard().setPrimaryClip(ClipData.newPlainText("PowOS terminal", text))
        }

        override fun onPasteTextFromClipboard(session: TerminalSession) = paste(slot.id)

        override fun onBell(session: TerminalSession) = Unit

        override fun onColorsChanged(session: TerminalSession) = slot.term.invalidate()

        override fun onTerminalCursorStateChange(state: Boolean) = Unit

        override fun getTerminalCursorStyle(): Int = TerminalEmulator.TERMINAL_CURSOR_STYLE_BLOCK

        override fun logError(
            tag: String,
            message: String,
        ) {
            Log.e(tag, message)
        }

        override fun logWarn(
            tag: String,
            message: String,
        ) {
            Log.w(tag, message)
        }

        override fun logInfo(
            tag: String,
            message: String,
        ) = Unit

        override fun logDebug(
            tag: String,
            message: String,
        ) = Unit

        override fun logVerbose(
            tag: String,
            message: String,
        ) = Unit

        override fun logStackTraceWithMessage(
            tag: String,
            message: String,
            e: Exception,
        ) {
            Log.e(tag, message, e)
        }

        override fun logStackTrace(
            tag: String,
            e: Exception,
        ) {
            Log.e(tag, "", e)
        }
    }

    companion object {
        private const val TAG = "ShellTermViews"

        /** The extra keys that are key codes (ExtraKeysView's Key.Code rows); the rest are characters. */
        private val KEYS =
            mapOf(
                "esc" to KeyEvent.KEYCODE_ESCAPE,
                "tab" to KeyEvent.KEYCODE_TAB,
                "home" to KeyEvent.KEYCODE_MOVE_HOME,
                "end" to KeyEvent.KEYCODE_MOVE_END,
                "up" to KeyEvent.KEYCODE_DPAD_UP,
                "down" to KeyEvent.KEYCODE_DPAD_DOWN,
                "left" to KeyEvent.KEYCODE_DPAD_LEFT,
                "right" to KeyEvent.KEYCODE_DPAD_RIGHT,
                "pgup" to KeyEvent.KEYCODE_PAGE_UP,
                "pgdn" to KeyEvent.KEYCODE_PAGE_DOWN,
            )

        /** PowTerm's scrollback (Tab.TRANSCRIPT_ROWS): a plain shell's history; tmux keeps its own. */
        const val TRANSCRIPT_ROWS = 3000
        private const val COLS = 80
        private const val ROWS = 24

        /** PowTerm's: the pty follows the view once its size has held this long (each resize is a tmux redraw). */
        private const val RESIZE_SETTLE_MS = 120L

        /** How far up and down from a tapped row a link may run (wrapped over rows). */
        private const val LINK_ROWS = 12

        /** A link: everything up to a space or a quote, its query string and fragment included. */
        private val LINK = Regex("""(?:https?|file)://[^\s<>"'`]+""")

        /**
         * A terminal's rows around a touch: each row's text (trailing blanks dropped), whether it wrapped onto the next
         * ([wraps]), the width in columns.
         */
        data class Rows(
            val text: List<String>,
            val wraps: List<Boolean>,
            val cols: Int,
        ) {
            /**
             * Row [i] goes on in the next: it wrapped, or it's full to the last column - tmux and Claude Code's own
             * layout break a long line with cursor moves, not a wrap, so the sign-in link (~400 characters) spans
             * several rows that only fill the width.
             */
            fun continues(i: Int) = i < text.size - 1 && (wraps.getOrElse(i) { false } || text[i].length >= cols)

            /** The rows row [at] is part of, joined, and where its column [col] falls in them. */
            fun line(
                at: Int,
                col: Int,
            ): Pair<String, Int> {
                var a = at
                while (a > 0 && continues(a - 1)) a--
                var b = at
                while (continues(b)) b++
                return (a..b).joinToString("") { if (it < b) text[it].padEnd(cols) else text[it] } to (at - a) * cols + col
            }
        }

        /**
         * The link at column [col] of row [at] of [rows], or null - its query string and fragment included: the old
         * link match ended at the '?' (the user, 11-09: "it doesn't catch the whole link ... it ends after the question
         * mark").
         */
        fun linkAt(
            rows: Rows,
            at: Int,
            col: Int,
        ): String? {
            if (at !in rows.text.indices || rows.cols <= 0) return null
            val (line, pos) = rows.line(at, col)
            return LINK.findAll(line)
                .map { it.range.first to trimLink(it.value) }
                .firstOrNull { (from, url) -> pos >= from && pos < from + url.length }
                ?.second
        }

        /** A link without the sentence's punctuation after it (a ')' it opened stays). */
        fun trimLink(s: String): String {
            var u = s
            while (u.isNotEmpty() && u.last() in ".,;:!?'\")]}>") {
                if (u.last() == ')' && u.count { it == '(' } >= u.count { it == ')' }) break
                u = u.dropLast(1)
            }
            return u
        }

        /** "#rrggbbaa" (the page's) to ARGB; null for anything else. */
        fun parseColor(s: String?): Int? {
            if (s == null || !Regex("#[0-9a-fA-F]{8}").matches(s)) return null
            val v = s.substring(1).toLong(16)
            return (((v and 0xff) shl 24) or (v shr 8)).toInt()
        }
    }
}
