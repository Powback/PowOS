package dev.omalauncher

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import dev.omalauncher.linux.Guest
import org.json.JSONObject
import java.io.Writer

/**
 * PowOS's native Claude sign-in (the user, 11-06: "it should detect when signin is missing or needs refresh and have a
 * login button which opens the url and shows the code input box"). claude-login end to end, through
 * `powos manager --fleet-login` (lib/ai/manager/fleet_login.py), whichever backend this phone's claude uses:
 *
 *  - authority: the fleet's claude-auth.pow (endpoint.conf). The authority runs claude-login for the tenant and stays
 *    the only refresher; this phone never holds a refresh token or writes a .credentials.json.
 *  - direct: no endpoint (a sellable non-root install). claude-login runs in PowOS's Linux and writes the image's own
 *    login.
 *
 * Login: one held process (`--fleet-login login`) - its first line is the sign-in URL (opened in the phone's browser,
 * while the page shows the code box at once), the pasted code#state goes to its stdin, its last line says done or why
 * not. No `/login` in a terminal, ever. Works rooted and not ([Guest]: the session or the engine's image). The page
 * reads [json] in the chat state (ShellBridge.aiChat), so every change reaches it without a call.
 */
object ClaudeSignIn {
    private const val TAG = "claude-signin"
    private const val CHANNEL = "claude-signin-v1"
    private const val NOTIFICATION = 0x5197

    /** ""/idle, "starting" (asked the authority / claude-login for the link), "code" (link open: paste), "checking", "done", "error". */
    var phase by mutableStateOf("")
        private set
    var url by mutableStateOf("")
        private set
    var error by mutableStateOf("")
        private set

    /** The last status: mode (authority / direct), state (ok / missing / refresh / unknown), tenant, why. */
    var status by mutableStateOf(JSONObject())
        private set

    private var proc: Process? = null
    private var stdin: Writer? = null
    private var asking = false
    private var notified = false
    private val main = Handler(Looper.getMainLooper())

    fun json(): JSONObject =
        JSONObject()
            .put("phase", phase)
            .put("url", url)
            .put("error", error)
            .put("mode", status.optString("mode"))
            .put("state", status.optString("state"))
            .put("tenant", status.optString("tenant").takeUnless { it == "null" } ?: "")
            .put("why", status.optString("why"))
            .put("canLogin", status.optBoolean("canLogin", true))

    /** One line of the held login's output: the link, done, or the error. Null for anything else. */
    data class Event(
        val url: String? = null,
        val done: Boolean = false,
        val error: String? = null,
    )

    fun event(line: String): Event? {
        val o = runCatching { JSONObject(line.trim()) }.getOrNull() ?: return null
        return when {
            !o.optBoolean("ok", false) -> Event(error = o.optString("error").ifBlank { "sign-in failed" })
            o.optBoolean("done") -> Event(done = true)
            o.optString("authorizeUrl").startsWith("https://") -> Event(url = o.getString("authorizeUrl"))
            else -> null
        }
    }

    /** The notification's and the sheet's title: whose login it is when the authority says (its tenant). */
    fun title(tenant: String?): String = "Claude sign-in needed" + (tenant?.takeIf { it.isNotBlank() && it != "null" }?.let { " - $it" } ?: "")

    /** Asks for the status again (a background thread; once at a time). */
    fun refresh(context: Context? = null) {
        if (!Guest.enabled || asking) return
        asking = true
        Thread({
            val st = readStatus()
            main.post {
                asking = false
                took(st, context)
            }
        }, "claude-signin-status").start()
    }

    private fun readStatus(): JSONObject? {
        val out = StringBuilder()
        runCatching { Guest.runOwn("exec powos manager --fleet-login status 2>/dev/null") { out.append(it).append('\n') } }
        return out.lineSequence().mapNotNull { runCatching { JSONObject(it) }.getOrNull() }.lastOrNull()
    }

    /** A status read: kept; the notification once per need (again only after the login worked in between). */
    private fun took(
        st: JSONObject?,
        context: Context?,
    ) {
        if (st == null) return
        status = st
        val need = needed()
        if (need && !notified && context != null) notifyNeeded(context)
        notified = need && (notified || context != null)
    }

    private fun needed() = status.optString("state") in setOf("missing", "refresh")

    /** The Login button: the code box shows at once ("starting"), the link opens in the browser as soon as it's there. */
    fun start(context: Context) {
        if (!Guest.enabled) return fail(Guest.NEEDS_IMAGE)
        cancelProcess()
        phase = "starting"
        url = ""
        error = ""
        val app = context.applicationContext
        Thread({ hold(app) }, "claude-signin").start()
    }

