package dev.omalauncher.shell

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class QaFilesTest {
    private val root = Files.createTempDirectory("qa").toFile()
    private val dir = File(root, "design-qa").apply { mkdirs() }
    private val outside = File(root, "secret.png").apply { writeText("secret") }

    init {
        File(dir, "shot-1.png").writeText("png")
        File(dir, "a.jpg").writeText("jpg")
    }

    @Test
    fun aBareNameInTheFolderIsServed() {
        assertEquals(File(dir, "shot-1.png").canonicalFile, QaFiles.resolve(dir, "shot-1.png"))
        assertEquals(File(dir, "a.jpg").canonicalFile, QaFiles.resolve(dir, "a.jpg"))
    }

    @Test
    fun traversalAndPathsAreRefused() {
        for (n in listOf("../secret.png", "..png", "../design-qa/shot-1.png", "sub/shot-1.png", "/etc/passwd", "./shot-1.png", "..", ".png"))
            assertNull(n, QaFiles.resolve(dir, n))
    }

    @Test
    fun encodedVariantsAreRefused() {
        for (n in listOf("%2e%2e%2fsecret.png", "..%2fsecret.png", "shot-1.png%00", "shot%2D1.png", "%2Fetc%2Fpasswd.png", "shot-1.png\u0000.png"))
            assertNull(n, QaFiles.resolve(dir, n))
    }

    @Test
    fun otherTypesAndMissingFilesAreRefused() {
        for (n in listOf("shot-1.PNG", "a.jpeg", "x.gif", "shot-1.png.txt", "nothere.png", "", " shot-1.png"))
            assertNull(n, QaFiles.resolve(dir, n))
    }

    @Test
    fun aSymlinkOutOfTheFolderIsRefused() {
        val link = File(dir, "link.png")
        Files.createSymbolicLink(link.toPath(), outside.toPath())
        assertNull(QaFiles.resolve(dir, "link.png"))
    }

    @Test
    fun theCopyCommandHasNoNameInIt() {
        val cmd = QaFiles.sync(File("/data/user/0/com.powos.app/cache/qa"))
        assertEquals(false, cmd.contains("shot-1"))
        assertEquals(true, cmd.contains("[ ! -L"))
    }
}
