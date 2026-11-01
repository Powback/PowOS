package dev.omalauncher.shell

/**
 * Quick pages (the user: "we don't need to open the whole Settings... I'd love to use the side launcher to launch e.g.
 * Wi-Fi settings this way"): ONE settings page from any app - com.oplus.wirelesssettings' Wi-Fi / hotspot / Bluetooth,
 * a com.android.settings page or fragment, any other exported settings action - opens as a compact card on home's page
 * (ui/quickpage.tsx) on its own trusted display, never the whole Settings window and never a bare OnePlus freeform
 * window. "Settings" opened as an app keeps its full window. Native panels (internet / NFC / Wi-Fi panel, volume) stay
 * Android's own sheets (docs/DESIGN-LANGUAGE.md, known exception). Pure, so the JVM tests drive the decision.
 */
internal object QuickPageRoute {
    const val SETTINGS = "com.android.settings"

    // android.content.Intent's flag values (constants here so the JVM tests need no Android stubs).
    const val FLAG_NEW_TASK = 0x10000000
    const val FLAG_MULTIPLE_TASK = 0x08000000
    const val FLAG_EXCLUDE_FROM_RECENTS = 0x00800000

    /** What a settings launch is: one page (a quick page), a native panel (its own sheet), or an app (its full window). */
    enum class Kind { QUICK, PANEL, APP }

    /** Where it goes. */
    enum class Route {
        /** A quick page: its own trusted display under home's card (unfolded ~440 dp at its anchor, folded a sheet). */
        QUICK_WINDOW,

        /** Android's own sheet, launched plain (a panel). */
        NATIVE_SHEET,

        /** The safety net: full screen on the main display - never a freeform window. */
        FULL_SCREEN,

        /** As any app launch (web windows off): AppWindows' usual way. */
        APP_DEFAULT,
    }

    /** [action] / [className] of a launch from [pkg]; [asApp]: "Settings" itself (its launcher), never a single page. */
    fun kind(
        pkg: String?,
        action: String?,
        className: String?,
        asApp: Boolean,
    ): Kind =
        when {
            pkg == null || asApp -> Kind.APP
            isPanel(action, className) -> Kind.PANEL
            action == "android.settings.SETTINGS" || action == "android.intent.action.MAIN" -> Kind.APP
            else -> Kind.QUICK
        }

    private fun isPanel(
        action: String?,
        className: String?,
    ): Boolean =
        action?.startsWith("android.settings.panel.action.") == true ||
            className?.endsWith(".SettingsPanelActivity") == true ||
            className?.endsWith("VolumePanelActivity") == true

    /**
     * [kind]'s route with web windows on ([webWindows]: `powos_web_windows` = 1) or not - folded OR unfolded (the manager,
     * 11-01: "web windows being unfolded-only is no excuse"). Quick pages are the web-window layer's first folded user:
     * one card display (folded: full width minus 16 dp, rising above the bar); every other folded launch still goes
     * AppWindows' way (WebWindowLaunch.route / openOnHome stay on the unfolded web desktop).
     */
    fun decide(
        kind: Kind,
        webWindows: Boolean,
    ): Route =
        when {
            kind == Kind.PANEL -> Route.NATIVE_SHEET
            kind == Kind.QUICK && webWindows -> Route.QUICK_WINDOW
            else -> Route.APP_DEFAULT
        }

    /**
     * A launch whose web window / quick page couldn't be made (no home page, no display in time, refused): with web
     * windows on ([webWindows], folded too) FULL SCREEN, logged - never Tasks.freeformOptions (the bare OnePlus freeform
     * window with no title bar, never adopted, 10-31 hotspot). Elsewhere the usual way.
     */
    fun afterFailure(webWindows: Boolean): Route = if (webWindows) Route.FULL_SCREEN else Route.APP_DEFAULT

    /**
     * A quick page's intent flags: its own task, not in recents; com.android.settings pages also MULTIPLE_TASK so they
     * never join (and hijack) the main Settings task / window.
     */
    fun flags(pkg: String): Int = FLAG_NEW_TASK or FLAG_EXCLUDE_FROM_RECENTS or (if (pkg == SETTINGS) FLAG_MULTIPLE_TASK else 0)

    /** The quick flags off again: pop-out relaunches the same page in its app's normal window (recents, dock). */
    fun poppedOut(flags: Int): Int = (flags and (FLAG_EXCLUDE_FROM_RECENTS or FLAG_MULTIPLE_TASK).inv()) or FLAG_NEW_TASK

    /** android.view.KeyEvent.KEYCODE_BACK (a constant here so the JVM tests need no Android stubs). */
    const val KEYCODE_BACK = 4

    /** An open quick page's card as Back sees it: its display (-1: none yet), closed, its page on screen ([shown]). */
    data class Card(
        val displayId: Int,
        val closed: Boolean,
        val shown: Boolean,
    )

    /**
     * Where a Back that reached home goes while quick page [cards] are open (the user, 11-01: "it's closing when returning
     * back"): the display of the card on screen - its page's own Back there pops the page's back stack (a sub-screen
     * goes back one screen; at the page's root the page finishes itself, its task goes, the card closes the bar's way:
     * WebWindows.confirmDead) - or null: no card on screen, Back is home's page's. A Back reaches home whenever display
     * 0 holds the top focus: the edge back gesture's own touch on display 0, a touch on the card's bar or home moved
     * it there - never the card's page then, and the page's back() had no card in it.
     */
    fun backDisplay(cards: List<Card>): Int? = cards.lastOrNull { !it.closed && it.shown && it.displayId >= 0 }?.displayId

    /** The display maker's (WebWindowsHost) line that sends Back to display [displayId]: a down and an up there. */
    fun backLine(displayId: Int): String = "key $displayId $KEYCODE_BACK"

    /** A quick page's held-launch key and page key ("q:<token>"): never an app's ("a:...") or its package. */
    fun key(token: String): String = "q:$token"
}
