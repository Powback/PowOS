package dev.omalauncher.shell

import dev.omalauncher.shell.QuickPageRoute.Kind
import dev.omalauncher.shell.QuickPageRoute.Route
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/** Quick pages: one settings page as a compact card, Settings itself as its full window, panels as native sheets. */
class QuickPageRouteTest {
    @Test
    fun aSinglePageFromAnyAppIsAQuickPageWithWebWindowsOn() {
        val hotspot = QuickPageRoute.kind("com.oplus.wirelesssettings", "android.settings.OPLUS_WIFI_AP_SETTINGS", "com.android.settings.SettingsActivity", asApp = false)
        val display = QuickPageRoute.kind("com.android.settings", "android.settings.DISPLAY_SETTINGS", null, asApp = false)
        val fragment = QuickPageRoute.kind("com.android.settings", null, "com.android.settings.SubSettings", asApp = false)
        for (k in listOf(hotspot, display, fragment)) {
            assertEquals(Kind.QUICK, k)
            assertEquals(Route.QUICK_WINDOW, QuickPageRoute.decide(k, webWindows = true))
        }
    }

    @Test
    fun settingsOpenedAsAnAppKeepsItsFullWindow() {
        assertEquals(Kind.APP, QuickPageRoute.kind("com.android.settings", "android.intent.action.MAIN", null, asApp = true))
        assertEquals(Kind.APP, QuickPageRoute.kind("com.android.settings", "android.settings.SETTINGS", null, asApp = false))
        assertEquals(Route.APP_DEFAULT, QuickPageRoute.decide(Kind.APP, webWindows = true))
    }

    @Test
    fun nativePanelsStayNativeSheets() {
        assertEquals(Kind.PANEL, QuickPageRoute.kind("com.android.settings", "android.settings.panel.action.INTERNET_CONNECTIVITY", null, asApp = false))
        assertEquals(Kind.PANEL, QuickPageRoute.kind("com.oplus.sound", null, "com.oplus.VolumePanelActivity", asApp = false))
        assertEquals(Route.NATIVE_SHEET, QuickPageRoute.decide(Kind.PANEL, webWindows = true))
        assertEquals(Route.NATIVE_SHEET, QuickPageRoute.decide(Kind.PANEL, webWindows = false))
    }

    @Test
    fun withWebWindowsOffAPageLaunchesAsBefore() {
        assertEquals(Route.APP_DEFAULT, QuickPageRoute.decide(Kind.QUICK, webWindows = false))
    }

    /**
     * Folded (no floating windows, AppWindows.webDesktop false) a page is still a quick page: the route only asks whether
     * web windows are on, never the screen's width (the manager, 11-01: "web windows being unfolded-only is no excuse").
     */
    @Test
    fun foldedASinglePageIsStillAQuickPageNeverTheOldFoldedLaunch() {
        val wifi = QuickPageRoute.kind("com.oplus.wirelesssettings", "android.settings.WIFI_SETTINGS", null, asApp = false)
        val folded = QuickPageRoute.decide(wifi, webWindows = true)
        assertEquals(Route.QUICK_WINDOW, folded)
        assertEquals(Route.FULL_SCREEN, QuickPageRoute.afterFailure(webWindows = true))
        // Settings opened as an app, folded: its usual launch (the old folded path stays for everything but quick pages).
        assertEquals(Route.APP_DEFAULT, QuickPageRoute.decide(Kind.APP, webWindows = true))
    }

    @Test
    fun quickFlagsAreNewTaskExcludedFromRecentsAndMultipleTaskOnlyForSettings() {
        val settings = QuickPageRoute.flags("com.android.settings")
        assertEquals(QuickPageRoute.FLAG_NEW_TASK or QuickPageRoute.FLAG_EXCLUDE_FROM_RECENTS or QuickPageRoute.FLAG_MULTIPLE_TASK, settings)
        val wireless = QuickPageRoute.flags("com.oplus.wirelesssettings")
        assertEquals(QuickPageRoute.FLAG_NEW_TASK or QuickPageRoute.FLAG_EXCLUDE_FROM_RECENTS, wireless)
    }

    @Test
    fun popOutDropsTheQuickFlags() {
        val out = QuickPageRoute.poppedOut(QuickPageRoute.flags("com.android.settings"))
        assertEquals(QuickPageRoute.FLAG_NEW_TASK, out)
    }

    @Test
    fun aRouteFailureWithWebWindowsOnIsFullScreenNeverFreeform() {
        assertEquals(Route.FULL_SCREEN, QuickPageRoute.afterFailure(webWindows = true))
        assertEquals(Route.APP_DEFAULT, QuickPageRoute.afterFailure(webWindows = false))
    }

    @Test
    fun quickKeysNeverCollideWithAnAppsPackageOrKey() {
        assertEquals("q:7", QuickPageRoute.key("7"))
        assertNotEquals("com.android.settings", QuickPageRoute.key("com.android.settings"))
    }

    @Test
    fun backWithACardOnScreenGoesToTheCardsPageNotHome() {
        val card = QuickPageRoute.Card(displayId = 101, closed = false, shown = true)
        // The page's own Back: a sub-screen goes back one screen; at its root the page finishes and the card closes.
        assertEquals(101, QuickPageRoute.backDisplay(listOf(card)))
        assertEquals("key 101 4", QuickPageRoute.backLine(101))
    }

    @Test
    fun backWithNoCardOnScreenIsHomesPage() {
        assertEquals(null, QuickPageRoute.backDisplay(emptyList()))
        // Closed, not on screen (another page, under the switcher) or with no display yet: home's page has Back.
        assertEquals(null, QuickPageRoute.backDisplay(listOf(QuickPageRoute.Card(101, closed = true, shown = true))))
        assertEquals(null, QuickPageRoute.backDisplay(listOf(QuickPageRoute.Card(101, closed = false, shown = false))))
        assertEquals(null, QuickPageRoute.backDisplay(listOf(QuickPageRoute.Card(-1, closed = false, shown = true))))
    }
}
