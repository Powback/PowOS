package dev.omalauncher.shell

import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.ui.Modifier
import dev.omalauncher.App
import dev.omalauncher.ui.AgentsScreen
import dev.omalauncher.ui.GesturesScreen
import dev.omalauncher.ui.LicensesScreen
import dev.omalauncher.ui.LinuxScreen
import dev.omalauncher.ui.PackagesScreen
import dev.omalauncher.ui.Palette
import dev.omalauncher.ui.SettingsScreen
import dev.omalauncher.ui.StoreScreen
import dev.omalauncher.ui.StyleScreen
import dev.omalauncher.ui.ThemeCatalogScreen
import dev.omalauncher.ui.applySystemBars

/**
 * The Compose launcher's own screens - the widget store, the theme catalog, the AUR store, Linux, coding agents,
 * settings - for the web shell, which hasn't got its own yet: one opens over home ([open]'s [screen]), the screens it
 * opens stack over it, and it finishes when the last one closes. HACK: a native stand-in; the real fix is each screen
 * ported to shell/ (phase 6), when this goes.
 */
class ShellScreensActivity : ComponentActivity() {
    private val runtime get() = (application as App).runtime

    /** The screens open, bottom first. */
    private val open = mutableStateListOf<String>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        applySystemBars(this, Palette.isLight)
        intent.getStringExtra(EXTRA_SCREEN)?.let(open::add)
        if (open.isEmpty()) return finish()
        setContent {
            BackHandler { close(open.last()) }
            Box(Modifier.fillMaxSize().background(Palette.background)) {
                for (screen in open.toList()) Screen(screen)
            }
        }
    }

    private fun show(screen: String) {
        open.remove(screen)
        open.add(screen)
    }

    private fun close(screen: String) {
        open.remove(screen)
        if (open.isEmpty()) finish()
    }

    @androidx.compose.runtime.Composable
    private fun Screen(screen: String) {
        val done = { close(screen) }
        when (screen) {
            STORE -> StoreScreen(runtime.widgets, runtime.agents.installed, runtime.widgets.activePage, runtime.themes.picked, onDismiss = done)
            THEMES -> ThemeCatalogScreen(runtime.themes, onDismiss = done)
            STYLE -> StyleScreen(runtime, onDismiss = done, onBrowse = { show(THEMES) })
            AUR -> PackagesScreen(runtime, onDismiss = done)
            LINUX -> LinuxScreen(runtime, onDismiss = done)
            AGENTS ->
                AgentsScreen(runtime, onDismiss = done, onOpen = { agent ->
                    done()
                    runtime.terminal(agent.bin, agent.name, agent)
                })
            SETTINGS ->
                SettingsScreen(
                    runtime,
                    onDismiss = done,
                    onStyle = { show(STYLE) },
                    onAgents = { show(AGENTS) },
                    onPackages = { show(AUR) },
                    onStore = { show(STORE) },
                    onLinux = { show(LINUX) },
                    onLicenses = { show(LICENSES) },
                    onGestures = { show(GESTURES) },
                )
            LICENSES -> LicensesScreen(onDismiss = done)
            GESTURES -> GesturesScreen(runtime, onDismiss = done)
            else -> done()
        }
    }

    companion object {
        private const val EXTRA_SCREEN = "screen"
        const val STORE = "store"
        const val THEMES = "themes"
        const val STYLE = "style"
        const val AUR = "aur"
        const val LINUX = "linux"
        const val AGENTS = "agents"
        const val SETTINGS = "settings"
        const val LICENSES = "licenses"
        const val GESTURES = "gestures"
        val ALL = setOf(STORE, THEMES, STYLE, AUR, LINUX, AGENTS, SETTINGS, LICENSES, GESTURES)

        fun open(
            context: Context,
            screen: String,
        ) {
            require(screen in ALL) { "no screen $screen" }
            context.startActivity(Intent(context, ShellScreensActivity::class.java).putExtra(EXTRA_SCREEN, screen))
        }
    }
}
