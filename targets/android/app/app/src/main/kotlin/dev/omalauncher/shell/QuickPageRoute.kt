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
        /** A quick page: its own trusted display under a compact card on home's page. */
        QUICK_WINDOW,

        /** Android's own sheet, launched plain (a panel). */
        NATIVE_SHEET,

        /** The safety net: full screen on the main display - never a freeform window. */
        FULL_SCREEN,

        /** As any app launch (folded, web windows off): AppWindows' usual way. */
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

    /** [kind]'s route on the web desktop ([webDesktop]: unfolded, web windows on) or not. */
    fun decide(
        kind: Kind,
        webDesktop: Boolean,
    ): Route =
        when {
            kind == Kind.PANEL -> Route.NATIVE_SHEET
            kind == Kind.QUICK && webDesktop -> Route.QUICK_WINDOW
            else -> Route.APP_DEFAULT
        }

    /**
     * A launch whose web window / quick page couldn't be made (no home page, no display in time, refused): on the web
     * desktop FULL SCREEN, logged - never Tasks.freeformOptions (the bare OnePlus freeform window with no title bar,
     * never adopted, 10-31 hotspot). Elsewhere the usual way.
     */
    fun afterFailure(webDesktop: Boolean): Route = if (webDesktop) Route.FULL_SCREEN else Route.APP_DEFAULT

    /**
     * A quick page's intent flags: its own task, not in recents; com.android.settings pages also MULTIPLE_TASK so they
     * never join (and hijack) the main Settings task / window.
     */
    fun flags(pkg: String): Int = FLAG_NEW_TASK or FLAG_EXCLUDE_FROM_RECENTS or (if (pkg == SETTINGS) FLAG_MULTIPLE_TASK else 0)

    /** The quick flags off again: pop-out relaunches the same page in its app's normal window (recents, dock). */
    fun poppedOut(flags: Int): Int = (flags and (FLAG_EXCLUDE_FROM_RECENTS or FLAG_MULTIPLE_TASK).inv()) or FLAG_NEW_TASK

    /** A quick page's held-launch key and page key ("q:<token>"): never an app's ("a:...") or its package. */
    fun key(token: String): String = "q:$token"
}
