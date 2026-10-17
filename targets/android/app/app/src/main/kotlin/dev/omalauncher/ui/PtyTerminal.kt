package dev.omalauncher.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Typeface
import android.graphics.fonts.Font
import android.graphics.fonts.FontFamily
import android.graphics.fonts.SystemFonts
import android.os.SystemClock
import android.util.Log
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.MotionEvent
import androidx.compose.ui.graphics.toArgb
import com.termux.terminal.TerminalEmulator
import com.termux.terminal.TerminalSession
import com.termux.terminal.TerminalSessionClient
import com.termux.terminal.TextStyle
import com.termux.view.TerminalView
import com.termux.view.TerminalViewClient
import dev.omalauncher.R
import dev.omalauncher.linux.RootedGuest
import dev.omalauncher.linux.shellQuote
import dev.omalauncher.wayland.Keys

/**
 * A PowOS terminal the launcher draws itself (rooted mode): Termux's emulator on a pty of the app's own, running
 * `su -c powos-run.sh [command]` - only the tty crosses into the PowOS session, as with `su` in Termux.
 *
 * Tiles can't show a foot from the PowOS session: its processes (SELinux domain magisk, level s0) can't hand their
 * shared-memory buffers to the app (untrusted_app, with MLS categories) - foot's wl_shm pools arrived without their
 * fd ("create_pool without an fd") and foot quit at once. Drawing here needs no buffer from the other side.
 *
 * Its keys come from the launcher's keyboard (KeyboardBridge, as a [KeyTarget]) as evdev codes, replayed as Android
 * key events into Termux's own key handling (arrows, Ctrl and Alt combinations, the cursor-key modes). Main thread only.
 */
