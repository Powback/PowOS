package dev.omalauncher.shell

import dev.omalauncher.linux.EngineServices
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** No-root islands (docs/research/nonroot-parity.md #2): the APK's apps as registry rows, and what an island waits for. */
class LocalAppsTest {
    @Test
    fun aBundledAppIsARegistryRowWithItsDatabase() {
        val m = """{"id":"local.pet","name":"Pet","version":"0.1.0","module":{"database":"local-pet"},"widgets":[]}"""
        val r = LocalApps.row("local.pet", m, "+apk42")!!
        assertEquals("Pet", r.getString("name"))
        assertEquals("0.1.0+apk42", r.getString("version"))
        assertEquals("local-pet", r.getString("database"))
        assertEquals(m, r.getString("manifest"))
    }

    @Test
    fun anAppWithoutAModuleNeedsNoDatabase() {
        val r = LocalApps.row("local.needs-me", """{"id":"local.needs-me","name":"What needs me","module":null}""", "")!!
        assertEquals("", r.getString("database"))
    }

    @Test
    fun aManifestOfAnotherIdOrBrokenIsNoRow() {
        assertNull(LocalApps.row("local.pet", """{"id":"local.other"}""", ""))
        assertNull(LocalApps.row("local.pet", "{not json", ""))
    }

    @Test
    fun spacetimeDbStateByWhereTheImageStands() {
        assertEquals("image", EngineServices.stateOf(image = false, hasStdb = false, up = false))
        assertEquals("missing", EngineServices.stateOf(image = true, hasStdb = false, up = false))
        assertEquals("starting", EngineServices.stateOf(image = true, hasStdb = true, up = false))
        assertEquals("up", EngineServices.stateOf(image = true, hasStdb = true, up = true))
    }
}
