package dev.omalauncher.shell

import android.content.AttributionSource
import android.content.Context
import android.content.ContextWrapper
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper

/**
 * The web windows' display maker (docs/WEB_WINDOWS.md S1), run as the shell user with app_process from this APK
 * ([WebWindows] starts it: `su 2000 -c "CLASSPATH=<apk> app_process /system/bin dev.omalauncher.shell.WebWindowsHost"`),
 * talking line by line over its stdin/stdout:
 *
 *   create <tag> <w> <h> <dpi>      -> "display <tag> <displayId>" | "error <tag> <why>"
 *   resize <displayId> <w> <h> <dpi>
 *   release <displayId>
 *   (stdin closed: the app is gone - every display released, then exit)
 *
 * Why it exists: a window's display must be TRUSTED, else the app's own launches leave it. Measured 2026-10-30
 * (spikes/webwindows-s1/P1.java, isActivityStartAllowedOnDisplay = ActivityStarter's canPlaceEntityOnDisplay): on an
 * untrusted VD that PowOS owns, PowOS may start any activity there, but Chrome's uid may not start its own
 * (ChromeLauncherActivity's trampoline to ChromeTabbedActivity), so WM moves that launch to display 0 - the user's
 * screen. On a TRUSTED VD Chrome may. TRUSTED needs ADD_TRUSTED_DISPLAY: signature|role on the phone, PowOS (uid
 * 10359) is refused ("Requires ADD_TRUSTED_DISPLAY permission to create a trusted virtual display"), the shell user
 * holds it. Only TRUSTED is added (no OWN_DISPLAY_GROUP: the window's display follows the phone's screen off/on, as
 * any app does).
 *
 * Each display's output is a 1x1 ImageReader read and dropped here: the display stays ON (a null surface turns it OFF
 * and the app STOPS within ~40 ms, S0), the app draws at its full rate, and SurfaceFlinger's composition into it is 1
 * pixel. What the user sees is not this output but the display's mirror under home ([WebWindows]).
 *
 * HACK: a root-spawned shell-uid helper because an app can't hold ADD_TRUSTED_DISPLAY. Real fix: the displays made
 * from the platform-signed side (PowOS's system module) or a role that grants it; the S4 input injector will be the
 * same kind of process, and then both live in one helper.
 */
object WebWindowsHost {
    private val FLAGS =
        DisplayManager.VIRTUAL_DISPLAY_FLAG_PUBLIC or DisplayManager.VIRTUAL_DISPLAY_FLAG_OWN_CONTENT_ONLY or
            (1 shl 8) or // DESTROY_CONTENT_ON_REMOVAL: the window's activities finish with it
            (1 shl 10) // TRUSTED

    private const val SHELL_UID = 2000

    private class Vd(val display: VirtualDisplay, val reader: ImageReader)

    @JvmStatic
    fun main(args: Array<String>) {
        Looper.prepareMainLooper()
        val frames = HandlerThread("ww-frames").apply { start() }
        val dm = DisplayManager::class.java.getDeclaredConstructor(Context::class.java).apply { isAccessible = true }.newInstance(shellContext())
        val host = Host(dm, Handler(frames.looper))
        say("hello")
        val input = System.`in`.bufferedReader()
        while (true) {
            val line = input.readLine() ?: break
            try {
                host.command(line.trim().split(' '))
            } catch (e: RuntimeException) {
                say("log $line: $e")
            }
        }
        host.releaseAll()
        System.exit(0)
    }

    private fun say(line: String) =
        synchronized(System.out) {
            System.out.println(line)
            System.out.flush()
        }

    private class Host(
        private val dm: DisplayManager,
        private val frames: Handler,
    ) {
        private val vds = HashMap<Int, Vd>()

        fun command(a: List<String>) {
            when (a[0]) {
                "create" -> create(a[1], a[2].toInt(), a[3].toInt(), a[4].toInt())
                "resize" -> vds[a[1].toInt()]?.display?.resize(a[2].toInt(), a[3].toInt(), a[4].toInt())
                "release" -> vds.remove(a[1].toInt())?.let(::release)
            }
        }

        private fun create(
            tag: String,
            w: Int,
            h: Int,
            dpi: Int,
        ) {
            val r = ImageReader.newInstance(1, 1, PixelFormat.RGBA_8888, 2)
            r.setOnImageAvailableListener({ it.acquireLatestImage()?.close() }, frames)
            val vd =
                try {
                    dm.createVirtualDisplay("powos-ww-$tag", w, h, dpi, r.surface, FLAGS)
                } catch (e: RuntimeException) {
                    null.also { say("error $tag ${e.toString().replace('\n', ' ')}") }
                }
            if (vd == null) {
                r.close()
                return
            }
            vds[vd.display.displayId] = Vd(vd, r)
            say("display $tag ${vd.display.displayId}")
        }

        private fun release(v: Vd) {
            v.display.release()
            v.reader.close()
        }

        fun releaseAll() = vds.values.forEach { runCatching { release(it) } }
    }

    /** The system context under the shell package's name (the uid this runs as), as scrcpy's server does. */
    private fun shellContext(): Context {
        val at = Class.forName("android.app.ActivityThread")
        val thread = at.getDeclaredConstructor().apply { isAccessible = true }.newInstance()
        at.getDeclaredField("sCurrentActivityThread").apply { isAccessible = true }.set(null, thread)
        at.getDeclaredField("mSystemThread").apply { isAccessible = true }.setBoolean(thread, true)
        val system = at.getMethod("getSystemContext").invoke(thread) as Context
        return object : ContextWrapper(system) {
            override fun getPackageName() = "com.android.shell"

            override fun getOpPackageName() = "com.android.shell"

            override fun getAttributionSource(): AttributionSource = AttributionSource.Builder(SHELL_UID).setPackageName("com.android.shell").build()

            override fun getApplicationContext(): Context = this
        }
    }
}
