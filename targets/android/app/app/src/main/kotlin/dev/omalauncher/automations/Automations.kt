package dev.omalauncher.automations

import android.annotation.SuppressLint
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.location.LocationManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.service.notification.NotificationListenerService
import android.util.Log
import dev.omalauncher.R
import dev.omalauncher.widgets.runtime.MediaListener
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.Calendar
import java.util.concurrent.Executors

/**
 * Automations (board task automations-triggers-and-actions, docs/research/stock-parity-gaps.md): the user's own
 * "when X, do Y", built in Settings > automations (shell/ui/automations.ts). They run here in the app - alarms,
 * broadcast receivers, proximity alerts - never in the WebView, so they run with no page open and after a reboot
 * (BootReceiver; the app's start re-arms everything too). No root anywhere.
 *
 * Triggers: time of day (+ weekdays: AlarmManager exact alarms, targetSdk 28 needs no exact-alarm permission),
 * arriving at / leaving a saved place (LocationManager.addProximityAlert: the framework's, no Play services), an app
 * opened from PowOS (AppUsage.record), the charger in / out and a Bluetooth device connecting / going (receivers
 * registered in the app's process: Android delivers neither to a manifest receiver of an app targeting 26+).
 * Optional conditions: weekdays and a from-to time window. Actions: notify, open an app or URL, Wi-Fi / Bluetooth /
 * Do not disturb on or off (the same no-root calls as the control center: targetSdk 28's setWifiEnabled and
 * BluetoothAdapter, DND through PowOS's notification listener), a focus mode (the page owns focus state, ui/focus.ts:
 * told now through "automations.focus", or on its next start), and any App API action (appcap_serve.py's POST /call,
 * consumer "automation": the runtime's own safety rules decide, as for every consumer).
 *
 * Stored in prefs "automations" as the page's JSON list (shell/ui/automations.ts Automation), plus each one's last run.
 */
object Automations {
    private const val TAG = "automations"
    private const val PREFS = "automations"
    private const val CHANNEL = "automations"
    const val ACTION_TIME = "com.powos.app.automations.TIME"
    const val ACTION_PLACE = "com.powos.app.automations.PLACE"
    private const val APP_API = "http://127.0.0.1:3411"

    private val io = Executors.newSingleThreadExecutor()
    private var app: Context? = null
    private var started = false

    /** Pages told of a run / a focus change (ShellBridge.broadcastAll, set by the bridge so this needs no shell). */
    @Volatile var tell: ((String, String) -> Unit)? = null

    private fun prefs(c: Context) = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun list(c: Context): JSONArray = runCatching { JSONArray(prefs(c).getString("list", "[]")) }.getOrElse { JSONArray() }

    /** The page's list saved (the editor's whole list), everything re-armed. */
    fun save(c: Context, list: JSONArray) {
        // Last-run lines are the app's: kept from what is stored, never the page's copy.
        val old = list(c).let { o -> (0 until o.length()).associate { o.getJSONObject(it).optString("id") to o.getJSONObject(it) } }
        for (i in 0 until list.length()) {
            val a = list.getJSONObject(i)
            old[a.optString("id")]?.let { o -> for (k in listOf("lastRan", "lastResult")) if (o.has(k)) a.put(k, o.get(k)) }
        }
        prefs(c).edit().putString("list", list.toString()).apply()
        arm(c.applicationContext)
    }

    /** App.onCreate: in the main process only, the pages told through every open shell window. */
    fun startApp(c: android.app.Application) {
        if (android.app.Application.getProcessName() != c.packageName) return
        tell = { e, j -> dev.omalauncher.shell.ShellBridge.broadcastAll(e, j) }
        start(c)
    }

    /** From App.onCreate (main process) and BootReceiver: receivers on, alarms and places armed. Idempotent. */
    @Synchronized
    fun start(c: Context) {
        val ctx = c.applicationContext
        app = ctx
        if (!started) {
            started = true
            ctx.registerReceiver(
                object : BroadcastReceiver() {
                    override fun onReceive(context: Context, i: Intent) {
                        when (i.action) {
                            Intent.ACTION_POWER_CONNECTED -> fire(ctx, "charger") { it.optString("when", "connected") == "connected" }
                            Intent.ACTION_POWER_DISCONNECTED -> fire(ctx, "charger") { it.optString("when") == "disconnected" }
                            BluetoothDevice.ACTION_ACL_CONNECTED, BluetoothDevice.ACTION_ACL_DISCONNECTED -> bluetooth(ctx, i)
                        }
                    }
                },
                IntentFilter().apply {
                    addAction(Intent.ACTION_POWER_CONNECTED)
                    addAction(Intent.ACTION_POWER_DISCONNECTED)
                    addAction(BluetoothDevice.ACTION_ACL_CONNECTED)
                    addAction(BluetoothDevice.ACTION_ACL_DISCONNECTED)
                },
            )
        }
        arm(ctx)
    }

