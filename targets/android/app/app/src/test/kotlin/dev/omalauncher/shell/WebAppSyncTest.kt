package dev.omalauncher.shell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/** Every `.pow` site as a launcher app (the user 11-23): the catalog parsed, and the sync's add/remove/keep rules. */
class WebAppSyncTest {
    private fun catalog(vararg apps: String) = """{"apps":[${apps.joinToString(",")}],"at":1}"""

    private fun entry(
        host: String,
        name: String = host.removeSuffix(".pow"),
        icon: String = "http://$host/i.png",
        manifest: Boolean = false,
        sleeps: Boolean = false,
        url: String = "http://$host/",
        category: String = "",
    ) = """{"host":"$host","url":"$url","name":"$name","icon":"$icon","theme_color":"#123","manifest":$manifest,"sleeps":$sleeps,"category":"$category"}"""

    private fun app(
        id: String,
        name: String = id.removeSuffix(".pow"),
        icon: String = "http://$id/i.png",
    ) = WebApps.App(id, name, "http://$id/", icon, "#123")

    @Test
    fun parsesKindsAndKeepsOnlyPowSitesOnTheirOwnHost() {
        val e =
            WebAppSync.parse(
                catalog(
                    entry("scan.pow", manifest = true, category = "tools"),
                    entry("cdn.pow"),
                    entry("ararat.pow", icon = "", sleeps = true, manifest = true),
                    entry("pub.powback.com"),
                    entry("evil.pow", url = "http://elsewhere.com/"),
                    entry("data.pow", icon = "data:image/svg+xml,x"),
                ),
            )!!
        assertEquals(listOf("scan.pow", "cdn.pow", "ararat.pow", "data.pow"), e.map { it.id })
        assertEquals(listOf(WebAppSync.PWA, WebAppSync.PAGE, WebAppSync.SLEEPS, WebAppSync.PAGE), e.map { it.web })
        assertEquals("tools", e[0].category)
        assertEquals("", e[3].icon) // data: icons aren't fetched: the letter icon shows
        assertNull(WebAppSync.parse("<html>captive portal</html>"))
    }

    @Test
    fun addsNewHostsAndRemovesOnesTheCatalogDropped() {
        val current = listOf(app("old.pow"), app("keep.pow", name = "Keep"))
        val r = WebAppSync.apply(current, WebAppSync.parse(catalog(entry("keep.pow", name = "Kept"), entry("new.pow", manifest = true))), emptySet()) { true }
        assertEquals(listOf("keep.pow", "new.pow"), r.apps.map { it.id }) // existing order kept, new ones after
        assertEquals(listOf("new.pow"), r.added)
        assertEquals(listOf("old.pow"), r.removed)
        assertEquals("Kept", r.apps[0].name)
        assertEquals(WebAppSync.PWA, r.apps[1].web)
        assertEquals(listOf("new.pow"), r.iconsToFetch) // keep.pow's icon URL didn't change: its PNG stays
    }

    @Test
    fun aFailedOrEmptyFetchKeepsEveryApp() {
        val current = listOf(app("a.pow"), app("b.pow"))
        for (failed in listOf(null, WebAppSync.parse("not json"), WebAppSync.parse(catalog()))) {
            val r = WebAppSync.apply(current, failed, emptySet()) { true }
            assertSame(current, r.apps)
            assertTrue(r.removed.isEmpty() && r.added.isEmpty() && !r.changed)
        }
    }

    @Test
    fun whatTheUserRemovedStaysRemoved() {
        val r = WebAppSync.apply(emptyList(), WebAppSync.parse(catalog(entry("gone.pow"), entry("new.pow"))), setOf("gone.pow")) { true }
        assertEquals(listOf("new.pow"), r.apps.map { it.id })
    }

    @Test
    fun iconsAreReadAgainOnlyWhenTheirUrlChangedOrTheFileIsMissing() {
        val current = listOf(app("moved.pow"), app("lost.pow"), app("same.pow"))
        val r =
            WebAppSync.apply(
                current,
                WebAppSync.parse(catalog(entry("moved.pow", icon = "http://moved.pow/new.png"), entry("lost.pow"), entry("same.pow"))),
                emptySet(),
            ) { it != "lost.pow" }
        assertEquals(listOf("moved.pow", "lost.pow"), r.iconsToFetch)
    }

    @Test
    fun aSleepingServiceWithoutADeclaredIconIsNeverWokenForOne() {
        val r = WebAppSync.apply(emptyList(), WebAppSync.parse(catalog(entry("zzz.pow", icon = "", sleeps = true), entry("zzi.pow", sleeps = true))), emptySet()) { false }
        assertEquals(listOf("zzi.pow"), r.iconsToFetch)
    }

