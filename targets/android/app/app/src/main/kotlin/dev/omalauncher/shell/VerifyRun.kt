package dev.omalauncher.shell

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.Region
import android.graphics.drawable.GradientDrawable
import android.hardware.display.DisplayManager
import android.os.Build
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
 *   - and {done, summary} at the end. While beats come, a small glass pill in the bottom-left corner says what's
 *   tested, "k of n", the time it's been running and the screen it needs. Done: the pill goes and the summary is left
 *   as a quiet notification. No beat for [STALE_MS] (the runner killed, the Mac asleep): the pill goes and says so.
 * - The runner's other two states, also {done: true} (so APKs before them just hide the pill): {wait, n, ttl} while
 *   checks wait for the user to put the phone down (a touch in the last 2 min, a game running): "Tests wait · phone
 *   in use", for ttl s unless rewritten; {paused, summary} after a stop: "Tests paused · Resume" for [PAUSED_MS], then
 *   only the notification and the AI page's "checks paused · resume" are left.
 * - The pill's one touch target, its right end (the rest of it takes no touches: over window chrome it hid the close
 *   buttons from the checks, e2e round 2, 2026-10-23): x writes PowOS's /tmp/powos-verify-stop, which the runner sees
 *   within 5 s - the running check is killed (its own trap restores what it opened) and the queue pauses; Resume is
 *   the AI page's resume (go=all).
 */
object VerifyRun {
    private const val TAG = "PowosVerify"
    private const val DIR = "verify"
    private const val STATUS = "status.json"

    /** The runner's state word + heartbeat (tools/phone/verify/queue.sh, idle.sh VERIFY_STATE): adb's shell user's. */
    private const val RUNNER = "/data/local/tmp/powos-verify-runner"

    /** WindowManager.LayoutParams.TYPE_STATUS_BAR_SUB_PANEL (hidden; the recents role's), as the pet's (PetOverlay). */
    private const val TYPE = 2017

    /** No heartbeat this long (the runner beats every 4 s): it's gone (killed, the Mac asleep) and the pill goes too. */
    private const val STALE_MS = 30_000L

    /** How long "Tests paused · Resume" stays after a stop. */
    private const val PAUSED_MS = 15_000L
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

    /** The runner's state the pill shows: a check running (its beats), checks waiting for the user, paused. */
    private enum class Kind { RUN, WAIT, PAUSED }

    private var kind = Kind.RUN

    /** How long the last status holds without a new write (ms). */
    private var life = STALE_MS

    /** While the pill is up: the elapsed time ticks, a missed write is picked up, a silent runner hides it. */
    private val tick =
        object : Runnable {
            override fun run() {
                val p = pill ?: return
                val m = file.lastModified()
                if (m != seen) read(fresh = true) else if (System.currentTimeMillis() - m > life) {
                    p.remove()
                    pill = null
                    if (kind == Kind.RUN) notify("Phone test stopped", "No word from the test runner for ${STALE_MS / 1000} s")
                    return
                } else {
                    p.tick(m)
                }
                if (pill != null) main.postDelayed(this, 1000)
            }
        }

    /** "Test now" ([task]: a board task id, or "all"): the queue's runner takes it at its next 5 s check. */
    fun go(task: String) = flag("powos-verify-go", task)

    /**
     * The pill's x and the shade's "tests" control (bridge verify.stop): the runner kills the running check and pauses
     * the queue (queue.sh, its beat / idle.sh's wait).
     */
    fun stop() = flag("powos-verify-stop", "1")

