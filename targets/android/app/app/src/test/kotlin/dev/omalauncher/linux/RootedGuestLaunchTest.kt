package dev.omalauncher.linux

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files
import java.util.concurrent.TimeUnit

/** A program that runs on never holds the app's pipes (targets/android/docs/powos-window-tasks.md "Output"). */
class RootedGuestLaunchTest {
    private val line = RootedGuest.launchCommand("steam", "steam -silent")

    @Test fun programGetsNoneOfTheAppsFds() {
        val start = Regex("""\(exec steam -silent\) (.*?) &""").find(line)?.groupValues?.get(1)
        assertTrue("program not started in the background with redirects: $line", start != null)
        assertTrue("stdin not /dev/null: $start", "</dev/null" in start!!)
        assertTrue("stdout not appended to its log: $start", ">>\"\$f\"" in start)
        assertTrue("stderr not with stdout: $start", "2>&1" in start)
        assertFalse("still exec'd straight onto the caller's fds", line.startsWith("exec "))
    }

    @Test fun logIsPerProgramAndCapped() {
        assertTrue(line, "f=\"\${XDG_RUNTIME_DIR:-/tmp}/launch/steam.log\"" in line)
        assertTrue("no size cap: $line", "-gt ${4 shl 20} ] && : >\"\$f\"" in line)
        assertTrue("output not relayed while it runs: $line", "--pid=\$p -f \"\$f\"" in line)
        assertTrue("exit code not the program's: $line", line.endsWith("wait \$p"))
    }

    /** The app restarts (its end of the pipe closes) while the program runs: the program writes on, to its log. */
    @Test fun programOutlivesADeadCallerPipe() {
        val run = Files.createTempDirectory("launch").toFile()
        val program = "bash -c 'echo first; sleep 1; for i in 1 2 3; do echo line\$i; done; echo err >&2; exit 7'"
        val p = ProcessBuilder("bash", "-c", RootedGuest.launchCommand("game", program)).redirectErrorStream(true)
        p.environment()["XDG_RUNTIME_DIR"] = run.path
        val process = p.start()
        assertEquals("first", process.inputStream.bufferedReader().readLine()) // relayed while it runs
        process.inputStream.close() // the reader is gone
        assertTrue("launch didn't end", process.waitFor(10, TimeUnit.SECONDS))
        assertEquals("the program's exit code", 7, process.exitValue())
        assertEquals("first\nline1\nline2\nline3\nerr\n", run.resolve("launch/game.log").readText())
        run.deleteRecursively()
    }

    @Test fun logNames() {
        assertEquals("steam", RootedGuest.logName("/usr/bin/steam -silent"))
        assertEquals("org.kde.dolphin", RootedGuest.logName("org.kde.dolphin"))
        assertEquals("a_b", RootedGuest.logName("a\$b"))
        assertEquals("command", RootedGuest.logName(""))
    }
}
