package dev.omalauncher.shell

import android.app.Activity
import android.app.ActivityManager
import android.app.role.RoleManager
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.util.Log
import android.view.KeyEvent
import androidx.compose.runtime.snapshotFlow
import dev.omalauncher.App
import dev.omalauncher.BuildConfig
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/**
 * The launcher: a full-screen [ShellHost] over the wallpaper (the shell's home), as the Home app - the only one (the
 * Compose launcher it replaced is gone, docs/COMPOSE-REMOVAL.md). Home pressed and Back go to the page; the widgets'
 * sources run while it shows.
 */
class ShellActivity : Activity() {
    private lateinit var host: ShellHost
    private val scope: CoroutineScope = MainScope()

    private val runtime get() = (application as App).runtime

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Each home made, and why (the manager saw home's task change: an app update, a recreation, a second home).
        Log.i(TAG, "home created: task $taskId, restored ${savedInstanceState != null}, intent ${intent.component?.shortClassName} ${intent.categories} ${intent.extras?.keySet()}, from ${referrer}")
        if (toHome()) return
        dropOtherHomes()
        // The launcher's runtime (themes, widgets, the PowOS session); started once.
        runtime.start()
        // The shell has no first-run screen (the Compose launcher's welcome): home shows at once, and the rest of
        // Omarchy's themes download behind it, as they did once the welcome was done.
        if (!runtime.launcherReady) runtime.finishWelcome()
        // Rooted mode: the PowOS session with it (terminals, PowOS apps, folding run in it), as the desktop starts it -
        // after a reboot or an update the launcher is often the first thing that runs. Already running: nothing.
        if (andro.marchy.RootMode.enabled()) andro.marchy.SessionService.start(this)
        window.setDecorFitsSystemWindows(false)
        host = ShellHost(this, this, runtime)
        setContentView(host.web)
        // The switcher is a layer of this page: the gestures and the overview button reach it here.
        val blur = WindowBlur(window)
        dev.omalauncher.system.Switcher.attach(host.bridge, { host.highRefresh?.boost(it) }, blur::set)
        // Opened from the agents' notification: the page opens the Agents screen.
        dev.omalauncher.AgentsSpool.opened(intent)
        handleDebugExec(intent)
        // Asked once nothing else is in front: not over the notification permission dialog a Linux install brings up.
        scope.launch {
            snapshotFlow { runtime.themes.loaded }.first { it }
            if (!isFinishing) requestHomeRole()
        }
    }

