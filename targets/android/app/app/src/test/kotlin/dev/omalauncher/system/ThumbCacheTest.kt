package dev.omalauncher.system

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files

/** The switcher's last-good card pictures (11-01 18:27: "cache the last working screenshot of it"). */
class ThumbCacheTest {
    private fun frame(f: (Int) -> Int) = IntArray(64) { f(it) }

    @Test
    fun blackAndFlatFramesAreBlank() {
        assertTrue(ThumbCache.blank(frame { 0xff000000.toInt() }))
        assertTrue(ThumbCache.blank(frame { 0xff0c0c0c.toInt() or (it % 3) }))
        assertTrue(ThumbCache.blank(frame { 0xffffffff.toInt() }))
        assertTrue(ThumbCache.blank(IntArray(0)))
    }

    @Test
    fun aRealFrameIsNotBlank() {
        assertFalse(ThumbCache.blank(frame { if (it % 4 == 0) 0xffffffff.toInt() else 0xff202840.toInt() }))
    }

    @Test
    fun aGoodLivePictureIsServedAndKeptABlankOneNeverReplacesIt() {
        val store = ThumbCache.Store(Files.createTempDirectory("thumbs").toFile())
        val good = byteArrayOf(1, 2, 3)
        assertNull(ThumbCache.choose("a:pkg/act", null, false, store))
        assertArrayEquals(good, ThumbCache.choose("a:pkg/act", good, false, store))
        // After a restart: no live picture - the cached one.
        assertArrayEquals(good, ThumbCache.choose("a:pkg/act", null, false, store))
        // A black capture: the cached one is served and stays.
        assertArrayEquals(good, ThumbCache.choose("a:pkg/act", byteArrayOf(9), true, store))
        assertArrayEquals(good, store.get("a:pkg/act"))
        // A newer good one replaces it.
        val newer = byteArrayOf(4, 5)
        assertArrayEquals(newer, ThumbCache.choose("a:pkg/act", newer, false, store))
        assertArrayEquals(newer, ThumbCache.choose("a:pkg/act", null, false, store))
    }

    @Test
    fun aBlankLivePictureWithNothingCachedIsNoPicture() {
        val store = ThumbCache.Store(Files.createTempDirectory("thumbs").toFile())
        assertNull(ThumbCache.choose("task-7", byteArrayOf(0), true, store))
    }
}
