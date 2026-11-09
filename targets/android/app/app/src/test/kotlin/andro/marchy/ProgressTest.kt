package andro.marchy

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Progress's state files (powos-progress, Powback/PowOS#11): names and lines as the helper writes them. */
class ProgressTest {
    @Test
    fun idsComeOnlyFromProgressStateFiles() {
        assertEquals("steam-setup", Progress.idOf("progress-steam-setup.state"))
        assertNull(Progress.idOf("progress-steam-setup.state.tmp.123"))
        assertNull(Progress.idOf("android-request"))
        assertNull(Progress.idOf("pack-gaming.state"))
        assertNull(Progress.idOf("progress-../x.state"))
    }

    @Test
    fun linesParse() {
        val p = Progress.parse("1048576 2097152", "Downloading Steam (2 MB)")!!
        assertEquals(Progress.Kind.PROGRESS, p.kind)
        assertEquals(1048576L, p.done)
        assertEquals(2097152L, p.total)
        assertEquals("Downloading Steam (2 MB)", p.title)
        assertEquals(Progress.Kind.PROGRESS, Progress.parse("0 0", "Unpacking Steam")!!.kind)
        assertEquals(Progress.Kind.DONE, Progress.parse("done", "")!!.kind)
        val f = Progress.parse("failed couldn't download", "")!!
        assertEquals(Progress.Kind.FAILED, f.kind)
        assertEquals("couldn't download", f.message)
        assertNull(Progress.parse("12 of 40", "x"))
        assertNull(Progress.parse("", "x"))
    }
}
