package dev.omalauncher.shell

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.hardware.display.DisplayManager
import android.os.FileObserver
import android.os.Handler
import android.os.Looper
import android.text.TextUtils
import android.util.Log
import android.util.TypedValue
import android.view.Display
import android.view.Gravity
import android.view.SurfaceControl
import android.view.View
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView
import dev.omalauncher.R
import dev.omalauncher.linux.RootedGuest
import dev.omalauncher.linux.shellQuote
import dev.omalauncher.system.HiddenApi
import org.json.JSONObject
import java.io.File

/**
 * The phone side of the verify queue (tools/phone/verify/queue.sh, which runs on the Mac and reaches the phone over
 * adb; the phone can't call the Mac):
 * - [go]: the AI page's "test now" / "test all" (bridge verify.go) writes PowOS's /tmp/powos-verify-go (a task id or
 *   "all"). The runner's one held wait (tools/phone/idle.sh, its loop on the phone) sees it and runs those checks now.
 * - The status pill: the runner writes [STATUS] (in the app's run dir, PowOS's /run/powos-app/verify) as a heartbeat
 *   every few seconds while a check runs - {name, task, k, n, screen, el (seconds in), budget, prev (the last result)}
 *   - and {done, summary} at the end. While beats come, a small glass pill at the top edge over everything says what's
 *   tested, "k of n", the time it's been running and the screen it needs. A tap writes /tmp/powos-verify-stop: the
 *   runner's next beat sees it, kills the check (it stays queued) and writes done. Done: the pill goes and the summary
 *   is left as a quiet notification. No beat for [STALE_MS] (the runner killed, the Mac asleep): the pill goes and says
 *   so in a notification.
 */
object VerifyRun {
    private const val TAG = "PowosVerify"
    private const val DIR = "verify"
    private const val STATUS = "status.json"

    /** WindowManager.LayoutParams.TYPE_STATUS_BAR_SUB_PANEL (hidden; the recents role's), as the pet's (PetOverlay). */
    private const val TYPE = 2017

    /** No heartbeat this long (the runner beats every 4 s): it's gone (killed, the Mac asleep) and the pill goes too. */
    private const val STALE_MS = 30_000L
    private const val CHANNEL = "verify-results"
    private const val NOTIFICATION_ID = 0x7e51

    private val main = Handler(Looper.getMainLooper())
    private val ID = Regex("all|[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}")
    private var watcher: FileObserver? = null
    private var pill: Pill? = null
    private lateinit var app: Context
    private lateinit var file: File

    /** The file's mtime last read (the phone's clock: the runner writes it on the phone). */
    private var seen = 0L

    /** While the pill is up: the elapsed time ticks, a missed write is picked up, a silent runner hides it. */
    private val tick =
        object : Runnable {
            override fun run() {
                val p = pill ?: return
                val m = file.lastModified()
                if (m != seen) read(fresh = true) else if (System.currentTimeMillis() - m > STALE_MS) {
                    p.remove()
                    pill = null
                    notify("Phone test stopped", "No word from the test runner for ${STALE_MS / 1000} s")
                    return
                } else {
                    p.tick(m)
                }
                if (pill != null) main.postDelayed(this, 1000)
            }
        }

    /** "Test now" ([task]: a board task id, or "all"): the queue's runner takes it at its next 5 s check. */
    fun go(task: String) = flag("powos-verify-go", task)

    private fun flag(
        name: String,
        value: String,
    ) {
        require(value.matches(ID)) { "bad task id $value" }
        Thread({
            runCatching { RootedGuest.run("umask 022; printf %s ${shellQuote(value)} > /tmp/.$name && mv -f /tmp/.$name /tmp/$name") }
                .onFailure { Log.w(TAG, "can't write $name", it) }
        }, "verify-flag").start()
    }

