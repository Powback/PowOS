package dev.omalauncher.shell

import android.Manifest
import android.app.Activity
import android.app.AlarmManager
import android.content.BroadcastReceiver
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.CalendarContract
import android.util.Log
import dev.omalauncher.widgets.lang.Builtins
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.concurrent.Executors

/**
 * The lock face's glance under the clock (lock.tsx LockGlance): the next alarm (AlarmManager.nextAlarmClock), the next
 * calendar event of the next 12 hours (CalendarContract.Instances; READ_CALENDAR, asked once - [CalendarPermission];
 * without it no event) and the weather now. One state, "lock.glance": {alarm, event {title, at}, weather {temp, icon,
 * place}}, each part null when there's none - the page shows what is there.
 *
 * The weather is the today widget's (widgets/10-today.owl): wttr.in's j1 for the city typed into it (its persisted
 * `city`), else where the phone is by IP; its icon the widget's glyph (Builtins.weatherIcon). Kept 30 minutes, also
 * on disk: the face shows the last one at once and never waits for the network.
 */
object LockGlance {
    data class Event(
        val title: String,
        val begin: Long,
        val allDay: Boolean,
    )

    data class Weather(
        val temp: String,
        val icon: String,
        val place: String,
        val at: Long,
    )

    /** How far ahead an event is shown. */
    const val EVENT_AHEAD_MS = 12 * 60 * 60 * 1000L

    /** How long a weather reading is kept before it's asked again. */
    const val WEATHER_TTL_MS = 30 * 60 * 1000L

    /** Countries wttr's own panel shows in °F (the today widget's list). */
    private val IMPERIAL = setOf("united states", "united states of america", "liberia", "myanmar", "burma")

    /** The page's state: each part null when there's none (no alarm set, no event or no permission, no weather yet). */
    fun state(
        alarm: Long?,
        event: Event?,
        weather: Weather?,
    ): JSONObject =
        JSONObject()
            .put("alarm", alarm ?: JSONObject.NULL)
            .put("event", event?.let { JSONObject().put("title", it.title).put("at", it.begin) } ?: JSONObject.NULL)
            .put(
                "weather",
                weather?.let { JSONObject().put("temp", it.temp).put("icon", it.icon).put("place", it.place) } ?: JSONObject.NULL,
            )

    /**
     * The event to show: the first to start from [now] on, within [EVENT_AHEAD_MS]; all-day ones aren't "next" (one
     * would stand there all day), untitled ones say nothing.
     */
    fun nextEvent(
        rows: List<Event>,
        now: Long,
    ): Event? =
        rows
            .filter { !it.allDay && it.title.isNotBlank() && it.begin >= now && it.begin <= now + EVENT_AHEAD_MS }
            .minByOrNull { it.begin }
            ?.let { it.copy(title = it.title.trim()) }

    /** wttr.in's `?format=j1` answer as the glance's weather: °C, or °F where the widget shows °F; null if it isn't one. */
    fun weatherFrom(
        j1: JSONObject,
        now: Long,
    ): Weather? {
        val cur = j1.optJSONArray("current_condition")?.optJSONObject(0) ?: return null
        val area = j1.optJSONArray("nearest_area")?.optJSONObject(0)
        fun first(o: JSONObject?, key: String) = o?.optJSONArray(key)?.optJSONObject(0)?.optString("value").orEmpty().trim()
        val country = first(area, "country").lowercase()
        val unit = if (country in IMPERIAL) "F" else "C"
        val temp = cur.optString("temp_$unit").trim().takeIf { it.isNotEmpty() } ?: return null
        val night = first(cur, "weatherIconUrl").contains("_night")
        val code = cur.optString("weatherCode").toIntOrNull() ?: 0
        return Weather("$temp°", Builtins.weatherGlyph(code, night), first(area, "areaName"), now)
    }

    /** The today widget's city (its persisted `state city`), percent-encoded for wttr's path; empty: by IP. */
    fun cityQuery(saved: String?): String {
        val city = runCatching { JSONObject(saved ?: return "").optJSONObject("values")?.optString("city") }.getOrNull().orEmpty().trim()
        return if (city.isEmpty()) "" else URLEncoder.encode(city, "UTF-8")
    }

    // --- on the phone

    private const val TAG = "LockGlance"
    private val io = Executors.newSingleThreadExecutor()

    /** The weather's own thread: a slow wttr.in never holds up the alarm and the event. */
    private val net = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    @Volatile private var weather: Weather? = null

    @Volatile private var fetching = false

    /** The state now: the alarm and the event read as asked, the weather as last fetched. */
    fun read(context: Context): JSONObject = state(alarm(context), event(context), cachedWeather(context))

    private fun alarm(context: Context): Long? =
        runCatching { context.getSystemService(AlarmManager::class.java).nextAlarmClock?.triggerTime }.getOrNull()

    private fun calendarAllowed(context: Context) = context.checkSelfPermission(Manifest.permission.READ_CALENDAR) == PackageManager.PERMISSION_GRANTED