    /**
     * Opened by its component (its app entry, a notification, `am start -n`) while it's the home screen: on to the
     * home screen's own instance, extras and all, and gone - one shell page, not a second WebView in a task of its own
     * (Android keeps a home activity and the same activity started as an app in different tasks, singleTask or not).
     * A HOME intent without a component is a home launch from any app; it resolves to .HomeShell, the one enabled.
     */
    private fun toHome(): Boolean {
        if (intent.hasCategory(Intent.CATEGORY_HOME)) return false
        val alias = android.content.ComponentName(this, "andro.marchy.HomeShell")
        if (packageManager.getComponentEnabledSetting(alias) != PackageManager.COMPONENT_ENABLED_STATE_ENABLED) return false
        startActivity(
            Intent(Intent.ACTION_MAIN)
                .addCategory(Intent.CATEGORY_HOME)
                .setPackage(packageName)
                .putExtras(intent)
                .putExtra(EXTRA_REDIRECTED, true)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        finish()
        return true
    }

    /**
     * Any other task of this activity goes: a home task left from before (an update, a relaunch as home on another
     * display or after an alias switch) kept its own WebView, and two homes at different sizes resized the hosted
     * Android widgets back and forth. One home page, this one.
     */
    private fun dropOtherHomes() {
        val mine = javaClass.name
        for (task in getSystemService(ActivityManager::class.java).appTasks) {
            val info = runCatching { task.taskInfo }.getOrNull() ?: continue
            if (info.taskId == taskId) continue
            val base = info.baseActivity ?: info.baseIntent.component
            // By the activity (the alias resolves to it): the HOME alias's tasks and any started by name.
            val ours = base?.className == mine || base?.className == "andro.marchy.HomeShell" || info.topActivity?.className == mine
            if (ours) runCatching { task.finishAndRemoveTask() }.onSuccess { Log.i(TAG, "dropped a second home task ${info.taskId}") }
        }
    }

    /** Asks once to become the default home app; Android shows its own chooser. (Rooted PowOS sets it itself.) */
    private fun requestHomeRole() {
        val roles = getSystemService(RoleManager::class.java)
        if (!roles.isRoleAvailable(RoleManager.ROLE_HOME) || roles.isRoleHeld(RoleManager.ROLE_HOME)) return
        val prefs = getSharedPreferences("launcher", MODE_PRIVATE)
        if (prefs.getBoolean("home_role_asked", false)) return
        prefs.edit().putBoolean("home_role_asked", true).apply()
        @Suppress("DEPRECATION")
        startActivityForResult(roles.createRequestRoleIntent(RoleManager.ROLE_HOME), HOME_ROLE_REQUEST)
    }

    /**
     * Debug builds: `adb shell am start -n com.powos.app/dev.omalauncher.shell.ShellActivity --es exec foot`, `--es app
     * org.kde.dolphin` to open a Linux app as a launcher tap does (its desktop id), or `--es theme kanagawa` to apply a
     * theme (scripts/collage-captures.sh).
     */
    private fun handleDebugExec(intent: Intent) {
        if (!BuildConfig.DEBUG) return
        intent.getStringExtra("exec")?.let(runtime::launch)
        intent.getStringExtra("app")?.let { id ->
            scope.launch {
                snapshotFlow { runtime.linuxApps.firstOrNull { it.id == id } }.first { it != null }?.let(runtime::launch)
            }
        }
        intent.getStringExtra("theme")?.let { name ->
            scope.launch {
                snapshotFlow { runtime.themes.loaded }.first { it }
                runtime.themes.themes.firstOrNull { it.name == name }?.let { runtime.themes.apply(it) } ?: Log.w("debug", "no theme $name")
            }
        }
    }

    override fun onResume() {
        super.onResume()
        runtime.wm.focus(null)
        removeStaleWindowTasks()
        // Back from the engine's installer (or anything else): whether PowOS is installed now.
        runtime.refreshLinuxState()
        // The user may have set or replaced the wallpaper while we were in the background.
        scope.launch { runtime.themes.refreshLiveWallpaper() }
    }

    /** Drops Recents cards whose Linux window no longer exists (app exited or process restarted). */
    private fun removeStaleWindowTasks() {
        for (task in getSystemService(ActivityManager::class.java).appTasks) {
            val base = runCatching { task.taskInfo?.baseIntent }.getOrNull() ?: continue
            // By its data rather than its class: windows start through aliases too.
            if (base.data?.let { it.scheme == "omarchy" && it.host == "window" } != true) continue
            // A window that just closed removes its own task meanwhile; finishing it again throws.
            if (runtime.wm.windowByHandle(base.data?.lastPathSegment) == null) runCatching { task.finishAndRemoveTask() }
        }
    }

    /** Super+Enter opens a terminal, as in Omarchy (the page has the rest of the keys). */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.isMetaPressed && event.action == KeyEvent.ACTION_DOWN && event.keyCode == KeyEvent.KEYCODE_ENTER) {
            runtime.terminal(null, "Terminal")
            return true
        }
        return super.dispatchKeyEvent(event)
    }

    /**
     * Home pressed while the shell is home already (singleTask: the intent comes back here): the page closes what's
     * open and goes to the first page, as a stock launcher does.
     */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Home pressed - not a notification's or the app entry's way here (toHome), which carries what it opens.
        // Nor the recents transition's launch of home or the switcher's (Switcher.EXTRA_RECENTS): its layer is coming up.
        val recents = intent.getBooleanExtra(dev.omalauncher.system.Switcher.EXTRA_RECENTS, false)
        if (intent.hasCategory(Intent.CATEGORY_HOME) && !intent.hasExtra(EXTRA_REDIRECTED) && !recents) host.bridge.emit("system.home", null)
        dev.omalauncher.AgentsSpool.opened(intent)
        handleDebugExec(intent)
    }

    /** Back goes to the page: it closes the drawer, a folder or edit mode. A home screen has nowhere to go back to. */
    @Deprecated("Back reaches the page instead", ReplaceWith(""))
    override fun onBackPressed() {
        host.bridge.emit("system.back", null)
    }

    // A home screen showing: widgets' sources run (they pause while no home is visible), the guest's on-screen helpers.
    override fun onStart() {
        super.onStart()
        if (::host.isInitialized) dev.omalauncher.system.Switcher.homeStarted(host.bridge)
        // A hosted widget that lost its drawing while home was away (its provider killed, a display gone): again.
        AppWidgets.get(this).heal()
        runtime.widgets.homeStarted()
        runtime.screenStarted()
    }

    override fun onStop() {
        super.onStop()
        // Out of sight: the switcher layer goes (an app was opened from it, or came up over it).
        if (::host.isInitialized) dev.omalauncher.system.Switcher.homeStopped(host.bridge)
        // An app was just opened from home: it moves to the front of the recent apps, out of sight.
        runtime.usage.settle()
        runtime.widgets.homeStopped()
        runtime.screenStopped()
    }

    /** The photo picker's answer (a background of one's own, from Style). */
    @Deprecated("The page's requests come back here", ReplaceWith(""))
    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == ShellScreens.PICK_IMAGE_REQUEST) host.bridge.screens.imagePicked(data?.data?.takeIf { resultCode == RESULT_OK })
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == ShellBridge.MIC_REQUEST) host.bridge.micPermission(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
    }

    override fun onDestroy() {
        Log.i(TAG, "home destroyed: task $taskId, finishing $isFinishing, config change $isChangingConfigurations")
        scope.cancel()
        // Not there when it went on to the home screen's instance (toHome).
        if (::host.isInitialized) {
            dev.omalauncher.system.Switcher.detach(host.bridge)
            host.destroy()
        }
        super.onDestroy()
    }

    private companion object {
        const val HOME_ROLE_REQUEST = 1
        const val TAG = "PowosShell"

        /** On a HOME intent that [toHome] sent: not Home pressed. */
        const val EXTRA_REDIRECTED = "dev.omalauncher.shell.redirected"
    }
}