    @SuppressLint("MissingPermission")
    private fun bluetooth(c: Context, i: Intent) {
        val d: BluetoothDevice? = i.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
        val name = runCatching { d?.name }.getOrNull().orEmpty()
        val addr = d?.address.orEmpty()
        val connected = i.action == BluetoothDevice.ACTION_ACL_CONNECTED
        fire(c, "bluetooth") { t ->
            val want = t.optString("device")
            (t.optString("when", "connected") == "connected") == connected &&
                (want.isBlank() || want.equals(name, true) || want.equals(addr, true))
        }
    }

    /** An app opened from PowOS (AppUsage.record: "a:<package>/<activity>", "w:<web app>"). */
    fun appOpened(key: String) {
        val c = app ?: return
        val pkg = if (key.startsWith("a:")) key.removePrefix("a:").substringBefore('/').substringBefore('@') else key
        fire(c, "app") { it.optString("pkg") == pkg || it.optString("pkg") == key }
    }

    /** Every on automation whose trigger is [kind] and [match]es, conditions met: its actions run. */
    private fun fire(c: Context, kind: String, match: (JSONObject) -> Boolean) {
        val l = list(c)
        for (i in 0 until l.length()) {
            val a = l.getJSONObject(i)
            val t = a.optJSONObject("trigger") ?: continue
            if (!a.optBoolean("on", true) || t.optString("kind") != kind || !match(t) || !conditions(a)) continue
            run(c, a.optString("id"), "trigger")
        }
    }

    private fun minutes(hhmm: String): Int? = hhmm.split(':').takeIf { it.size == 2 }?.let { (h, m) -> h.toIntOrNull()?.times(60)?.plus(m.toIntOrNull() ?: return null) }

    /** Optional conditions: weekdays (0 = Sunday), a from-to window (over midnight when to < from). */
    private fun conditions(a: JSONObject): Boolean {
        val k = a.optJSONObject("conditions") ?: return true
        val now = Calendar.getInstance()
        k.optJSONArray("days")?.takeIf { it.length() > 0 }?.let { d ->
            if ((0 until d.length()).none { d.getInt(it) == now.get(Calendar.DAY_OF_WEEK) - 1 }) return false
        }
        val from = minutes(k.optString("from")) ?: return true
        val to = minutes(k.optString("to")) ?: return true
        val m = now.get(Calendar.HOUR_OF_DAY) * 60 + now.get(Calendar.MINUTE)
        return if (from <= to) m in from until to else m >= from || m < to
    }

    /** [id]'s actions, in order, off the main thread; its last-run line stored and the pages told. */
    fun run(c: Context, id: String, why: String, done: (() -> Unit)? = null) {
        val ctx = c.applicationContext
        io.execute { try { runNow(ctx, id, why) } finally { done?.invoke() } }
    }

    private fun runNow(ctx: Context, id: String, why: String) {
        val a = find(ctx, id) ?: return
        val acts = a.optJSONArray("actions") ?: JSONArray()
        val results = (0 until acts.length()).map { i ->
            runCatching { act(ctx, acts.getJSONObject(i)) }.getOrElse { "failed: ${it.message}" }
        }
        val line = results.joinToString(" · ").ifEmpty { "no actions" }
        Log.i(TAG, "${a.optString("name")} ($why): $line")
        synchronized(this) {
            val l = list(ctx)
            for (i in 0 until l.length()) {
                val o = l.getJSONObject(i)
                if (o.optString("id") == id) o.put("lastRan", System.currentTimeMillis()).put("lastResult", line)
            }
            prefs(ctx).edit().putString("list", l.toString()).commit()
        }
        tell?.invoke("automations.ran", JSONObject().put("id", id).put("result", line).toString())
    }

    private fun find(c: Context, id: String): JSONObject? {
        val l = list(c)
        return (0 until l.length()).map { l.getJSONObject(it) }.firstOrNull { it.optString("id") == id }
    }

    /** One action; what it did, in a few words. */
    private fun act(c: Context, x: JSONObject): String =
        when (x.optString("kind")) {
            "notify" -> notify(c, x.optString("title", "Automation"), x.optString("text")).let { "notified" }
            "open" -> open(c, x.optString("target"))
            "toggle" -> toggle(c, x.optString("what"), x.optBoolean("on", true))
            "focus" -> focus(c, x.optString("mode"))
            "appapi" -> appApi(x)
            else -> "unknown action"
        }

    private fun open(c: Context, target: String): String {
        val i =
            if (target.contains("://")) Intent(Intent.ACTION_VIEW, Uri.parse(target))
            else c.packageManager.getLaunchIntentForPackage(target) ?: error("no app $target")
        c.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        return "opened $target"
    }

