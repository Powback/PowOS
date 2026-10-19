package dev.omalauncher.shell

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.view.ViewGroup
import dev.omalauncher.system.Switcher
import dev.omalauncher.system.SwitcherSlot

/**
 * The switcher's window: Android's recents activity when PowOS is the recents provider (the system module's overlay
 * sets config_recentsComponentName to it, so the system treats it as the recents screen). A thin host: it shows the
 * warm switcher page ([Switcher]) over the wallpaper; the page lists the tasks, switches and removes them.
 *
 * Gone once it's not on screen (an app switched to, Home): the page stays warm, the next press shows it again.
 */
class SwitcherActivity : Activity() {
    private var host: ShellHost? = null
    private var slot: SwitcherSlot? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.setDecorFitsSystemWindows(false)
        val h = Switcher.page(this)
        (h.web.parent as? ViewGroup)?.removeView(h.web)
        val mine =
            object : SwitcherSlot {
                override fun close() = finish()

                override fun home() {
                    startActivity(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    finish()
                }
            }
        h.bridge.switcher = mine
        slot = mine
        host = h
        setContentView(h.web)
    }

    override fun onResume() {
        super.onResume()
        Switcher.showing = this
        host?.bridge?.emit("switcher.shown", Switcher.shownEvent())
    }

    override fun onPause() {
        super.onPause()
        if (Switcher.showing === this) Switcher.showing = null
    }

    override fun onStop() {
        super.onStop()
        // Not a screen to come back to: the next overview press opens it afresh, with the tasks as they are then.
        if (!isChangingConfigurations) finish()
    }

    /** Back goes to the page (it goes back to the app the switcher was opened over, or home). */
    @Deprecated("Back reaches the page instead", ReplaceWith(""))
    override fun onBackPressed() {
        host?.bridge?.emit("system.back", null)
    }

    override fun onDestroy() {
        // The page stays warm for the next time; only this window lets go of it (unless a newer one has it already).
        host?.let { h ->
            (h.web.parent as? ViewGroup)?.takeIf { it.rootView === window.decorView }?.removeView(h.web)
            if (h.bridge.switcher === slot) h.bridge.switcher = null
        }
        host = null
        super.onDestroy()
    }
}
