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

    fun open(context: Context, id: String, anchor: org.json.JSONObject? = null) {
        val entry = entries[id] ?: error("Settings result expired; search again")
        val intent = Intent.parseUri(entry.getString("intent"), Intent.URI_INTENT_SCHEME).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        // Intent URI serialization drops nested Bundles. Restore Android's preference arguments at launch.
        val key = intent.getStringExtra(":settings:fragment_args_key")
        if (!key.isNullOrBlank()) {
            val args = android.os.Bundle().apply { putString(":settings:fragment_args_key", key) }
            intent.putExtra(":settings:show_fragment_args", args)
        }
        val label = entry.getString("label")
        if (!intent.getStringExtra(":settings:show_fragment").isNullOrBlank() && rooted()) return fragmentPage(context, intent, label, anchor)
        try {
            QuickPages.launch(context, intent, label, anchor)
        } catch (e: SecurityException) {
            unavailable(context, label)
        } catch (e: android.content.ActivityNotFoundException) {
            unavailable(context, label)
        }
    }

    private fun rooted() = RootMode.enabled() && android.os.Process.myUid() / 100000 == 0

    /** quickpage.open({fragment}): com.android.settings fragment [fragment] as a quick page (root SubSettings only). */
    fun openFragmentPage(context: Context, fragment: String, label: String, anchor: org.json.JSONObject?) {
        check(rooted()) { "Settings fragments need root mode" }
        fragmentPage(context, Intent().putExtra(":settings:show_fragment", fragment).putExtra(":settings:show_fragment_title", label), label, anchor)
    }

    /**
     * [intent]'s fragment through the root SubSettings launcher, as a quick page (its own task: MULTIPLE_TASK, never the
     * main Settings window's); its pop-out is the same fragment in Settings' window.
     */
    private fun fragmentPage(context: Context, intent: Intent, label: String, anchor: org.json.JSONObject?) {
        intent.setClassName("com.android.settings", "com.android.settings.SubSettings").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val popOut = {
            val plain = QuickPages.poppedOut(intent)
            // Web desktop: Settings' window first, the page started on its display (AppWindows.launch).
            dev.omalauncher.system.AppWindows.launch(context, "com.android.settings") { openFragment(context, plain, label, it) }
        }
        QuickPages.launch(context, QuickPages.Page(intent, label, anchor, { openFragment(context, intent, label, it) }, popOut))
    }

    private fun openFragment(context: Context, intent: Intent, title: String, options: android.os.Bundle?) {
        val parcel = android.os.Parcel.obtain()
        val payload = try {
            parcel.writeBundle(android.os.Bundle().apply {
                putParcelable("intent", intent)
                putBundle("options", options)
            })
            android.util.Base64.encodeToString(parcel.marshall(), android.util.Base64.NO_WRAP)
        } finally { parcel.recycle() }
        val app = context.applicationContext
        worker.execute {
            val result = RootShell.run("timeout 15s env CLASSPATH=${quote(app.applicationInfo.sourceDir)} app_process /system/bin ${SettingsIndexLauncher::class.java.name} ${quote(payload)}", null, 20_000)
            if (result.code != 0) {
                Log.w("PowosSettingsSearch", "Fragment navigation failed: ${result.code}")
                android.os.Handler(android.os.Looper.getMainLooper()).post { unavailable(app, title) }
            }
        }
    }

    private fun unavailable(context: Context, title: String) {
        android.widget.Toast.makeText(context, "Cannot open $title on this device", android.widget.Toast.LENGTH_LONG).show()
    }

    private fun quote(value: String) = "'" + value.replace("'", "'\\''") + "'"
}
