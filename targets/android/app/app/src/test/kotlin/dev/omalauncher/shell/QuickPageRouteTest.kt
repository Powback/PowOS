package dev.omalauncher.shell

import dev.omalauncher.shell.QuickPageRoute.Kind
import dev.omalauncher.shell.QuickPageRoute.Route
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/** Quick pages: one settings page as a compact card, Settings itself as its full window, panels as native sheets. */
class QuickPageRouteTest {
    @Test
    fun aSinglePageFromAnyAppIsAQuickPageOnTheWebDesktop() {
        val hotspot = QuickPageRoute.kind("com.oplus.wirelesssettings", "android.settings.OPLUS_WIFI_AP_SETTINGS", "com.android.settings.SettingsActivity", asApp = false)
        val display = QuickPageRoute.kind("com.android.settings", "android.settings.DISPLAY_SETTINGS", null, asApp = false)
        val fragment = QuickPageRoute.kind("com.android.settings", null, "com.android.settings.SubSettings", asApp = false)
        for (k in listOf(hotspot, display, fragment)) {
            assertEquals(Kind.QUICK, k)
            assertEquals(Route.QUICK_WINDOW, QuickPageRoute.decide(k, webDesktop = true))
        }
    }

    @Test
    fun settingsOpenedAsAnAppKeepsItsFullWindow() {
        assertEquals(Kind.APP, QuickPageRoute.kind("com.android.settings", "android.intent.action.MAIN", null, asApp = true))
        assertEquals(Kind.APP, QuickPageRoute.kind("com.android.settings", "android.settings.SETTINGS", null, asApp = false))
        assertEquals(Route.APP_DEFAULT, QuickPageRoute.decide(Kind.APP, webDesktop = true))
    }

    @Test
    fun nativePanelsStayNativeSheets() {
        assertEquals(Kind.PANEL, QuickPageRoute.kind("com.android.settings", "android.settings.panel.action.INTERNET_CONNECTIVITY", null, asApp = false))
        assertEquals(Kind.PANEL, QuickPageRoute.kind("com.oplus.sound", null, "com.oplus.VolumePanelActivity", asApp = false))
        assertEquals(Route.NATIVE_SHEET, QuickPageRoute.decide(Kind.PANEL, webDesktop = true))
        assertEquals(Route.NATIVE_SHEET, QuickPageRoute.decide(Kind.PANEL, webDesktop = false))
    }

    @Test
    fun offTheWebDesktopAPageLaunchesAsBefore() {
        assertEquals(Route.APP_DEFAULT, QuickPageRoute.decide(Kind.QUICK, webDesktop = false))
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
    fun aRouteFailureOnTheWebDesktopIsFullScreenNeverFreeform() {
        assertEquals(Route.FULL_SCREEN, QuickPageRoute.afterFailure(webDesktop = true))
        assertEquals(Route.APP_DEFAULT, QuickPageRoute.afterFailure(webDesktop = false))
    }

    @Test
    fun quickKeysNeverCollideWithAnAppsPackageOrKey() {
        assertEquals("q:7", QuickPageRoute.key("7"))
        assertNotEquals("com.android.settings", QuickPageRoute.key("com.android.settings"))
    }
}