    /**
     * The runner's state for the AI page ("checks paused · resume"): the word the Mac's runner keeps in
     * /data/local/tmp/powos-verify-runner (waiting | paused | running | idle | stopped; its waits on the phone touch it
     * every 5 s) and the seconds since (age, -1: no file - no runner has run). Android root (the file is adb's shell
     * user's), off the main thread; the answer comes as [emit] (the page's "verify.state").
     */
    fun state(emit: (JSONObject) -> Unit) {
        Thread({
            val r = andro.marchy.RootShell.run("f=$RUNNER; [ -e \$f ] && { head -c 16 \$f | tr -cd a-z; echo; echo \$(( \$(date +%s) - \$(stat -c %Y \$f) )); }", null, 5_000)
            val lines = r.output.lines()
            val ok = r.code == 0 && lines.size >= 2
            emit(JSONObject().put("state", if (ok) lines[0] else "").put("age", if (ok) lines[1].trim().toLongOrNull() ?: -1 else -1))
        }, "verify-state").start()
    }

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
        val k = kindOf(s)
        if (k != Kind.WAIT) s.optString("summary").takeIf { fresh && it.isNotBlank() }?.let { notify(it) }
        life = lifeOf(k, s)
        if (k == null || System.currentTimeMillis() - seen > life) {
            pill?.remove()
            pill = null
            return
        }
        kind = k
        val p = pill ?: Pill(app).also {
            pill = it
            main.removeCallbacks(tick)
            main.postDelayed(tick, 1000)
        }
        p.show(s, seen)
    }

    /** The status's state: null = done (the pill goes). */
    private fun kindOf(s: JSONObject) =
        when {
            s.optBoolean("paused") -> Kind.PAUSED
            s.optBoolean("wait") -> Kind.WAIT
            s.optBoolean("done") -> null
            else -> Kind.RUN
        }

    private fun lifeOf(
        k: Kind?,
        s: JSONObject,
    ) = when (k) {
        Kind.WAIT -> s.optLong("ttl", 200) * 1000
        Kind.PAUSED -> PAUSED_MS
        else -> STALE_MS
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
        /** One line: the check, k/n, its time, and the screen only when it's the wrong one. */
        private val title = text(10f, INK, bold = true).apply { setPadding(dp(9f), dp(3f), 0, dp(4f)) }

        /**
         * The one touch target (x: stop, Resume): the pill's right end, its full height. Only from Android 14
         * (AttachedSurfaceControl.setTouchableRegion keeps the rest of the pill touch-through); before, no target.
         */
        private val action =
            text(11f, INK, bold = true).apply {
                maxWidth = Int.MAX_VALUE
                setPadding(dp(8f), dp(4f), dp(9f), dp(5f))
                setOnClickListener { tapped() }
            }
        private val canTouch = Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE

        /** After a tap, what it does ("Stopping tests…") until the runner's next word. */
        private var local: String? = null

        /** The state last logged (the device check reads the log: "pill PAUSED: Tests paused [Resume]"). */
        private var logged: Kind? = null
        private val root =
            LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                background = GradientDrawable().apply {
                    setColor(TINT)
                    cornerRadius = CORNER_DP * density
                }
                addView(title)
                addView(action)
                addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> touchRegion() }
            }
        private val blur = WindowBlur({ root.rootView }, BLUR_DP, cornersDp = FloatArray(4) { CORNER_DP })
        private var added = false
        private var status = JSONObject()
        private var at = 0L

        /** The fold changed: the screen line again ("Unfold the phone" may be done now). */
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
            gravity = Gravity.START
            // Narrow: a long check name made it ~450 dp wide, over the floating windows' close buttons (e2e 2026-10-23).
            maxWidth = dp(PILL_MAX_DP)
        }

        /** [s]: the runner's beat, written at [mtime] (phone clock). */
        fun show(
            s: JSONObject,
            mtime: Long,
        ) {
            status = s
            at = mtime
            local = null
            tick(mtime)
            val a = if (!canTouch) "" else if (kind == Kind.PAUSED) "Resume" else "\u00d7"
            if (logged != kind) Log.i(TAG, "pill $kind: ${title.text} [$a]")
            logged = kind
            setAction(a)
            runCatching { if (added) wm.updateViewLayout(root, params()) else add() }.onFailure { Log.w(TAG, "can't show the status pill", it) }
        }

        /** The elapsed time between beats: the beat's own, plus the time since it was written. */
        fun tick(mtime: Long) {
            title.text = local ?: when {
                kind == Kind.PAUSED -> "Tests paused"
                kind == Kind.WAIT -> "Tests wait \u00b7 phone in use"
                else -> runLine(mtime)
            }
        }

        private fun runLine(mtime: Long): String {
            val el = status.optLong("el") + ((System.currentTimeMillis() - mtime) / 1000).coerceAtLeast(0)
            val name = status.optString("name").ifBlank { status.optString("task") }
            val line = "$name · ${status.optInt("k")}/${status.optInt("n")} · ${el / 60}:${"%02d".format(el % 60)}"
            // The wrong screen first: the line is short and ends in an ellipsis.
            return screenLine(status.optString("screen"))?.let { "$it · $line" } ?: line
        }

        private fun setAction(a: String) {
            action.text = a
            action.visibility = if (a.isEmpty()) View.GONE else View.VISIBLE
            action.contentDescription = if (a == "Resume") "Resume tests" else "Stop tests"
            title.setPaddingRelative(dp(9f), dp(3f), if (a.isEmpty()) dp(9f) else 0, dp(4f))
        }

        /** x: stop (the runner pauses); Resume: go=all. The pill says so at once; the runner's next write follows. */
        private fun tapped() {
            val resume = kind == Kind.PAUSED
            Log.i(TAG, "pill tap: ${if (resume) "resume" else "stop"}")
            if (resume) go("all") else stop()
            local = if (resume) "Resuming tests\u2026" else "Stopping tests\u2026"
            tick(at)
            setAction("")
        }

        /** Touches only on the action; everything else goes through to what's under the pill. */
        private fun touchRegion() {
            if (!canTouch) return
            val r = Rect()
            if (action.visibility == View.VISIBLE) action.getHitRect(r)
            runCatching { root.rootSurfaceControl?.setTouchableRegion(Region(r)) }
                .onFailure { Log.w(TAG, "can't set the pill's touch region", it) }
        }

        /** The screen the check needs when it isn't the one in use (the cover is the tall, narrow one); else null. */
        private fun screenLine(need: String): String? {
            val b = wm.currentWindowMetrics.bounds
            val folded = b.width() < b.height() * 0.6f
            return when {
                need == "inner" && folded -> "Unfold the phone"
                need == "cover" && !folded -> "Fold the phone"
                else -> null
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
                // Touchable only on its action (touchRegion); before Android 14, not at all. Every other touch goes to
                // what's under it (a check's taps, the user's finger).
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                    (if (canTouch) 0 else WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE) or
                    WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED,
                PixelFormat.TRANSLUCENT,
            ).apply {
                title = "PowOS verify status"
                // The bottom-left corner, under the dock's row: away from every window's title bar and grip.
                gravity = Gravity.BOTTOM or Gravity.START
                x = dp(SIDE_DP)
                fitInsetsTypes = 0
                layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                y = dp(BOTTOM_DP)
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
    private const val CORNER_DP = 12f
    private const val BOTTOM_DP = 2f
    private const val SIDE_DP = 6f
    private const val PILL_MAX_DP = 150f
    private val TINT = Color.argb(107, 18, 20, 26)
    private val INK = Color.argb(222, 255, 255, 255)
}
