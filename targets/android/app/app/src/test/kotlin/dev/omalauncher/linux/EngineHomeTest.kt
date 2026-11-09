package dev.omalauncher.linux

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

/**
 * gh#13: in the no-root PowOS image, ~/.config/omalauncher/widgets and ~/.local/share/powos/apps are the launcher's
 * own files/widgets and files/apps (what it loads and lists), and the widget tools are on PATH.
 */
class EngineHomeTest {
    private fun dirs(): Pair<File, File> {
        val t = Files.createTempDirectory("enginehome").toFile()
        return File(t, "rootfs").apply { mkdirs() } to File(t, "files").apply { mkdirs() }
    }

    @Test
    fun theImageHomeLinksToTheLaunchersDirs() {
        val (rootfs, files) = dirs()
        EngineHome.apply(rootfs, files) { null }
        for ((rel, target) in EngineHome.links(files)) {
            val p = File(rootfs, rel).toPath()
            assertTrue("$rel is a link", Files.isSymbolicLink(p))
            assertEquals(target.path, Files.readSymbolicLink(p).toString())
        }
        assertEquals(File(files, "apps"), EngineHome.links(files).first { it.first.endsWith("powos/apps") }.second)
        // Again: nothing to do.
        assertTrue(EngineHome.apply(rootfs, files) { null }.isEmpty())
    }

    @Test
    fun appsInstalledBeforeTheLinkMoveIntoTheLaunchersDir() {
        val (rootfs, files) = dirs()
        val old = File(rootfs, "root/.local/share/powos/apps/local.tally/current").apply { mkdirs() }
        File(old, "powos-app.json").writeText("{}")
        // One the launcher's dir has already stays where it is (never overwritten), the old dir set aside.
        File(rootfs, "root/.local/share/powos/apps/local.both").mkdirs()
        File(files, "apps/local.both").mkdirs()
        EngineHome.link(rootfs, "root/.local/share/powos/apps", File(files, "apps"))
        assertTrue(File(files, "apps/local.tally/current/powos-app.json").isFile)
        assertTrue(Files.isSymbolicLink(File(rootfs, "root/.local/share/powos/apps").toPath()))
        assertTrue(File(rootfs, "root/.local/share/powos/apps.before-link/local.both").isDirectory)
    }

    @Test
    fun aLinkToElsewhereIsReplaced() {
        val (rootfs, files) = dirs()
        val p = File(rootfs, "root/.config/omalauncher/widgets").toPath()
        Files.createDirectories(p.parent)
        Files.createSymbolicLink(p, File("/nowhere").toPath())
        EngineHome.link(rootfs, "root/.config/omalauncher/widgets", File(files, "widgets"))
        assertEquals(File(files, "widgets").path, Files.readSymbolicLink(p).toString())
        assertNull(EngineHome.link(rootfs, "root/.config/omalauncher/widgets", File(files, "widgets")))
    }

    @Test
    fun theWidgetToolsAreOnThePath() {
        val (rootfs, files) = dirs()
        EngineHome.apply(rootfs, files) { "#!/bin/sh\necho $it\n".toByteArray() }
        for (name in EngineHome.TOOLS) {
            val f = File(rootfs, "usr/local/bin/$name")
            assertTrue("$name executable", f.canExecute())
            assertArrayEquals("#!/bin/sh\necho $name\n".toByteArray(), f.readBytes())
        }
    }
}