    fun start(
        context: Context,
        runDir: File,
    ) {
        if (watcher != null) return
        app = context.applicationContext
        // A folder of its own: FileObservers on one folder share its inotify watch, and the last one started takes
        // every event (android.os.FileObserver's ObserverThread keeps one observer per watch) - in the shared run dir
        // a widget's watch once took the pill's "done" and left it up.
        val dir = File(runDir, DIR).apply { mkdirs() }
        file = File(dir, STATUS)
        val w =
            object : FileObserver(dir, CLOSE_WRITE or MOVED_TO) {
                override fun onEvent(
                    event: Int,
                    path: String?,
                ) {
                    if (path == STATUS) main.post { read(fresh = true) }
                }
            }
        watcher = w
        w.startWatching()
        // A run under way while the app restarted (an install mid-run): the pill again, but never an old summary.
        main.post { read(fresh = false) }
    }

    private fun read(fresh: Boolean) {
        seen = file.lastModified()
        val s = runCatching { JSONObject(file.readText()) }.getOrNull() ?: return
        if (s.optBoolean("done")) {
            pill?.remove()
            pill = null
            s.optString("summary").takeIf { fresh && it.isNotBlank() }?.let { notify(it) }
            return
        }
        if (System.currentTimeMillis() - seen > STALE_MS) return
        val p = pill ?: Pill(app).also {
            pill = it
            main.removeCallbacks(tick)
            main.postDelayed(tick, 1000)
        }
        p.show(s, seen)
    }

    private fun notify(
        summary: String,
        text: String? = null,
    ) {
        runCatching {
            val nm = app.getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Phone checks", NotificationManager.IMPORTANCE_LOW))
            nm.notify(
                NOTIFICATION_ID,
                Notification.Builder(app, CHANNEL)
                    .setSmallIcon(R.drawable.ic_notification)
                    .setContentTitle(summary)
                    .apply { text?.let(::setContentText) }
                    .setAutoCancel(true)
                    .build(),
            )
        }.onFailure { Log.w(TAG, "can't post the summary", it) }
    }