    private fun event(context: Context): Event? {
        if (!calendarAllowed(context)) return null
        val now = System.currentTimeMillis()
        val uri =
            CalendarContract.Instances.CONTENT_URI.buildUpon().also {
                ContentUris.appendId(it, now)
                ContentUris.appendId(it, now + EVENT_AHEAD_MS)
            }.build()
        val cols = arrayOf(CalendarContract.Instances.TITLE, CalendarContract.Instances.BEGIN, CalendarContract.Instances.ALL_DAY)
        return runCatching {
            context.contentResolver.query(uri, cols, null, null, "${CalendarContract.Instances.BEGIN} ASC")?.use { c ->
                val rows = ArrayList<Event>()
                while (c.moveToNext()) rows += Event(c.getString(0).orEmpty(), c.getLong(1), c.getInt(2) != 0)
                nextEvent(rows, now)
            }
        }.onFailure { Log.w(TAG, "calendar", it) }.getOrNull()
    }

    private fun cacheFile(context: Context) = File(context.filesDir, "lock-glance-weather.json")

    private fun cachedWeather(context: Context): Weather? =
        weather ?: runCatching {
            val o = JSONObject(cacheFile(context).readText())
            Weather(o.getString("temp"), o.getString("icon"), o.optString("place"), o.getLong("at"))
        }.getOrNull()?.also { weather = it }

    /** Older than [WEATHER_TTL_MS] (or none): asked again off the main thread, [done] with the state once it's in. */
    fun refreshWeather(
        context: Context,
        done: (JSONObject) -> Unit,
    ) {
        val app = context.applicationContext
        val now = System.currentTimeMillis()
        if ((cachedWeather(app)?.at ?: 0) + WEATHER_TTL_MS > now || fetching) return
        fetching = true
        net.execute {
            try {
                val saved = File(app.filesDir, "widget-state/10-today.owl.json").takeIf { it.isFile }?.readText()
                val conn = URL("https://wttr.in/${cityQuery(saved)}?format=j1").openConnection() as HttpURLConnection
                conn.connectTimeout = 8000
                conn.readTimeout = 10000
                val w = conn.inputStream.bufferedReader().use { weatherFrom(JSONObject(it.readText()), now) } ?: return@execute
                weather = w
                cacheFile(app).writeText(JSONObject().put("temp", w.temp).put("icon", w.icon).put("place", w.place).put("at", w.at).toString())
                val s = read(app)
                main.post { done(s) }
            } catch (e: Exception) {
                Log.i(TAG, "weather: ${e.message}")
            } finally {
                fetching = false
            }
        }
    }

    /**
     * While the face is up: the state pushed now and again on an alarm change, a calendar change and every 30 minutes
     * (the weather). Nothing while it's hidden; [start] on resume, [stop] on pause.
     */
    class Watch(
        private val context: Context,
        private val emit: (JSONObject) -> Unit,
    ) {
        private var on = false
        private val alarmChanged =
            object : BroadcastReceiver() {
                override fun onReceive(c: Context, intent: Intent) = push()
            }
        private val calendarChanged =
            object : ContentObserver(main) {
                override fun onChange(selfChange: Boolean) = push()
            }
        private val tick =
            object : Runnable {
                override fun run() {
                    refreshWeather(context, emit)
                    main.postDelayed(this, WEATHER_TTL_MS)
                }
            }

        private fun push() = io.execute { read(context).let { s -> main.post { if (on) emit(s) } } }

        fun start() {
            if (on) return
            on = true
            context.registerReceiver(alarmChanged, IntentFilter(AlarmManager.ACTION_NEXT_ALARM_CLOCK_CHANGED))
            if (calendarAllowed(context)) {
                runCatching { context.contentResolver.registerContentObserver(CalendarContract.CONTENT_URI, true, calendarChanged) }
            }
            push()
            main.post(tick)
        }

        fun stop() {
            if (!on) return
            on = false
            runCatching { context.unregisterReceiver(alarmChanged) }
            runCatching { context.contentResolver.unregisterContentObserver(calendarChanged) }
            main.removeCallbacks(tick)
        }
    }
}

/**
 * The calendar permission the lock face's next event needs, asked the PowOS way (as [dev.omalauncher.system.StatusPermission]):
 * once. Rooted, PowOS grants it to itself; not rooted, home asks the first time it comes up; a "no" is kept and the
 * glance shows no event.
 */
object CalendarPermission {
    const val REQUEST = 45
    private const val PREFS = "calendar-permission"
    private const val ASKED = "asked-read-calendar"

    /** True if it asked now (one permission dialog at a time: the caller asks nothing else this time). */
    fun askOnce(activity: Activity): Boolean {
        if (activity.checkSelfPermission(Manifest.permission.READ_CALENDAR) == PackageManager.PERMISSION_GRANTED) return false
        val prefs = activity.getSharedPreferences(PREFS, Activity.MODE_PRIVATE)
        if (prefs.getBoolean(ASKED, false)) return false
        prefs.edit().putBoolean(ASKED, true).apply()
        if (andro.marchy.RootMode.enabled()) {
            val pkg = activity.packageName
            Executors.newSingleThreadExecutor().execute {
                val r = andro.marchy.RootShell.run("pm grant $pkg ${Manifest.permission.READ_CALENDAR}")
                Log.i("LockGlance", "pm grant READ_CALENDAR: ${if (r.code == 0) "ok" else r.output}")
            }
            return false
        }
        activity.requestPermissions(arrayOf(Manifest.permission.READ_CALENDAR), REQUEST)
        return true
    }
}
