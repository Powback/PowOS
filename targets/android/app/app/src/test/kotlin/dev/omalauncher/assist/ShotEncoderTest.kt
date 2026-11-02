package dev.omalauncher.assist

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.concurrent.Executor

/** The assist screenshot is encoded off the main thread, and only the newest summoning's lands (ShotEncoder). */
class ShotEncoderTest {
    private class Queue : Executor {
        val tasks = ArrayDeque<Runnable>()

        override fun execute(command: Runnable) {
            tasks.add(command)
        }

        fun drain() {
            while (tasks.isNotEmpty()) tasks.removeFirst().run()
        }
    }

    private val dir = Files.createTempDirectory("shot").toFile()
    private val file = File(dir, "screen.jpg")

    @Test
    fun encodeRunsOnTheWorkerNotTheCaller() {
        val worker = Queue()
        val main = Queue()
        var wrote = false
        val got = mutableListOf<File>()
        ShotEncoder(worker, main).encode(file, { wrote = true; it.write(byteArrayOf(1, 2, 3)) }) { got += it }
        // Nothing encoded, nothing written, nothing called back on the calling (main) thread.
        assertFalse(wrote)
        assertFalse(file.exists())
        worker.drain()
        assertTrue(wrote)
        assertTrue(got.isEmpty())
        main.drain()
        assertEquals(listOf(file), got)
        // Same bytes as written straight to the file.
        assertArrayEquals(byteArrayOf(1, 2, 3), file.readBytes())
        assertFalse(File(dir, "screen.jpg.tmp").exists())
    }

    @Test
    fun aNewerSummoningOrCancelDropsTheOldShot() {
        val worker = Queue()
        val main = Queue()
        val enc = ShotEncoder(worker, main)
        val got = mutableListOf<String>()
        enc.encode(file, { it.write(1) }) { got += "old" }
        enc.encode(file, { it.write(2) }) { got += "new" }
        worker.drain()
        main.drain()
        assertEquals(listOf("new"), got)
        assertArrayEquals(byteArrayOf(2), file.readBytes())

        enc.encode(file, { it.write(3) }) { got += "cancelled" }
        worker.drain()
        enc.cancel()
        main.drain()
        assertEquals(listOf("new"), got)
    }

    @Test
    fun aFailedWriteKeepsTheLastFileAndCallsNothing() {
        file.writeBytes(byteArrayOf(9))
        val got = mutableListOf<File>()
        val direct = Executor { it.run() }
        ShotEncoder(direct, direct).encode(file, { error("compress failed") }) { got += it }
        assertTrue(got.isEmpty())
        assertArrayEquals(byteArrayOf(9), file.readBytes())
        assertFalse(File(dir, "screen.jpg.tmp").exists())
    }
}