    /** The held login (a background thread): its lines to [on], its end to [ended]. */
    private fun hold(app: Context) {
        val p =
            runCatching { Guest.process("exec powos manager --fleet-login login", mergeErrors = false).start() }
                .getOrElse {
                    main.post { fail("couldn't start the sign-in: ${it.message}") }
                    return
                }
        main.post {
            proc = p
            stdin = p.outputStream.bufferedWriter()
        }
        // Its stderr's last words, for when it ends without a line of its own: an image whose `powos manager` has no
        // --fleet-login (the non-root razr's, 11-09) said only "the sign-in stopped - try again", with the reason
        // ("not signed in to Claude ...") thrown away.
        val why = StringBuffer()
        val errors =
            Thread({
                runCatching {
                    p.errorStream.bufferedReader().forEachLine { line ->
                        if (line.isNotBlank()) {
                            why.setLength(0)
                            why.append(line.trim())
                        }
                    }
                }
            }, "claude-signin-errors").apply { start() }
        runCatching {
            p.inputStream.bufferedReader().forEachLine { line ->
                event(line)?.let { ev -> main.post { if (proc === p) on(app, ev) } }
            }
            p.waitFor()
        }.onFailure { Log.w(TAG, "sign-in process", it) }
        runCatching { errors.join(2000) }
        val last = why.toString()
        if (last.isNotEmpty()) Log.w(TAG, "sign-in ended: $last")
        main.post { ended(p, last) }
    }

    private fun on(
        app: Context,
        ev: Event,
    ) {
        when {
            ev.url != null -> {
                url = ev.url
                phase = "code"
                open(app, ev.url)
            }
            ev.done -> {
                phase = "done"
                cancelNotification(app)
                PowosAiChat.checkAuth()
                refresh()
            }
            ev.error != null -> fail(ev.error)
        }
    }

    private fun ended(
        p: Process,
        why: String = "",
    ) {
        if (proc !== p) return
        proc = null
        stdin = null
        if (phase == "starting" || phase == "code" || phase == "checking") fail(stoppedMessage(why))
    }

    /** What the sheet says when the login ended without saying done or why: its stderr's last line when it had one. */
    fun stoppedMessage(why: String): String {
        val w = why.trim().removePrefix("manager: ").take(240)
        return if (w.isEmpty()) "the sign-in stopped - try again" else "the sign-in stopped: $w"
    }

    /** The pasted code#state, into the waiting login. */
    fun complete(code: String) {
        val c = code.trim()
        if (c.isEmpty()) return fail("paste the code from claude.com first")
        val w = stdin ?: return fail("the sign-in isn't running any more - tap Login again")
        phase = "checking"
        error = ""
        Thread({
            runCatching {
                w.write(c + "\n")
                w.flush()
            }.onFailure { main.post { fail("couldn't hand over the code - tap Login again") } }
        }, "claude-signin-code").start()
    }

    /** The sheet closed: the login stops, the state stays as the status says. */
    fun cancel() {
        cancelProcess()
        phase = ""
        url = ""
        error = ""
    }

    /** Opens the link again (the user closed the browser tab). */
    fun reopen(context: Context) {
        if (url.isNotEmpty()) open(context.applicationContext, url)
    }

    private fun fail(why: String) {
        phase = "error"
        error = why
    }

    private fun cancelProcess() {
        val p = proc ?: return
        proc = null
        stdin = null
        Thread({ runCatching { p.destroy() } }, "claude-signin-stop").start()
    }

    private fun open(
        context: Context,
        link: String,
    ) {
        runCatching {
            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(link)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }.onFailure { Log.w(TAG, "no browser for the sign-in link", it) }
    }

    /** "Claude sign-in needed - powback": tap for the AI page, where the sheet is. Posted once per need. */
    fun notifyNeeded(context: Context) {
        val nm = context.getSystemService(NotificationManager::class.java) ?: return
        runCatching {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Claude sign-in", NotificationManager.IMPORTANCE_HIGH))
            val open =
                PendingIntent.getActivity(
                    context,
                    NOTIFICATION,
                    Intent(context, PowosAiActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                )
            nm.notify(
                TAG,
                NOTIFICATION,
                Notification.Builder(context, CHANNEL)
                    .setSmallIcon(R.drawable.ic_notification)
                    .setContentTitle(title(status.optString("tenant")))
                    .setContentText(notificationText(status.optString("state")))
                    .setContentIntent(open)
                    .setAutoCancel(true)
                    .setOnlyAlertOnce(true)
                    .setCategory(Notification.CATEGORY_ERROR)
                    .build(),
            )
        }.onFailure { Log.w(TAG, "notify", it) }
    }

    fun notificationText(state: String): String =
        if (state == "missing") "PowOS AI and claude aren't signed in. Tap to log in." else "The Claude login expired. Tap to log in again."

    private fun cancelNotification(context: Context) {
        runCatching { context.getSystemService(NotificationManager::class.java)?.cancel(TAG, NOTIFICATION) }
    }
}
