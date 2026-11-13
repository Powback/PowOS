package dev.omalauncher.upgrade

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PowosUpdatesTest {
    private val sha = "a".repeat(64)
    private val manifest =
        """{"stamp":"1762650000 0123456789abcdef0123456789abcdef01234567","file":"powos-shell/0123456789ab.zip","sha256":"$sha","size":1048576,"apk":29902902}"""

    @Test
    fun parsesPublishShellsManifest() {
        val b = UpdatePlan.parseShell(manifest)!!
        assertEquals(1762650000L, b.time)
        assertEquals("0123456789abcdef0123456789abcdef01234567", b.commit)
        assertEquals("powos-shell/0123456789ab.zip", b.file)
        assertEquals(sha, b.sha256)
        assertEquals(1048576L, b.size)
        assertEquals(29902902L, b.apk)
    }

    @Test
    fun refusesABundleOutsideItsFolderOrWithoutAChecksum() {
        assertNull(UpdatePlan.parseShell(manifest.replace("powos-shell/0123456789ab.zip", "../powos.apk")))
        assertNull(UpdatePlan.parseShell(manifest.replace(sha, "nope")))
        assertNull(UpdatePlan.parseShell("<html>404</html>"))
    }

    @Test
    fun shellAppliesOnlyWhenNewerAndTheApkIsThere() {
        val b = UpdatePlan.parseShell(manifest)!!
        assertTrue(UpdatePlan.shellWanted(b, servedTime = 1762600000L, installedApk = 29902902L))
        // Not newer than what's served (the APK's own shell, or a push already there).
        assertFalse(UpdatePlan.shellWanted(b, servedTime = 1762650000L, installedApk = 29902902L))
        // An older APK takes the store's APK first.
        assertFalse(UpdatePlan.shellWanted(b, servedTime = 0L, installedApk = 29902669L))
    }

    @Test
    fun apkOnlyWhenTheStoresIsNewer() {
        assertTrue(UpdatePlan.apkNewer(UpdatePlan.parseVersion("29902902\n"), 29902669L))
        assertFalse(UpdatePlan.apkNewer(29902669L, 29902669L))
        assertFalse(UpdatePlan.apkNewer(UpdatePlan.parseVersion("<html>"), 1L))
    }

    @Test
    fun throttledUnlessForced() {
        val h = 60 * 60 * 1000L
        val now = 100 * h
        assertTrue(UpdatePlan.due(now, lastOk = now - 7 * h, lastTry = now - 7 * h, force = false))
        assertFalse(UpdatePlan.due(now, lastOk = now - 1 * h, lastTry = now - 1 * h, force = false))
        // Away from home: the failed try holds the next one off for a while.
        assertFalse(UpdatePlan.due(now, lastOk = 0L, lastTry = now - 10 * 60 * 1000L, force = false))
        assertTrue(UpdatePlan.due(now, lastOk = now, lastTry = now, force = true))
    }

    @Test
    fun bundlePathsStayInsideTheShell() {
        assertTrue(UpdatePlan.safePath("ui/home.tsx"))
        assertFalse(UpdatePlan.safePath("../shell-push.json"))
        assertFalse(UpdatePlan.safePath("/data/x"))
        assertFalse(UpdatePlan.safePath("ui//x"))
    }

    @Test
    fun progressFromPacmanAndTheUpdater() {
        assertEquals("Updating Linux packages", UpdatePlan.progress("#step packages"))
        assertEquals("Updating powos-core (2/3)", UpdatePlan.progress("(2/3) upgrading powos-core                 [####]"))
        // Without a terminal (the app reads a pipe), as on the razr 11-09.
        assertEquals("Updating powos-core", UpdatePlan.progress("upgrading powos-core..."))
        assertNull(UpdatePlan.progress("checking keys in keyring"))
        assertEquals("Completing the Linux image", UpdatePlan.progress("#step base"))
        assertEquals("Adding to the Linux image: spacetimedb tmux", UpdatePlan.progress("phone-update: adding to the base: spacetimedb tmux"))
        val lines = listOf("(1/2) upgrading kwin", "(2/2) upgrading fex-emu", "installing powos-core...", "(1/1) installing powos-core")
        assertEquals(3, UpdatePlan.changed(lines))
    }

    @Test
    fun summaryOnlyWhenAskedOrSomethingChanged() {
        assertNull(UpdatePlan.summary(reached = true, done = emptyList(), force = false))
        assertNull(UpdatePlan.summary(reached = false, done = emptyList(), force = false))
        assertEquals("PowOS is up to date", UpdatePlan.summary(reached = true, done = emptyList(), force = true))
        assertEquals("Updated: the home screen, 2 Linux packages", UpdatePlan.summary(true, listOf("the home screen", UpdatePlan.packages(2)!!), false))
        assertEquals("1 Linux package", UpdatePlan.packages(1))
        assertNull(UpdatePlan.packages(0))
        assertNull(UpdatePlan.error(reached = true, linuxFailed = false))
        assertTrue(UpdatePlan.error(reached = false, linuxFailed = false)!!.contains("store"))
        // Off the LAN with no VPN: the way to update is the PowOS VPN (issue #2); with one up, the VPN is the suspect.
        assertTrue(UpdatePlan.error(reached = false, linuxFailed = false, vpn = false)!!.contains("connect the PowOS VPN"))
        assertTrue(UpdatePlan.error(reached = false, linuxFailed = false, vpn = true)!!.contains("over the VPN"))
        assertEquals(UpdatePlan.unreachable(false).replaceFirstChar { it.uppercase() }, UpdatePlan.summary(false, emptyList(), force = true))
        assertEquals(50, UpdatePlan.percent(50, 100))
        assertNull(UpdatePlan.percent(50, -1))
    }

    @Test
    fun storeUrlsFallBackToTheHubByAddress() {
        assertEquals("http://192.168.50.100/apk/powos.ver", UpdatePlan.viaHub("${UpdatePlan.STORE}/powos.ver"))
        assertEquals("http://192.168.50.100/apk/powos-shell/abc.zip", UpdatePlan.viaHub("${UpdatePlan.STORE}/powos-shell/abc.zip"))
        assertNull(UpdatePlan.viaHub("http://example.com/apk/powos.ver"))
    }
}