class PtyTerminal(
    private val context: Context,
    command: String,
    private val textPixels: () -> Int,
    private val onTap: () -> Unit,
    private val onExit: () -> Unit,
) : KeyTarget {
    /** The views showing it; a tile being arranged is drawn twice. The newest one takes the keys. */
    private val views = ArrayList<TerminalView>()

    private val sessionClient =
        object : TerminalSessionClient {
            override fun onTextChanged(changedSession: TerminalSession) = views.forEach { it.onScreenUpdated() }

            override fun onTitleChanged(changedSession: TerminalSession) = Unit

            override fun onSessionFinished(finishedSession: TerminalSession) {
                Log.i(TAG, "exited ${finishedSession.exitStatus}")
                onExit()
            }

            override fun onCopyTextToClipboard(
                session: TerminalSession,
                text: String,
            ) {
                clipboard().setPrimaryClip(ClipData.newPlainText("PowOS terminal", text))
            }

            override fun onPasteTextFromClipboard(session: TerminalSession) {
                val text = clipboard().primaryClip?.getItemAt(0)?.coerceToText(context)?.toString() ?: return
                session.emulator?.paste(text)
            }

            override fun onBell(session: TerminalSession) = Unit

            override fun onColorsChanged(session: TerminalSession) = views.forEach { it.invalidate() }

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

    /** Starts its process once a view first lays it out (Termux: the pty gets the view's columns and rows). */
    private val session =
        TerminalSession(
            "/system/bin/sh",
            "/",
            arrayOf("sh", "-c", "exec su -c " + shellQuote(RootedGuest.rootCommand(command))),
            (System.getenv() + ("TERM" to "xterm-256color")).map { (k, v) -> "$k=$v" }.toTypedArray(),
            TRANSCRIPT_ROWS,
            sessionClient,
        )

    private val viewClient =
        object : TerminalViewClient {
            override fun onScale(scale: Float) = 1f

            override fun onSingleTapUp(e: MotionEvent) = onTap()

            override fun shouldBackButtonBeMappedToEscape() = false

            override fun shouldEnforceCharBasedInput() = true

            override fun shouldUseCtrlSpaceWorkaround() = false

            override fun isTerminalViewSelected() = true

            override fun copyModeChanged(copyMode: Boolean) = Unit

            override fun onKeyDown(
                keyCode: Int,
                e: KeyEvent,
                session: TerminalSession,
            ) = false

            override fun onKeyUp(
                keyCode: Int,
                e: KeyEvent,
            ) = false

            override fun onLongPress(event: MotionEvent) = false

            override fun readControlKey() = false

            override fun readAltKey() = false

            override fun readShiftKey() = false

            override fun readFnKey() = false

            override fun onCodePoint(
                codePoint: Int,
                ctrlDown: Boolean,
                session: TerminalSession,
            ) = false

            override fun onEmulatorSet() = applyColors()

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

    /** A view showing this terminal; [release] it when it goes. */
    fun newView(context: Context): TerminalView =
        TerminalView(context, null).also { view ->
            // Never focused: the launcher's KeyboardSink owns the soft keyboard and hands the keys on (see [key]).
            view.isFocusable = false
            view.isFocusableInTouchMode = false
            view.setTerminalViewClient(viewClient)
            view.setTypeface(typeface(context))
            view.setTextSize(textPixels())
            view.attachSession(session)
            views += view
            applyColors()
        }

    fun release(view: TerminalView) {
        views -= view
    }

    /** Follows the launcher's terminal text size and theme. */
    fun restyle() {
        views.forEach { it.setTextSize(textPixels()) }
        applyColors()
    }

    /** Ends the shell (the widget went away). */
    fun finish() = session.finishIfRunning()

    /** The theme's colors (Omarchy's colors.toml: foreground, background, color0-15), as foot gets them. */
    private fun applyColors() {
        val colors = session.emulator?.mColors?.mCurrentColors ?: return
        for (i in 0 until 16) Palette.named("color$i")?.let { colors[i] = it.toArgb() }
        colors[TextStyle.COLOR_INDEX_FOREGROUND] = Palette.foreground.toArgb()
        colors[TextStyle.COLOR_INDEX_BACKGROUND] = Palette.background.toArgb()
        colors[TextStyle.COLOR_INDEX_CURSOR] = (Palette.named("cursor") ?: Palette.foreground).toArgb()
        views.forEach { it.invalidate() }
    }

    private fun clipboard() = context.getSystemService(ClipboardManager::class.java)

    // KeyTarget: the launcher keyboard's evdev keys.

    private val held = HashSet<Int>()

    override fun key(
        code: Int,
        pressed: Boolean,
    ) {
        if (Keys.isModifier(code)) {
            if (pressed) held += code else held -= code
            return
        }
        if (!pressed) return
        val view = views.lastOrNull() ?: return
        val keyCode = Keys.keyCode(code) ?: return
        var meta = 0
        if (KEY_LEFTSHIFT in held || KEY_RIGHTSHIFT in held) meta = meta or KeyEvent.META_SHIFT_ON or KeyEvent.META_SHIFT_LEFT_ON
        if (KEY_LEFTCTRL in held || KEY_RIGHTCTRL in held) meta = meta or KeyEvent.META_CTRL_ON or KeyEvent.META_CTRL_LEFT_ON
        if (KEY_LEFTALT in held) meta = meta or KeyEvent.META_ALT_ON or KeyEvent.META_ALT_LEFT_ON
        if (KEY_RIGHTALT in held) meta = meta or KeyEvent.META_ALT_ON or KeyEvent.META_ALT_RIGHT_ON
        val now = SystemClock.uptimeMillis()
        view.onKeyDown(keyCode, KeyEvent(now, now, KeyEvent.ACTION_DOWN, keyCode, 0, meta, KeyCharacterMap.VIRTUAL_KEYBOARD, 0))
    }

    override fun codePoint(cp: Int) = session.writeCodePoint(KEY_LEFTALT in held, cp)

    private companion object {
        const val TAG = "PtyTerminal"

        /** Scrollback; tmux keeps its own, this is for a plain shell. */
        const val TRANSCRIPT_ROWS = 2000

        const val KEY_LEFTSHIFT = 42
        const val KEY_RIGHTSHIFT = 54
        const val KEY_LEFTCTRL = 29
        const val KEY_RIGHTCTRL = 97
        const val KEY_LEFTALT = 56
        const val KEY_RIGHTALT = 100

        /** Monospace with the Nerd Font symbols tmux's and the prompt's icons use, as in foot. */
        private var typeface: Typeface? = null

        fun typeface(context: Context): Typeface =
            typeface ?: runCatching {
                // The cells measure the first family, so that is the system's monospace font (Droid Sans Mono).
                val mono = SystemFonts.getAvailableFonts().first { it.file?.name?.startsWith("DroidSansMono") == true }
                val symbols = Font.Builder(context.resources, R.font.nerd_symbols).build()
                Typeface.CustomFallbackBuilder(FontFamily.Builder(Font.Builder(mono.file!!).build()).build())
                    .addCustomFallback(FontFamily.Builder(symbols).build())
                    .setSystemFallback("monospace")
                    .build()
            }.getOrElse { Typeface.MONOSPACE }.also { typeface = it }
    }
}
