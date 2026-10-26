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
    /** The terminal font family the user picked (Style terminal.font), as foot uses it. */
    private val fontFamily: () -> String,
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

    /** Views with a text size of their own (a widget's textSize), in pixels; the others follow [textPixels]. */
    private val ownPixels = java.util.WeakHashMap<TerminalView, Int>()

    /** A view showing this terminal, at [pixels] text if given; [release] it when it goes. */
    fun newView(context: Context, pixels: Int? = null): TerminalView =
        TerminalView(context, null).also { view ->
            // Never focused: the launcher's KeyboardSink owns the soft keyboard and hands the keys on (see [key]).
            view.isFocusable = false
            view.isFocusableInTouchMode = false
            view.setTerminalViewClient(viewClient)
            if (pixels != null) ownPixels[view] = pixels
            // Size first: it creates the renderer, which setTypeface reads.
            view.setTextSize(pixels ?: textPixels())
            view.setTypeface(typeface(context, fontFamily()) { restyle() })
            // One view drives the shell's size, the newest (a tile's screen over the tile): a view resizes the
            // session to its own columns whenever it's laid out, and the tile under the screen, smaller and at
            // smaller text, kept sizing it to the tile - the screen drew the tile's columns. The others let go of
            // the session (a view without one doesn't resize it) until [release] gives it back.
            views.forEach { it.attachSession(null) }
            view.attachSession(session)
            views += view
            applyColors()
        }

    fun release(view: TerminalView) {
        views -= view
        ownPixels -= view
        // The view under it gets the session back, which sizes the shell to it again.
        views.lastOrNull()?.let { it.post { if (it in views) it.attachSession(session) } }
    }

    /** Follows the launcher's terminal text size and theme. */
    fun restyle() {
        val face = typeface(context, fontFamily()) { restyle() }
        views.forEach {
            it.setTextSize(ownPixels[it] ?: textPixels())
            it.setTypeface(face)
        }
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

    companion object {
        private const val TAG = "PtyTerminal"

        /** Scrollback; tmux keeps its own, this is for a plain shell. */
        private const val TRANSCRIPT_ROWS = 2000

        private const val KEY_LEFTSHIFT = 42
        private const val KEY_RIGHTSHIFT = 54
        private const val KEY_LEFTCTRL = 29
        private const val KEY_RIGHTCTRL = 97
        private const val KEY_LEFTALT = 56
        private const val KEY_RIGHTALT = 100

        /** Typefaces by family, with the Nerd Font symbols tmux's and the prompt's icons use as fallback, as in foot. */
        private val typefaces = HashMap<String, Typeface>()

        /** Families whose font file is being fetched from PowOS. */
        private val fetching = HashSet<String>()

        /**
         * [family] as an Android typeface: its [fontFile], else (meanwhile, and if that fails) the system's monospace
         * font. [onLoaded] runs (main thread) once the file is there.
         */
        fun typeface(
            context: Context,
            family: String,
            onLoaded: () -> Unit,
        ): Typeface {
            typefaces[family]?.let { return it }
            fontFile(context, family, onLoaded)?.let { file ->
                withSymbols(context, runCatching { Font.Builder(file).build() }.getOrNull())?.let {
                    typefaces[family] = it
                    return it
                }
            }
            return withSymbols(context, null) ?: Typeface.MONOSPACE
        }

        /**
         * [family]'s font file, or null while it isn't there yet. The file is PowOS's, out of the app's reach (rooted
         * mode: /data/powos), so the first time it's looked up with PowOS's fontconfig and copied into the app's
         * files, in the background; [onLoaded] runs (main thread) once it's there. The web shell's terminals use it
         * too (ShellActivity serves it).
         */
        fun fontFile(
            context: Context,
            family: String,
            onLoaded: () -> Unit,
        ): java.io.File? {
            val file = java.io.File(context.filesDir, "fonts/" + family.replace(Regex("[^A-Za-z0-9]+"), "-") + ".font")
            if (file.length() > 0) return file
            if (RootedGuest.enabled && fetching.add(family)) {
                val main = android.os.Handler(android.os.Looper.getMainLooper())
                Thread {
                    val path = StringBuilder()
                    RootedGuest.run("fc-match -f '%{file}' " + shellQuote("$family:style=Regular")) { path.append(it.trim()) }
                    if (path.startsWith("/")) {
                        file.parentFile?.mkdirs()
                        val copy = "cp ${shellQuote("/data/powos/root$path")} ${shellQuote(file.path)} && chmod 644 ${shellQuote(file.path)}"
                        runCatching { andro.marchy.RootShell.run(copy) }
                    }
                    main.post {
                        fetching -= family
                        if (file.length() > 0) onLoaded() else Log.w(TAG, "no font file for $family (fc-match: $path)")
                    }
                }.start()
            }
            return null
        }

        /** [font] (else the system's monospace font, Droid Sans Mono), then the Nerd Font symbols. */
        private fun withSymbols(
            context: Context,
            font: Font?,
        ): Typeface? =
            runCatching {
                val primary = font ?: SystemFonts.getAvailableFonts().first { it.file?.name?.startsWith("DroidSansMono") == true }
                    .let { Font.Builder(it.file!!).build() }
                val symbols = Font.Builder(context.resources, R.font.nerd_symbols).build()
                // The cells measure the first family, so that is the monospace font.
                Typeface.CustomFallbackBuilder(FontFamily.Builder(primary).build())
                    .addCustomFallback(FontFamily.Builder(symbols).build())
                    .setSystemFallback("monospace")
                    .build()
            }.getOrNull()
    }
}
