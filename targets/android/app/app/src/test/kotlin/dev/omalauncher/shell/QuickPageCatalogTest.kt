package dev.omalauncher.shell

import dev.omalauncher.shell.QuickPageCatalog.Candidate
import dev.omalauncher.shell.QuickPageCatalog.Resolved
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The control center's "add quick page" list: the device's own settings pages, their own names and pictures. */
class QuickPageCatalogTest {
    private val wifi = Candidate("android.settings.WIFI_SETTINGS", "Wi-Fi")
    private val net = Candidate("android.settings.WIRELESS_SETTINGS", "Network & internet")
    private val nfc = Candidate("android.settings.NFC_SETTINGS", "NFC")
    private val dev = Candidate("android.settings.APPLICATION_DEVELOPMENT_SETTINGS", "Developer options")

    @Test
    fun onlyPagesTheDeviceAnswersAreOffered() {
        val got = QuickPageCatalog.offer(listOf(wifi, nfc, dev)) { c -> if (c == nfc) null else "s/${c.action}" to Resolved(null, null, false) }
        assertEquals(listOf(wifi.action, dev.action), got.map { it.getString("action") })
    }

    @Test
    fun aPageReachedByTwoActionsIsOfferedOnce() {
        val got = QuickPageCatalog.offer(listOf(wifi, net)) { "s/Settings\$NetworkDashboardActivity" to Resolved("Network", null, false) }
        assertEquals(listOf(wifi.action), got.map { it.getString("action") })
    }

    @Test
    fun theActivitysOwnNameAndPictureWinTheFallbackOnlyWithoutThem() {
        val got = QuickPageCatalog.offer(listOf(wifi, dev)) { c ->
            if (c == wifi) "a" to Resolved("Wi‑Fi & internet", "data:image/png;base64,AA", true) else "b" to Resolved("", null, true)
        }
        assertEquals("Wi‑Fi & internet", got[0].getString("label"))
        assertEquals("data:image/png;base64,AA", got[0].getString("icon"))
        assertTrue(got[0].getBoolean("mono"))
        // No own name: the candidate's; no own picture (it'd be the app's gear): none sent, never "mono".
        assertEquals("Developer options", got[1].getString("label"))
        assertFalse(got[1].has("icon"))
        assertFalse(got[1].getBoolean("mono"))
    }

    @Test
    fun aOneColourPictureIsMonochromeAColouredOneIsNot() {
        val black = 0xff000000.toInt()
        val clear = 0
        val blue = 0xff2060e0.toInt()
        assertTrue(QuickPageCatalog.monochrome(intArrayOf(clear, black, black, 0xff202020.toInt())))
        assertFalse(QuickPageCatalog.monochrome(intArrayOf(black, blue)))
        assertFalse(QuickPageCatalog.monochrome(intArrayOf(clear, clear)))
    }

    @Test
    fun theSystemChooserIsNotAPage() {
        assertTrue(QuickPageCatalog.chooser("android", "com.android.internal.app.ResolverActivity"))
        assertTrue(QuickPageCatalog.chooser("android", "com.android.internal.app.ChooserActivity"))
        assertFalse(QuickPageCatalog.chooser("com.android.settings", "com.android.settings.Settings\$DataUsageSummaryActivity"))
    }
}
