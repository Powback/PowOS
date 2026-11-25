package dev.omalauncher.shell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The control center's tiles on rooted PowOS, a phone without root (S25, razr), and with a way in still off. */
class TilePathsTest {
    private val rooted = TileCaps(rooted = true, legacyWifi = true, legacyBt = true, accessibility = true, lockAdmin = true, writeSettings = true, dndAccess = true)
    private val noRoot = rooted.copy(rooted = false)
    private val bare = TileCaps(rooted = false, legacyWifi = false, legacyBt = false, accessibility = false, lockAdmin = false, writeSettings = false, dndAccess = false)

    private val switches = listOf("wifi", "bt", "cell", "airplane", "location", "darkmode", "nfc", "battery", "powersave", "dnd", "rotation")
    private val actions = listOf("screenshot", "lockscreen")

    @Test
    fun rootedKeepsTheInstantSuCommands() {
        assertEquals(TilePath.Root("svc wifi disable"), TilePaths.choose("wifi", true, rooted))
        assertEquals(TilePath.Root("svc wifi enable"), TilePaths.choose("wifi", false, rooted))
        assertEquals(TilePath.Root("svc bluetooth enable"), TilePaths.choose("bt", false, rooted))
        assertEquals(TilePath.Root("svc data disable"), TilePaths.choose("cell", true, rooted))
        assertEquals(TilePath.Root("cmd connectivity airplane-mode enable"), TilePaths.choose("airplane", false, rooted))
        assertEquals(TilePath.Root("cmd location set-location-enabled true"), TilePaths.choose("location", false, rooted))
        assertEquals(TilePath.Root("cmd uimode night no"), TilePaths.choose("darkmode", true, rooted))
        assertEquals(TilePath.Root("svc nfc enable"), TilePaths.choose("nfc", false, rooted))
        assertEquals(TilePath.Root("cmd power set-mode 1"), TilePaths.choose("battery", false, rooted))
        assertEquals(TilePath.Root("input keyevent KEYCODE_SYSRQ"), TilePaths.choose("screenshot", null, rooted))
        assertEquals(TilePath.Root("input keyevent KEYCODE_SLEEP"), TilePaths.choose("lockscreen", null, rooted))
    }

    @Test
    fun noRootSwitchesWhatTheAppMayAndOpensPanelsForTheRest() {
        assertEquals(TilePath.Direct, TilePaths.choose("wifi", false, noRoot))
        assertEquals(TilePath.Direct, TilePaths.choose("bt", true, noRoot))
        assertEquals(TilePath.Direct, TilePaths.choose("darkmode", false, noRoot))
        assertEquals(TilePath.Direct, TilePaths.choose("dnd", false, noRoot))
        assertEquals(TilePath.Direct, TilePaths.choose("rotation", false, noRoot))
        assertEquals(TilePath.Panel("cell"), TilePaths.choose("cell", true, noRoot))
        assertEquals(TilePath.Panel("airplane"), TilePaths.choose("airplane", false, noRoot))
        assertEquals(TilePath.Panel("location"), TilePaths.choose("location", false, noRoot))
        assertEquals(TilePath.Panel("nfc"), TilePaths.choose("nfc", false, noRoot))
        assertEquals(TilePath.Panel("battery"), TilePaths.choose("battery", false, noRoot))
        assertEquals(TilePath.Global(TilePaths.GLOBAL_SCREENSHOT), TilePaths.choose("screenshot", null, noRoot))
        // The accessibility lock before the admin's lockNow (which costs the next biometric unlock).
        assertEquals(TilePath.Global(TilePaths.GLOBAL_LOCK), TilePaths.choose("lockscreen", null, noRoot))
        assertEquals(TilePath.AdminLock, TilePaths.choose("lockscreen", null, noRoot.copy(accessibility = false)))
    }

    @Test
    fun aMissingPermissionOpensThePageThatGrantsItAndSaysWhy() {
        assertEquals(TilePath.Panel("wifi"), TilePaths.choose("wifi", false, bare))
        assertEquals(TilePath.Panel("bt"), TilePaths.choose("bt", false, bare))
        assertEquals(TilePath.Panel("dnd"), TilePaths.choose("dnd", false, bare))
        assertEquals(TilePath.Ask("write-settings", TilePaths.WHY_ROTATION), TilePaths.choose("rotation", false, bare))
        assertEquals(TilePath.Ask("accessibility", TilePaths.WHY_SCREENSHOT), TilePaths.choose("screenshot", null, bare))
        assertEquals(TilePath.Ask("lock-admin", TilePaths.WHY_LOCK), TilePaths.choose("lockscreen", null, bare))
        // Rooted without WRITE_SETTINGS: auto-rotate through su, not a grant page.
        assertEquals(TilePath.Root("settings put system accelerometer_rotation 1"), TilePaths.choose("rotation", false, bare.copy(rooted = true)))
    }

    @Test
    fun neverSilentEveryTileHasAPathOnEveryPhone() {
        for (caps in listOf(rooted, noRoot, bare)) {
            for (id in switches + actions) assertNotNull("$id $caps", TilePaths.choose(id, false, caps))
        }
    }

    @Test
    fun aFailedPathFallsToAPanelNeverToNothing() {
        for (caps in listOf(rooted, noRoot, bare)) {
            for (id in switches) {
                val f = TilePaths.fallback(id, false, caps)
                assertTrue("$id $caps -> $f", f is TilePath.Panel || f is TilePath.Ask)
            }
        }
        // su failing on a "rooted" phone: the screenshot goes to the accessibility service, the lock likewise.
        assertEquals(TilePath.Global(TilePaths.GLOBAL_SCREENSHOT), TilePaths.fallback("screenshot", null, rooted))
        assertEquals(TilePath.Global(TilePaths.GLOBAL_LOCK), TilePaths.fallback("lockscreen", null, rooted))
        assertEquals(TilePath.Panel("darkmode"), TilePaths.fallback("darkmode", false, noRoot))
        assertEquals(TilePath.Panel("wifi"), TilePaths.fallback("wifi", false, noRoot))
    }

    @Test
    fun onlySwitchesThatActFlipOptimistically() {
        assertTrue(TilePaths.optimistic(TilePaths.choose("wifi", false, rooted)))
        assertTrue(TilePaths.optimistic(TilePaths.choose("wifi", false, noRoot)))
        assertEquals(false, TilePaths.optimistic(TilePaths.choose("wifi", false, bare)))
        assertEquals(false, TilePaths.optimistic(TilePaths.choose("cell", false, noRoot)))
    }

    @Test
    fun torchHotspotAndThirdPartyTilesKeepTheirOwnHandling() {
        assertNull(TilePaths.choose("flashlight", false, bare))
        assertNull(TilePaths.choose("hotspot", false, bare))
        assertNull(TilePaths.choose("custom(com.x/.T)", null, bare))
    }
}