    /** Wi-Fi / Bluetooth / Do not disturb: the no-root calls targetSdk 28 keeps (the control center's direct path). */
    @SuppressLint("MissingPermission")
    @Suppress("DEPRECATION")
    private fun toggle(c: Context, what: String, on: Boolean): String {
        val ok =
            when (what) {
                "wifi" -> c.getSystemService(WifiManager::class.java)?.setWifiEnabled(on) == true
                "bt" -> BluetoothAdapter.getDefaultAdapter()?.let { if (on) it.enable() else it.disable() } == true
                "dnd" -> dnd(on)
                else -> false
            }
        return "$what ${if (on) "on" else "off"}${if (ok) "" else " refused"}"
    }

    /** The page owns the focus (ui/focus.ts): told now, or on its next start (automations.takeFocus). */
    private fun focus(c: Context, mode: String): String {
        prefs(c).edit().putString("focus", mode.ifEmpty { "off" }).apply()
        dnd(mode.isNotEmpty())
        tell?.invoke("automations.focus", JSONObject.quote(mode.ifEmpty { "off" }))
        return if (mode.isEmpty()) "focus off" else "focus $mode"
    }

    private fun dnd(on: Boolean): Boolean {
        val l = MediaListener.connected ?: return false
        l.requestInterruptionFilter(if (on) NotificationListenerService.INTERRUPTION_FILTER_PRIORITY else NotificationListenerService.INTERRUPTION_FILTER_ALL)
        return true
    }

    /** A focus mode an automation set while no page was there to take it ("off": end it); null: none waiting. */
    fun takeFocus(c: Context): String? = prefs(c).getString("focus", null)?.also { prefs(c).edit().remove("focus").apply() }

    fun notify(c: Context, title: String, text: String) {
        val nm = c.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Automations", NotificationManager.IMPORTANCE_DEFAULT).apply { description = "What your automations post" })
        nm.notify(
            ("automation:$title:$text").hashCode(),
            Notification.Builder(c, CHANNEL).setSmallIcon(R.drawable.ic_notification).setContentTitle(title).setContentText(text).setAutoCancel(true).build(),
        )
    }

    /** An App API action through the device's runtime; its own refusal words when it says no. */
    private fun appApi(x: JSONObject): String {
        val body = JSONObject().put("app", x.optString("app")).put("action", x.optString("action")).put("args", x.optJSONObject("args") ?: JSONObject())
            .put("send", true).put("consumer", "automation")
        val r = JSONObject(http("POST", "/call", body.toString()))
        return r.optString("refused").takeIf { it.isNotEmpty() }?.let { "${x.optString("action")}: $it" }
            ?: r.optString("error").takeIf { it.isNotEmpty() }?.let { "${x.optString("action")}: $it" }
            ?: "${x.optString("app")}.${x.optString("action")} ran"
    }

    /** App API's apps and their enabled actions, for the editor (off the main thread: ShellBridge OFF_MAIN). */
    fun apiActions(): JSONArray {
        val apps = runCatching { JSONObject(http("GET", "/apps", null)).optJSONArray("apps") ?: JSONArray(http("GET", "/apps", null)) }.getOrElse { return JSONArray() }
        val out = JSONArray()
        for (i in 0 until apps.length()) {
            val a = apps.getJSONObject(i)
            if (!a.optBoolean("enabled", true)) continue
            val acts = a.optJSONObject("actions") ?: continue
            for (k in acts.keys()) {
                val x = acts.getJSONObject(k)
                if (!x.optBoolean("enabled", true)) continue
                out.put(JSONObject().put("app", a.optString("app")).put("appName", a.optString("name")).put("action", k).put("summary", x.optString("summary")).put("safety", x.optString("safety")))
            }
        }
        return out
    }

    private fun http(method: String, path: String, body: String?): String {
        val u = URL(APP_API + path).openConnection() as HttpURLConnection
        u.requestMethod = method
        u.connectTimeout = 3000
        u.readTimeout = 35000
        if (body != null) {
            u.doOutput = true
            u.setRequestProperty("content-type", "application/json")
            u.outputStream.use { it.write(body.toByteArray()) }
        }
        val s = (if (u.responseCode >= 400) u.errorStream else u.inputStream)?.bufferedReader()?.readText().orEmpty()
        u.disconnect()
        return s.ifEmpty { "{}" }
    }

    /** Where the phone is now (the last known fix), for "use where I am" on a place trigger; null: none. */
    @SuppressLint("MissingPermission")
    fun here(c: Context): JSONObject? {
        val lm = c.getSystemService(LocationManager::class.java) ?: return null
        val fix =
            runCatching { lm.getProviders(true).mapNotNull { lm.getLastKnownLocation(it) }.maxByOrNull { it.time } }.getOrNull()
                ?: return null
        return JSONObject().put("lat", fix.latitude).put("lng", fix.longitude).put("accuracy", fix.accuracy.toDouble())
    }

