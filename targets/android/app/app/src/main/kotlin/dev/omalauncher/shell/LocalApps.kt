package dev.omalauncher.shell

import android.content.Context
import dev.omalauncher.linux.EngineServices
import dev.omalauncher.linux.RootedGuest
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.InputStream

/**
 * The PowOS apps the launcher has itself, for a phone without root (docs/research/nonroot-parity.md #2): the ones whose
 * built UI ships inside the APK (assets/apps/<id>/, from the repo's apps/bundled.list - app/build.gradle.kts copyApps)
 * and the ones installed in the app's files (files/apps/<id>/current, `powos app install` on a rooted phone). Before
 * this an island's files and its registry row came only from `powos app install` inside the rooted session, so without
 * root every island stayed "…".
 *
 * An installed copy always wins over the APK's (a rooted phone's apps are as before; a newer install of a bundled app
 * is the one shown).
 */
object LocalApps {
    /** The APK's apps, by id (their asset folders). */
    fun bundled(ctx: Context): List<String> = runCatching { ctx.assets.list(ASSETS)?.toList() }.getOrNull().orEmpty()

    private fun installed(ctx: Context): List<String> = File(ctx.filesDir, "apps").list()?.filter { File(ctx.filesDir, "apps/$it/current/powos-app.json").isFile }.orEmpty()

    /** File [name] of app [id]'s UI: the installed one, else the APK's; null when neither has it. */
    fun open(
        ctx: Context,
        id: String,
        name: String,
    ): InputStream? {
        val ui = File(ctx.filesDir, "apps/$id/current/ui")
        if (ui.isDirectory) {
            val file = File(ui, name)
            return if (file.isFile && file.canonicalPath.startsWith(ui.canonicalPath + "/")) file.inputStream() else null
        }
        if (name.split('/').any { it == ".." || it.isEmpty() }) return null
        return runCatching { ctx.assets.open("$ASSETS/$id/ui/$name") }.getOrNull()
    }

    private fun manifest(
        ctx: Context,
        id: String,
    ): Pair<String, String>? {
        File(ctx.filesDir, "apps/$id/current/powos-app.json").takeIf { it.isFile }?.let { return it.readText() to "" }
        val text = runCatching { ctx.assets.open("$ASSETS/$id/powos-app.json").bufferedReader().use { it.readText() } }.getOrNull() ?: return null
        // The APK's copy changes with each APK: its version in the module URL, so a new APK's UI is imported anew.
        return text to "+apk${versionCode(ctx)}"
    }

    private fun versionCode(ctx: Context): Long =
        runCatching {
            val p = ctx.packageManager.getPackageInfo(ctx.packageName, 0)
            if (android.os.Build.VERSION.SDK_INT >= 28) p.longVersionCode else @Suppress("DEPRECATION") p.versionCode.toLong()
        }.getOrDefault(0L)

    /** The page's apps.local (shell/apps/localapps.ts LocalApps): rooted, where SpacetimeDB stands, the apps as registry rows. */
    fun json(ctx: Context): JSONObject {
        val rooted = RootedGuest.enabled
        val o = JSONObject().put("rooted", rooted).put("stdb", if (rooted) "up" else EngineServices.state(ctx)).put("mb", JSONObject.NULL)
        // No root: SpacetimeDB for the page only through the token gate (the TCP port 3410 isn't there).
        if (!rooted) dev.omalauncher.linux.LoopbackGate.url(3410)?.let { o.put("stdbUrl", "ws" + it.removePrefix("http")) }
        val apps = JSONArray()
        if (!rooted) {
            for (id in (installed(ctx) + bundled(ctx)).distinct()) {
                val (text, suffix) = manifest(ctx, id) ?: continue
                apps.put(row(id, text, suffix) ?: continue)
            }
        }
        return o.put("apps", apps)
    }

    /** An app's registry row (shell/apps/registry.ts RegistryApp) from its manifest; null for a broken one. */
    fun row(
        id: String,
        manifest: String,
        versionSuffix: String,
    ): JSONObject? {
        val m = runCatching { JSONObject(manifest) }.getOrNull() ?: return null
        if (m.optString("id") != id) return null
        return JSONObject()
            .put("id", id)
            .put("name", m.optString("name", id))
            .put("version", m.optString("version", "0") + versionSuffix)
            .put("database", m.optJSONObject("module")?.optString("database").orEmpty())
            .put("tier", 0)
            .put("manifest", manifest)
    }

    /** The APK's apps' modules, "<database>" to its asset path, for EngineServices to publish. */
    fun modules(ctx: Context): Map<String, String> =
        bundled(ctx).mapNotNull { id ->
            val (text, _) = manifest(ctx, id) ?: return@mapNotNull null
            val db = runCatching { JSONObject(text).optJSONObject("module")?.optString("database") }.getOrNull()
            if (db.isNullOrEmpty() || runCatching { ctx.assets.open("$ASSETS/$id/module.wasm").close() }.isFailure) null else db to "$ASSETS/$id/module.wasm"
        }.toMap()

    private const val ASSETS = "apps"
}
