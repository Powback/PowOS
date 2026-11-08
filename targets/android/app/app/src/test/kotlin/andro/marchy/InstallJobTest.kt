package andro.marchy

import andro.marchy.InstallJob.Attach
import andro.marchy.InstallJob.Status
import andro.marchy.InstallJob.Step
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** 2026-11-08 razr (no root): "the launcher keeps restarting the install when resized or when backgrounded or locked". */
class InstallJobTest {
    private val url = "http://android.pow/apk/powos-rootfs-base.tar.gz"

    private fun running(step: Step = Step.DOWNLOAD) = InstallJob.fresh("KB_LAYOUTS=us\n", true, url).apply { this.step = step }

    @Test
    fun aRecreatedScreenAttachesInsteadOfShowingTheForm() {
        // fold / HOME / unlock: a new InstallActivity while the worker runs -> progress, never the form
        assertEquals(Attach.WATCH, InstallJob.onOpen(running(), false, true))
        // the process died mid-download: resume the saved job
        assertEquals(Attach.RESUME, InstallJob.onOpen(running(Step.UNPACK), false, false))
        // no job yet: the form; installed: on to the desktop
        assertEquals(Attach.FORM, InstallJob.onOpen(null, false, false))
        assertEquals(Attach.DONE, InstallJob.onOpen(null, true, false))
    }

    @Test
    fun failedAndFinishedJobs() {
        val failed = running().apply { fail("HTTP 502") }
        assertEquals(Attach.FAILED, InstallJob.onOpen(failed, false, false))
        val done = running(Step.DONE).apply { status = Status.DONE }
        assertEquals(Attach.DONE, InstallJob.onOpen(done, true, false))
        // PowOS removed since: a fresh install, not a stale "done"
        assertEquals(Attach.FORM, InstallJob.onOpen(done, false, false))
    }

    @Test
    fun neverASecondWorker() {
        assertFalse(InstallJob.shouldRun(running(), true))
        assertTrue(InstallJob.shouldRun(running(), false))
        assertFalse(InstallJob.shouldRun(running(Step.DONE), false))
        assertFalse(InstallJob.shouldRun(null, false))
    }

    @Test
    fun downloadResumesOnlyTheSameFile() {
        val j = running().apply { validator = "\"6aee938e-3e34fc53\"" }
        assertEquals(500L shl 20, InstallJob.resumeFrom(j, url, 500L shl 20))
        assertEquals(0L, InstallJob.resumeFrom(j, "http://android.pow/apk/powos-rootfs.tar.gz", 500L shl 20))
        assertEquals(0L, InstallJob.resumeFrom(running(), url, 500L shl 20)) // no validator: can't If-Range
        assertEquals(0L, InstallJob.resumeFrom(j, url, 0))
        assertTrue(InstallJob.appends(10, 206))
        assertFalse(InstallJob.appends(10, 200)) // If-Range mismatch: the server sends the new file whole
        assertFalse(InstallJob.appends(0, 206))
    }

    @Test
    fun aMissingArchiveGoesBackToTheDownload() {
        assertEquals(Step.DOWNLOAD, InstallJob.resumeStep(running(Step.UNPACK), false))
        assertEquals(Step.UNPACK, InstallJob.resumeStep(running(Step.UNPACK), true))
        assertEquals(Step.PACKS, InstallJob.resumeStep(running(Step.PACKS), false))
    }

    @Test
    fun survivesTheProcessOnDisk() {
        val f = File.createTempFile("install-job", ".properties")
        try {
            val j =
                running(Step.VERIFY).apply {
                    conf = "FULL_NAME='Mats'\nEMAIL='a=b'\n"
                    validator = "W/\"x\""
                    done = 123
                    total = 1000
                    text = "Checking the download (0 / 0 MB)\nusr/bin"
                }
            j.save(f)
            val back = InstallJob.load(f)!!
            assertEquals(j.toProperties(), back.toProperties())
            assertEquals(123, back.permille())
            f.writeText("step=NOPE\nstatus=RUNNING\n")
            assertNull(InstallJob.load(f))
        } finally {
            f.delete()
        }
    }

    @Test
    fun progressIsNeverSilent() {
        val j = running().apply { total = -1 }
        assertEquals(-1, j.permille()) // indeterminate bar, still shown
        assertEquals(1000, running(Step.DONE).permille())
    }
}