    fun charging(c: Context): Boolean = c.getSystemService(BatteryManager::class.java)?.isCharging == true

    // --- arming: one exact alarm per time trigger, one proximity alert per place trigger

    private fun pending(c: Context, action: String, id: String, flags: Int = PendingIntent.FLAG_UPDATE_CURRENT): PendingIntent? =
        PendingIntent.getBroadcast(
            c,
            id.hashCode(),
            Intent(c, Receiver::class.java).setAction(action).setData(Uri.parse("powos-automation://$id")).putExtra("id", id),
            flags or PendingIntent.FLAG_IMMUTABLE,
        )

    private fun arm(c: Context) {
        val known = prefs(c).getStringSet("armed", emptySet())!!
        val l = list(c)
        val now = (0 until l.length()).mapNotNull { armOne(c, l.getJSONObject(it)) }.toSet()
        // Gone or switched off since: disarmed.
        for (k in known - now) disarm(c, k)
        prefs(c).edit().putStringSet("armed", now).apply()
    }

    /** One automation's alarm or proximity alert; its key ("t:<id>", "p:<id>"), null when nothing was armed. */
    @SuppressLint("MissingPermission")
    private fun armOne(c: Context, a: JSONObject): String? {
        val id = a.optString("id")
        val t = a.optJSONObject("trigger")?.takeIf { a.optBoolean("on", true) } ?: return null
        return when (t.optString("kind")) {
            "time" -> next(t)?.let { at ->
                c.getSystemService(AlarmManager::class.java).setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending(c, ACTION_TIME, id)!!)
                "t:$id"
            }
            "place" -> runCatching {
                c.getSystemService(LocationManager::class.java)
                    .addProximityAlert(t.getDouble("lat"), t.getDouble("lng"), t.optDouble("radius", 150.0).toFloat(), -1, pending(c, ACTION_PLACE, id)!!)
                "p:$id"
            }.onFailure { Log.w(TAG, "place $id not armed: ${it.message}") }.getOrNull()
            else -> null
        }
    }

    private fun disarm(c: Context, key: String) {
        val id = key.drop(2)
        val action = if (key.startsWith("t:")) ACTION_TIME else ACTION_PLACE
        val p = pending(c, action, id, PendingIntent.FLAG_NO_CREATE) ?: return
        if (action == ACTION_TIME) c.getSystemService(AlarmManager::class.java).cancel(p)
        else runCatching { c.getSystemService(LocationManager::class.java).removeProximityAlert(p) }
        p.cancel()
    }

    /** A time trigger's next moment after now: its "at" (HH:MM) on one of its days (none: every day). */
    fun next(t: JSONObject, from: Long = System.currentTimeMillis()): Long? {
        val m = minutes(t.optString("at")) ?: return null
        val days = t.optJSONArray("days")?.let { d -> (0 until d.length()).map { d.getInt(it) }.toSet() }.orEmpty()
        val cal = Calendar.getInstance().apply {
            timeInMillis = from
            set(Calendar.HOUR_OF_DAY, m / 60)
            set(Calendar.MINUTE, m % 60)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        repeat(8) {
            if (cal.timeInMillis > from && (days.isEmpty() || (cal.get(Calendar.DAY_OF_WEEK) - 1) in days)) return cal.timeInMillis
            cal.add(Calendar.DAY_OF_MONTH, 1)
        }
        return null
    }

    /** The alarms' and proximity alerts' receiver (exported=false: only the system's PendingIntents reach it). */
    class Receiver : BroadcastReceiver() {
        override fun onReceive(c: Context, i: Intent) {
            val id = i.getStringExtra("id") ?: return
            val a = find(c, id)?.takeIf { it.optBoolean("on", true) } ?: return
            if (i.action == ACTION_TIME) arm(c.applicationContext) // the next one
            if (due(a, i) && conditions(a)) goAsync().let { p -> run(c, id, i.action.orEmpty()) { p.finish() } }
        }

        /** A time alarm is always due; a place alert when its direction (arrive / leave) is the trigger's. */
        private fun due(a: JSONObject, i: Intent): Boolean {
            if (i.action != ACTION_PLACE) return i.action == ACTION_TIME
            val entering = i.getBooleanExtra(LocationManager.KEY_PROXIMITY_ENTERING, true)
            return (a.optJSONObject("trigger")?.optString("when", "arrive") == "arrive") == entering
        }
    }

    /** After a reboot: the app's process starts and everything is re-armed (alarms and proximity alerts don't survive). */
    class BootReceiver : BroadcastReceiver() {
        override fun onReceive(c: Context, i: Intent) {
            if (i.action == Intent.ACTION_BOOT_COMPLETED || i.action == Intent.ACTION_MY_PACKAGE_REPLACED) start(c)
        }
    }
}
