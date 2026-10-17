package dev.omalauncher

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import dev.omalauncher.linux.RootedGuest
import dev.omalauncher.ui.ExtraKeys
import dev.omalauncher.ui.KeyboardBridge
import dev.omalauncher.ui.KeyboardSink
import dev.omalauncher.ui.Mono
import dev.omalauncher.ui.Palette
import dev.omalauncher.ui.PtyTerminal
import dev.omalauncher.ui.applySystemBars
import dev.omalauncher.ui.extraKeysWanted

/**
 * A PowOS terminal as its own Android task (rooted mode): what the launcher's terminal() opens - a terminal app in the
 * drawer, a widget's terminal(...), an agent session. The same terminal as the home-screen tiles ([PtyTerminal]: the
 * launcher draws it, on a pty of its own, running PowOS's shell through su), so it works folded too, where the PowOS
 * desktop steps aside, and without handing PowOS's window buffers to the app (which SELinux doesn't allow).
 */
class PowosTerminalActivity : ComponentActivity() {
    private val runtime get() = (application as App).runtime
    private var pty: PtyTerminal? = null

    /** This terminal's keys: the launcher keyboard's bridge, aimed at the pty instead of a Wayland window. */
    private var bridge: KeyboardBridge? = null

    /** The soft keyboard's owner. */
    private var sink: KeyboardSink? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val command = intent.getStringExtra(EXTRA_COMMAND) ?: RootedGuest.TERMINAL_SHELL
        val title = intent.getStringExtra(EXTRA_TITLE) ?: "Terminal"
        applySystemBars(this, Palette.isLight)
        @Suppress("DEPRECATION")
        setTaskDescription(ActivityManager.TaskDescription(title, null, Palette.background.toArgb()))
        val keys = KeyboardBridge(runtime.wm)
        bridge = keys
        val terminal =
            PtyTerminal(
                applicationContext,
                command,
                textPixels = { runtime.terminalFont.pixels(runtime.terminalFont.size) },
                fontFamily = { runtime.terminalFont.family },
                onTap = { sink?.show() },
                onExit = { finishAndRemoveTask() },
            )
        pty = terminal
        keys.target = terminal
        setContent {
            LaunchedEffect(Palette.isLight) { applySystemBars(this@PowosTerminalActivity, Palette.isLight) }
            val palette = Palette.current
            LaunchedEffect(palette, runtime.terminalFont.size, runtime.terminalFont.family) { terminal.restyle() }
            BackHandler { moveTaskToBack(true) }
            val pad = with(LocalDensity.current) { runtime.terminalFont.padPixels.toDp() }
            Box(
                Modifier
                    .fillMaxSize()
                    .background(Palette.background)
                    .systemBarsPadding()
                    .imePadding(),
            ) {
                AndroidView(
                    factory = { KeyboardSink(it, keys).also { v -> sink = v } },
                    modifier = Modifier.size(1.dp),
                )
                Column(Modifier.fillMaxSize()) {
                    Box(Modifier.weight(1f).fillMaxWidth()) {
                        AndroidView(
                            factory = { terminal.newView(it) },
                            onRelease = { terminal.release(it) },
                            modifier = Modifier.fillMaxSize().padding(pad),
                        )
                        Box(
                            Modifier
                                .align(Alignment.BottomEnd)
                                .padding(12.dp)
                                .size(40.dp)
                                .background(Palette.overlay, CircleShape)
                                .clickable { sink?.toggle() },
                            contentAlignment = Alignment.Center,
                        ) {
                            BasicText("⌨", style = Mono.copy(color = Palette.foreground))
                        }
                    }
                    // Below the terminal rather than over it, so its rows shrink and nothing hides behind the keys.
                    if (extraKeysWanted()) ExtraKeys(keys)
                }
            }
        }
    }

    private var keyboardShown = false

    /** The keyboard comes up as the terminal opens (typing is what it's for), once its window has the focus. */
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && !keyboardShown) sink?.let { it.show(); keyboardShown = true }
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (bridge?.handle(event) == true) return true
        return super.dispatchKeyEvent(event)
    }

    /** Swiping the card away in Recents ends the shell, like closing an app. */
    override fun onDestroy() {
        super.onDestroy()
        if (isFinishing) pty?.finish()
    }

    companion object {
        private const val EXTRA_COMMAND = "command"
        private const val EXTRA_TITLE = "title"

        /** Opens [command] (null: PowOS's terminal, its tmux picker) as a terminal task titled [title]. */
        fun open(
            context: Context,
            command: String?,
            title: String,
        ) {
            context.startActivity(
                Intent(context, PowosTerminalActivity::class.java)
                    .putExtra(EXTRA_COMMAND, command)
                    .putExtra(EXTRA_TITLE, title)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
    }
}
