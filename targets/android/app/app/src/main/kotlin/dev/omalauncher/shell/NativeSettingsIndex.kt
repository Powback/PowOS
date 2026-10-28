package dev.omalauncher.shell

import android.content.Context
import android.content.Intent
import android.os.SystemClock
import android.util.Log
import andro.marchy.RootMode
import andro.marchy.RootShell
import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale
import java.util.concurrent.Executors

/** Process-wide immutable snapshot. Indexing is off the UI thread, demand-driven, and never runs per keystroke. */
object NativeSettingsIndex {
    private val worker = Executors.newSingleThreadExecutor()
    @Volatile private var entries = emptyMap<String, JSONObject>()
    @Volatile private var publicEntries = JSONArray()
    private var refreshed = -300_000L
    private var locale = ""
    private var loading = false

    @Synchronized fun destinations(context: Context, changed: () -> Unit): JSONArray {
        val language = Locale.getDefault().toLanguageTag()
        if (language != locale) { entries = emptyMap(); publicEntries = JSONArray() }
        if (!loading && (language != locale || SystemClock.elapsedRealtime() - refreshed > 300_000)) {
            loading = true
            val app = context.applicationContext
            worker.execute {
                try {
                    val result = read(app)
                    val snapshot = (0 until result.length()).map { result.getJSONObject(it) }.associateBy { it.getString("id") }
                    val publicSnapshot = JSONArray(snapshot.values.map { entry -> JSONObject(entry.toString()).apply { remove("intent") } })
                    synchronized(this) { entries = snapshot; publicEntries = publicSnapshot; locale = language }
                } catch (e: Exception) { Log.w("PowosSettingsSearch", "Index unavailable", e) }
                synchronized(this) { locale = language; refreshed = SystemClock.elapsedRealtime(); loading = false }
                changed()
            }
        }
        return publicEntries
    }

    private fun read(context: Context): JSONArray {
        if (context.checkSelfPermission("android.permission.READ_SEARCH_INDEXABLES") == android.content.pm.PackageManager.PERMISSION_GRANTED) {
            return SettingsIndexReader(context).read()
        }
        if (!RootMode.enabled() || android.os.Process.myUid() / 100000 != 0) return JSONArray()
        val apk = quote(context.applicationInfo.sourceDir)
        val result = RootShell.run("timeout 45s env CLASSPATH=$apk app_process /system/bin ${SettingsIndexReader::class.java.name}", null, 50_000)
        check(result.code == 0) { "Settings index worker exited ${result.code}" }
        val json = result.output.lineSequence().firstOrNull { it.startsWith("POWOS_SETTINGS_INDEX=") }?.substringAfter('=')
        return JSONArray(checkNotNull(json) { "Settings index worker returned no data" })
    }

    fun open(context: Context, id: String) {
        val entry = entries[id] ?: error("Settings result expired; search again")
        val intent = Intent.parseUri(entry.getString("intent"), Intent.URI_INTENT_SCHEME).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            context.startActivity(intent, dev.omalauncher.system.AppWindows.bundle(context))
        } catch (e: SecurityException) {
            searchFallback(context, entry.getString("label"))
        } catch (e: android.content.ActivityNotFoundException) {
            searchFallback(context, entry.getString("label"))
        }
    }

    private fun searchFallback(context: Context, title: String) {
        android.widget.Toast.makeText(context, "Opening Android settings search for $title", android.widget.Toast.LENGTH_SHORT).show()
        context.startActivity(Intent("android.settings.APP_SEARCH_SETTINGS").putExtra("query", title)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), dev.omalauncher.system.AppWindows.bundle(context))
    }

    private fun quote(value: String) = "'" + value.replace("'", "'\\''") + "'"
}
