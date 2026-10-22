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
 * - The status pill: the runner writes [STATUS] (in the app's run dir, PowOS's /run/powos-app) before each check -
 *   {name, task, k, n, screen} - and {done, summary} at the end. While it runs, a small glass pill at the top edge over
 *   everything says what's tested, "k of n", the screen it needs, and "don't touch · tap to stop". A tap writes
 *   /tmp/powos-verify-stop, which ends the check like a real touch (it stays queued). Done: the pill goes and the
 *   summary is left as a quiet notification.
 */
object VerifyRun {
    private const val TAG = "PowosVerify"
    private const val STATUS = "verify-status.json"

    /** WindowManager.LayoutParams.TYPE_STATUS_BAR_SUB_PANEL (hidden; the recents role's), as the pet's (PetOverlay). */
    private const val TYPE = 2017

    /** No word from the runner this long: it's gone (a crash, the Mac asleep) and the pill goes too. */
    private const val STALE_MS = 30 * 60_000L
    private const val CHANNEL = "verify-results"
    private const val NOTIFICATION_ID = 0x7e51

    private val main = Handler(Looper.getMainLooper())
    private val ID = Regex("all|[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}")
    private var watcher: FileObserver? = null
    private var pill: Pill? = null
    private lateinit var app: Context

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
        runDir.mkdirs()
        val file = File(runDir, STATUS)
        val w =
            object : FileObserver(runDir, CLOSE_WRITE or MOVED_TO) {
                override fun onEvent(
                    event: Int,
                    path: String?,
                ) {
                    if (path == STATUS) main.post { read(file, fresh = true) }
                }
            }
        watcher = w
        w.startWatching()
        // A run under way while the app restarted (an install mid-run): the pill again, but never an old summary.
        main.post { read(file, fresh = false) }
    }

    private fun read(
        file: File,
        fresh: Boolean,
    ) {
        val s = runCatching { JSONObject(file.readText()) }.getOrNull() ?: return
        if (s.optBoolean("done")) {
            pill?.remove()
            pill = null
            s.optString("summary").takeIf { fresh && it.isNotBlank() }?.let(::notify)
            return
        }
        if (!fresh && System.currentTimeMillis() - s.optLong("ts") * 1000 > STALE_MS) return
        (pill ?: Pill(app).also { pill = it }).show(s)
    }

    private fun notify(summary: String) {
        runCatching {
            val nm = app.getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Phone checks", NotificationManager.IMPORTANCE_LOW))
            nm.notify(
                NOTIFICATION_ID,
                Notification.Builder(app, CHANNEL)
                    .setSmallIcon(R.drawable.ic_notification)
                    .setContentTitle(summary)
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
        private val stale = Runnable { remove() }

        /** The fold changed: the screen line again ("unfold the phone for this one" may be done now). */
        private val displays =
            object : DisplayManager.DisplayListener {
                override fun onDisplayAdded(id: Int) {}

                override fun onDisplayRemoved(id: Int) {}

                override fun onDisplayChanged(id: Int) {
                    if (id == Display.DEFAULT_DISPLAY && added) show(status)
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

        fun show(s: JSONObject) {
            if (s.optString("task") != status.optString("task") || s.optInt("k") != status.optInt("k")) stopping = false
            status = s
            title.text = "Testing: ${s.optString("name").ifBlank { s.optString("task") }}"
            detail.text = "${s.optInt("k")} of ${s.optInt("n")} · ${screenLine(s.optString("screen"))}"
            hint.text = if (stopping) "stopping…" else "don't touch · tap to stop"
            runCatching { if (added) wm.updateViewLayout(root, params()) else add() }.onFailure { Log.w(TAG, "can't show the status pill", it) }
            main.removeCallbacks(stale)
            main.postDelayed(stale, STALE_MS)
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

        /** The tap: the running check ends like a real touch did (exit 3, it stays queued). */
        private fun stop() {
            if (stopping) return
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
            main.removeCallbacks(stale)
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