    /** The pill: one small window of its own over everything, kept out of screencaps (the checks take their own). */
    private class Pill(
        app: Context,
    ) {
        private val display: Display = app.getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY)
        private val context: Context = app.createDisplayContext(display).createWindowContext(TYPE, null)
        private val wm = context.getSystemService(WindowManager::class.java)
        private val density = context.resources.displayMetrics.density
        private val title = text(13f, INK, bold = true)
        private val detail = text(12f, SOFT, bold = false)
        private val hint = text(12f, SOFT, bold = false).apply { text = "don't touch · tap to stop" }
        private val root =
            LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER_HORIZONTAL
                val p = dp(14f)
                setPadding(p, dp(8f), p, dp(9f))
                background = GradientDrawable().apply {
                    setColor(TINT)
                    cornerRadius = CORNER_DP * density
                }
                addView(title)
                addView(detail)
                addView(hint)
                setOnClickListener { stop() }
            }
        private val blur = WindowBlur({ root.rootView }, BLUR_DP, cornersDp = FloatArray(4) { CORNER_DP })
        private var added = false
        private var stopping = false
        private var status = JSONObject()
        private var at = 0L

        /** The fold changed: the screen line again ("unfold the phone for this one" may be done now). */
        private val displays =
            object : DisplayManager.DisplayListener {
                override fun onDisplayAdded(id: Int) {}

                override fun onDisplayRemoved(id: Int) {}

                override fun onDisplayChanged(id: Int) {
                    if (id == Display.DEFAULT_DISPLAY && added) show(status, at)
                }
            }

        private fun dp(v: Float) = (v * density).toInt()

        private fun text(
            sp: Float,
            color: Int,
            bold: Boolean,
        ) = TextView(context).apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, sp)
            setTextColor(color)
            if (bold) typeface = android.graphics.Typeface.create("sans-serif-medium", android.graphics.Typeface.NORMAL)
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
            gravity = Gravity.CENTER_HORIZONTAL
        }

        /** [s]: the runner's beat, written at [mtime] (phone clock). */
        fun show(
            s: JSONObject,
            mtime: Long,
        ) {
            if (s.optString("task") != status.optString("task") || s.optInt("k") != status.optInt("k")) stopping = false
            status = s
            at = mtime
            title.text = "Testing: ${s.optString("name").ifBlank { s.optString("task") }}"
            tick(mtime)
            val prev = s.optString("prev")
            hint.text = if (stopping) "stopping…" else if (prev.isNotBlank()) "$prev · tap to stop" else "don't touch · tap to stop"
            runCatching { if (added) wm.updateViewLayout(root, params()) else add() }.onFailure { Log.w(TAG, "can't show the status pill", it) }
        }

        /** The elapsed time between beats: the beat's own, plus the time since it was written. */
        fun tick(mtime: Long) {
            val el = status.optLong("el") + ((System.currentTimeMillis() - mtime) / 1000).coerceAtLeast(0)
            detail.text = "${status.optInt("k")} of ${status.optInt("n")} · ${el / 60}:${"%02d".format(el % 60)} · ${screenLine(status.optString("screen"))}"
        }

        /** The screen the check needs, said against the one in use (the cover is the tall, narrow one). */
        private fun screenLine(need: String): String {
            val b = wm.currentWindowMetrics.bounds
            val folded = b.width() < b.height() * 0.6f
            return when {
                need == "inner" && folded -> "unfold the phone for this one"
                need == "cover" && !folded -> "fold the phone for this one"
                folded -> "testing on the cover screen"
                else -> "testing on the inner screen"
            }
        }

        private fun add() {
            wm.addView(root, params())
            added = true
            context.getSystemService(DisplayManager::class.java).registerDisplayListener(displays, main)
            root.post {
                blur.set(1f)
                skipScreenshot()
            }
        }

        private fun params() =
            WindowManager.LayoutParams(
                WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.WRAP_CONTENT,
                TYPE,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                    WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED,
                PixelFormat.TRANSLUCENT,
            ).apply {
                title = "PowOS verify status"
                gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
                fitInsetsTypes = 0
                layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                // Below the status bar's clock and the camera, out of the way of the top row a check may pull.
                y = dp(TOP_DP)
            }

        /** The tap, every time: the runner's next beat sees the flag, kills the check (it stays queued) and says done. */
        private fun stop() {
            stopping = true
            hint.text = "stopping…"
            flag("powos-verify-stop", status.optString("task").takeIf { it.matches(ID) } ?: "all")
        }

        /**
         * Out of every screencap and recording's capture (SurfaceFlinger's skip-screenshot layer flag): the checks'
         * own screencaps must show the screen under test, not this.
         * HACK: Transaction.setSkipScreenshot and ViewRootImpl.getSurfaceControl are hidden (SystemUI's screenshot
         * UI uses them); reflected past the checks ([HiddenApi]). Real fix: none for an app - the public
         * FLAG_SECURE blacks the window out instead of leaving it out.
         */
        private fun skipScreenshot(retries: Int = 0) {
            runCatching {
                HiddenApi.allow()
                val viewRoot = View::class.java.getMethod("getViewRootImpl").invoke(root)
                val surface = viewRoot?.javaClass?.getMethod("getSurfaceControl")?.invoke(viewRoot) as? SurfaceControl
                if (surface == null || !surface.isValid) {
                    if (retries < 30) root.postOnAnimation { skipScreenshot(retries + 1) }
                    return
                }
                val t = SurfaceControl.Transaction()
                SurfaceControl.Transaction::class.java.getMethod("setSkipScreenshot", SurfaceControl::class.java, Boolean::class.javaPrimitiveType).invoke(t, surface, true)
                t.apply()
            }.onFailure { Log.w(TAG, "the status pill can't keep out of screencaps", it) }
        }

        fun remove() {
            if (!added) return
            added = false
            runCatching { context.getSystemService(DisplayManager::class.java).unregisterDisplayListener(displays) }
            runCatching { wm.removeViewImmediate(root) }
            if (pill === this) pill = null
        }
    }

    /** Home's glass (WindowFrame's): the compositor's blur under a dark tint. */
    private const val BLUR_DP = 140f
    private const val CORNER_DP = 18f
    private const val TOP_DP = 40f
    private val TINT = Color.argb(107, 18, 20, 26)
    private val INK = Color.argb(222, 255, 255, 255)
    private val SOFT = Color.argb(170, 255, 255, 255)
}
