package dev.omalauncher.shell

import android.app.Activity
import android.os.Bundle
import android.view.ViewGroup
import dev.omalauncher.system.Switcher
import dev.omalauncher.system.Tasks

/**
 * The system's recents activity (the system module's overlay names it in config_recentsComponentName: the recents
 * role's package and uid come from it). The switcher is a layer of a shell page (shell/ui/recents.tsx, [Switcher]):
 *
 * - PowOS's web home is the home app: the layer is home's page; this only brings home up with it shown, and is gone.
 * - The desktop is home (no web page there): this shows the layer itself, on the warm recents page - the window a
 *   swipe up's recents transition launches behind the app, as Quickstep's fallback recents activity. Gone once it's
 *   out of sight (an app opened, home brought up).
 */
class SwitcherActivity : Activity() {
    private var host: ShellHost? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Switcher.homeIsShell(this)) {
            // The app under this activity (it never drew) is still the visible one.
            Switcher.show(this, Tasks.visible(this))
            finish()
            return
        }
        window.setDecorFitsSystemWindows(false)
        val h = Switcher.page(this)
        (h.web.parent as? ViewGroup)?.removeView(h.web)
        setContentView(h.web)
        val refresh = HighRefresh(window, h.web)
        Switcher.attachHost({ refresh.boost(it) }, WindowBlur(window)::set)
        host = h
    }

    override fun onStart() {
        super.onStart()
        host?.let { Switcher.homeStarted(it.bridge) }
    }

    override fun onStop() {
        super.onStop()
        host?.let { Switcher.homeStopped(it.bridge) }
        // Not a screen to come back to: the next swipe or overview press brings it up afresh.
        if (host != null && !isChangingConfigurations) finish()
    }

    /** Back goes to the page (back to the app the switcher was opened over, or home). */
    @Deprecated("Back reaches the page instead", ReplaceWith(""))
    override fun onBackPressed() {
        host?.bridge?.emit("system.back", null)
    }

    override fun onDestroy() {
        // The page stays warm for the next time; only this window lets go of it (unless a newer one has it already).
        host?.let { h -> (h.web.parent as? ViewGroup)?.takeIf { it.rootView === window.decorView }?.removeView(h.web) }
        host = null
        super.onDestroy()
    }
}
