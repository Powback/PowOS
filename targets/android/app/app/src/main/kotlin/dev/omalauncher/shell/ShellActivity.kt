package dev.omalauncher.shell

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import dev.omalauncher.App

/**
 * The launcher as a web UI: a full-screen [ShellHost] over the wallpaper (the shell's home), as the Home app. Home
 * pressed and Back go to the page; the widgets' sources run while it shows.
 */
class ShellActivity : Activity() {
    private lateinit var host: ShellHost

    private val runtime get() = (application as App).runtime

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The launcher's runtime (themes, widgets, the PowOS session), as MainActivity starts it; started once.
        runtime.start()
        // Rooted mode: the PowOS session with it (terminals, PowOS apps, folding run in it), as the desktop starts it -
        // after a reboot or an update the launcher is often the first thing that runs. Already running: nothing.
        if (andro.marchy.RootMode.enabled()) andro.marchy.SessionService.start(this)
        window.setDecorFitsSystemWindows(false)
        host = ShellHost(this, this, runtime)
        setContentView(host.web)
        // Opened from the agents' notification: the page opens the Agents screen.
        dev.omalauncher.AgentsSpool.opened(intent)
    }

    /**
     * Home pressed while the shell is home already (singleTask: the intent comes back here): the page closes what's
     * open and goes to the first page, as a stock launcher does.
     */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.hasCategory(Intent.CATEGORY_HOME)) host.bridge.emit("system.home", null)
        dev.omalauncher.AgentsSpool.opened(intent)
    }

    /** Back goes to the page: it closes the drawer, a folder or edit mode. A home screen has nowhere to go back to. */
    @Deprecated("Back reaches the page instead", ReplaceWith(""))
    override fun onBackPressed() {
        host.bridge.emit("system.back", null)
    }

    // A home screen showing: widgets' sources run (they pause while no home is visible).
    override fun onStart() {
        super.onStart()
        runtime.widgets.homeStarted()
    }

    override fun onStop() {
        super.onStop()
        runtime.widgets.homeStopped()
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
        host.destroy()
        super.onDestroy()
    }
}