    @Test
    fun differSeesNameKindAndMembershipChanges() {
        val a = listOf(app("a.pow"))
        assertFalse(WebAppSync.differ(a, listOf(app("a.pow"))))
        assertTrue(WebAppSync.differ(a, listOf(app("a.pow", name = "A2"))))
        assertTrue(WebAppSync.differ(a, listOf(WebApps.App("a.pow", "a", "http://a.pow/", "http://a.pow/i.png", "#123", WebApps.Kind(WebAppSync.SLEEPS)))))
        assertTrue(WebAppSync.differ(a, emptyList()))
    }

    @Test
    fun hostsArePowNamesOnly() {
        assertTrue(WebAppSync.isPowHost("powscan.pow"))
        assertTrue(WebAppSync.isPowHost("a.b-c.pow"))
        assertFalse(WebAppSync.isPowHost("x.powback.com"))
        assertFalse(WebAppSync.isPowHost("192.168.50.100"))
        assertFalse(WebAppSync.isPowHost(null))
        assertEquals("cdn.pow", WebAppSync.hostOf("http://CDN.pow:80/x?y"))
        assertNull(WebAppSync.hostOf("ftp://cdn.pow/"))
    }

    // --- Reachability (the user 11-27: "Pow apps all greyed out as offline while the network works")

    @Test
    fun `probe - a catalog, the hub without one, nothing`() {
        val cat = listOf(app("a.pow"))
        assertEquals(WebAppSync.Probe.CATALOG, WebAppSync.probeOf(200, cat))
        // Traefik up, the catalog service down/restarting: the sites behind it work.
        assertEquals(WebAppSync.Probe.ANSWERED, WebAppSync.probeOf(502, null))
        assertEquals(WebAppSync.Probe.ANSWERED, WebAppSync.probeOf(404, null))
        assertEquals(WebAppSync.Probe.ANSWERED, WebAppSync.probeOf(301, null, "https://powstation.pow/v1/apps"))
        // No DNS/connection/timeout, the .pow LAN-only gate, a captive portal.
        assertEquals(WebAppSync.Probe.NO_ANSWER, WebAppSync.probeOf(null, null))
        assertEquals(WebAppSync.Probe.NO_ANSWER, WebAppSync.probeOf(403, null))
        assertEquals(WebAppSync.Probe.NO_ANSWER, WebAppSync.probeOf(302, null, "http://login.hotspot.example/"))
        assertEquals(WebAppSync.Probe.NO_ANSWER, WebAppSync.probeOf(200, null))
    }

    @Test
    fun `one failed try never greys the apps, the next answer clears it`() {
        var r = WebAppSync.Reach()
        assertFalse(r.offline)
        assertNull(r.retryInSec())
        r = r.after(WebAppSync.Probe.NO_ANSWER)
        assertFalse("one miss (a network still settling) greys nothing", r.offline)
        assertEquals(3L, r.retryInSec())
        r = r.after(WebAppSync.Probe.NO_ANSWER)
        assertTrue(r.offline)
        assertEquals(30L, r.retryInSec())
        r = r.after(WebAppSync.Probe.ANSWERED)
        assertFalse("the hub answering clears it at once", r.offline)
        assertNull(r.retryInSec())
    }

    @Test
    fun `what the launcher shows - a single miss keeps the last state`() {
        val miss = WebAppSync.Reach().after(WebAppSync.Probe.NO_ANSWER)
        assertEquals(true, miss.shown(true, WebAppSync.Probe.NO_ANSWER))
        assertNull(miss.shown(null, WebAppSync.Probe.NO_ANSWER))
        val off = miss.after(WebAppSync.Probe.NO_ANSWER)
        assertEquals(false, off.shown(true, WebAppSync.Probe.NO_ANSWER))
        val back = off.after(WebAppSync.Probe.ANSWERED)
        assertEquals(true, back.shown(false, WebAppSync.Probe.ANSWERED))
    }

    @Test
    fun `offline retries back off to five minutes`() {
        var r = WebAppSync.Reach()
        val delays =
            (1..10).map {
                r = r.after(WebAppSync.Probe.NO_ANSWER)
                r.retryInSec()
            }
        assertEquals(listOf(3L, 30L, 60L, 120L, 240L, 300L, 300L, 300L, 300L, 300L), delays)
        assertFalse(r.after(WebAppSync.Probe.CATALOG).offline)
    }
}
