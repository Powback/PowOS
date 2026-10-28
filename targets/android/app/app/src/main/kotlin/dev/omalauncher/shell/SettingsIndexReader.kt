package dev.omalauncher.shell

import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.ProviderInfo
import android.database.Cursor
import android.net.Uri
import android.os.Looper
import android.os.Process
import org.json.JSONArray
import org.json.JSONObject

/** Reads the same raw/XML/non-indexable sources as Android Settings search. No settings values are written. */
class SettingsIndexReader(private val context: Context) {
    private val entries = LinkedHashMap<String, JSONObject>()
    private val pm = context.packageManager

    fun read(): JSONArray {
        val providers = pm.queryIntentContentProviders(Intent("android.content.action.SEARCH_INDEXABLES_PROVIDER"), 0)
        providers.mapNotNull { it.providerInfo }.filter { it.exported && it.applicationInfo.flags and ApplicationInfo.FLAG_SYSTEM != 0 }
            .forEach { provider -> runCatching { readProvider(provider) }.onFailure { android.util.Log.w("PowosSettingsSearch", "Provider unavailable: ${provider.authority}", it) } }
        return JSONArray(entries.values.toList())
    }

    private fun query(provider: ProviderInfo, path: String): Cursor? = SettingsIndexQuery.query(
        context, Uri.parse("content://${provider.authority.split(';').first()}/settings/$path"),
    )

    private fun readProvider(provider: ProviderInfo) {
        // If exclusions cannot be read, don't expose stale, hidden or unsupported controls from this provider.
        val excluded = query(provider, "non_indexables_key")?.use { c -> buildSet<String> { while (c.moveToNext()) add(c.text("key")) } } ?: return
        query(provider, "indexables_xml_res")?.use { c -> while (c.moveToNext()) runCatching { readXml(provider, row(c), excluded) } }
        for (path in listOf("indexables_raw", "dynamic_indexables_raw")) {
            runCatching { query(provider, path)?.use { c -> while (c.moveToNext()) add(provider, row(c), excluded) } }
        }
    }

    private fun row(c: Cursor): JSONObject = JSONObject().apply {
        c.columnNames.forEach { name -> put(name, c.text(name)) }
    }

    private fun readXml(provider: ProviderInfo, parent: JSONObject, excluded: Set<String>) {
        val resources = pm.getResourcesForApplication(provider.applicationInfo)
        val id = parent.optString("xmlResId").toIntOrNull() ?: return
        SettingsXmlPreferences(resources, excluded).read(id).forEach { preference ->
            val data = JSONObject(parent.toString())
            preference.keys().forEach { key -> data.put(key, preference.get(key)) }
            add(provider, data, excluded)
        }
    }

    private fun add(provider: ProviderInfo, data: JSONObject, excluded: Set<String>) {
        val title = data.optString("title").trim()
        val key = data.optString("key")
        if (title.isBlank() || key in excluded || entries.size >= 20000) return
        val user = data.optString("user_id").toIntOrNull() ?: -1
        if (user != -1 && user != Process.myUid() / 100000) return
        val intent = destination(provider, data) ?: return
        val id = "indexed:${provider.authority}:${data.optString("className")}:${key.ifBlank { title }}"
        entries[id] = JSONObject().put("id", id).put("label", title)
            .put("keywords", entries[id]?.optString("label").orEmpty() + " " + listOf("screenTitle", "summaryOn", "summaryOff", "entries", "keywords").map { data.optString(it) }.joinToString(" "))
            .put("breadcrumb", data.optString("screenTitle")).put("intent", intent.toUri(Intent.URI_INTENT_SCHEME))
    }

    private fun destination(provider: ProviderInfo, data: JSONObject): Intent? {
        val action = data.optString("intentAction")
        val key = data.optString("key")
        val intent = if (action.isBlank()) {
            val fragment = data.optString("className").takeIf { it.isNotBlank() } ?: return null
            Intent("com.android.settings.SEARCH_RESULT_TRAMPOLINE").setPackage("com.android.settings")
                .putExtra(":settings:show_fragment", fragment).putExtra(":settings:show_fragment_title", data.optString("screenTitle"))
                .putExtra(":settings:source_metrics", 34)
        } else {
            val pkg = data.optString("intentTargetPackage").ifBlank { provider.packageName }
            Intent(action).setPackage(pkg).apply { data.optString("intentTargetClass").takeIf { it.isNotBlank() }?.let { setClassName(pkg, it) } }
        }
        intent.putExtra(":settings:fragment_args_key", key)
        val info = pm.resolveActivity(intent, android.content.pm.PackageManager.MATCH_DEFAULT_ONLY)?.activityInfo ?: return null
        return intent.takeIf { info.enabled && info.exported && info.applicationInfo.flags and ApplicationInfo.FLAG_SYSTEM != 0 }
    }

    private fun Cursor.text(name: String): String = getColumnIndex(name).let { if (it < 0 || isNull(it)) "" else getString(it).orEmpty() }

    companion object {
        /** Isolated read-only root worker, loaded from the installed APK; never accepts arbitrary provider/intent input. */
        @JvmStatic fun main(args: Array<String>) {
            check(Process.myUid() == 0) { "Settings index export requires system access" }
            Looper.prepareMainLooper()
            val threadClass = Class.forName("android.app.ActivityThread")
            val thread = threadClass.getMethod("systemMain").invoke(null)
            val context = threadClass.getMethod("getSystemContext").invoke(thread) as Context
            println("POWOS_SETTINGS_INDEX=" + SettingsIndexReader(context).read().toString())
            kotlin.system.exitProcess(0)
        }
    }
}
