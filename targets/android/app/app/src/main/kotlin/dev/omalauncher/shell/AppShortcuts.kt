package dev.omalauncher.shell

import android.content.Context
import android.content.pm.LauncherApps
import android.content.pm.ShortcutInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import android.util.Base64
import android.util.Log
import dev.omalauncher.AndroidApp
import dev.omalauncher.system.AppWindows
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream

/**
 * An Android app's own shortcuts, as stock launchers show them on a long press (Chrome "New tab", Gmail "Compose"):
 * "apps.shortcuts" lists them for the app menu (shell/ui/apps.tsx AppMenu), "apps.startShortcut" starts one. Only the
 * default launcher (or a holder of the shortcut host permission) may read them; anyone else gets none.
 */
object AppShortcuts {
    private const val TAG = "PowosShortcuts"

    /** As many as stock launchers' popup shows (Launcher3 MAX_SHORTCUTS). */
    const val MAX = 4

    /** The icon's edge in px for the menu's 24-28 px rows at up to 3.5x. */
    private const val ICON_PX = 96

    /** One shortcut, as the page gets it ([icon]: a PNG data URL, null: none). */
    data class Entry(
        val id: String,
        val label: String,
        val enabled: Boolean,
        val rank: Int,
        val manifest: Boolean,
        val dynamic: Boolean,
        val icon: String? = null,
    )

    /**
     * What the menu shows, in stock order: enabled before disabled, the manifest's (static) before dynamic ones before
     * ones only pinned, each by its own rank; unlabelled ones never; at most [MAX].
     */
    fun pick(all: List<Entry>): List<Entry> =
        all.filter { it.label.isNotBlank() }
            .distinctBy { it.id }
            .sortedWith(compareBy<Entry>({ !it.enabled }, { if (it.manifest) 0 else if (it.dynamic) 1 else 2 }, { it.rank }))
            .take(MAX)

    fun toJson(list: List<Entry>): JSONArray =
        JSONArray().also { out ->
            for (e in list) out.put(JSONObject().put("id", e.id).put("label", e.label).put("enabled", e.enabled).put("icon", e.icon ?: JSONObject.NULL))
        }

    /** [app]'s shortcuts for the menu; none when this isn't the shortcut host or the app has none. Off the UI thread. */
    fun read(
        context: Context,
        app: AndroidApp,
    ): JSONArray {
        val la = context.getSystemService(LauncherApps::class.java) ?: return JSONArray()
        val infos = query(la, app) ?: return JSONArray()
        val density = context.resources.displayMetrics.densityDpi
        val byId = infos.associateBy { it.id }
        val picked = pick(infos.map { it.toEntry() })
        return toJson(picked.map { e -> e.copy(icon = byId[e.id]?.let { si -> runCatching { la.getShortcutIconDrawable(si, density)?.let(::dataUrl) }.getOrNull() }) })
    }

    /** Starts [app]'s shortcut [id] (into its web window on the web desktop, as other launches: AppWindows.launch). */
    fun start(
        context: Context,
        app: AndroidApp,
        id: String,
    ): Boolean {
        val la = context.getSystemService(LauncherApps::class.java) ?: return false
        if (!runCatching { la.hasShortcutHostPermission() }.getOrDefault(false)) return false
        val pkg = app.component.packageName
        AppWindows.launch(context, pkg) { opts ->
            runCatching { la.startShortcut(pkg, id, null, opts, app.user) }.onFailure { Log.w(TAG, "cannot start $pkg/$id", it) }
        }
        return true
    }

    private fun query(
        la: LauncherApps,
        app: AndroidApp,
    ): List<ShortcutInfo>? =
        runCatching {
            if (!la.hasShortcutHostPermission()) return null
            val q =
                LauncherApps.ShortcutQuery()
                    .setPackage(app.component.packageName)
                    .setQueryFlags(LauncherApps.ShortcutQuery.FLAG_MATCH_DYNAMIC or LauncherApps.ShortcutQuery.FLAG_MATCH_MANIFEST or LauncherApps.ShortcutQuery.FLAG_MATCH_PINNED)
            // Shortcuts of the app's launcher activity (or none named: the app's whole set), as Launcher3 asks.
            la.getShortcuts(q, app.user)?.filter { it.activity == null || it.activity == app.component }
        }.onFailure { Log.w(TAG, "cannot list shortcuts of ${app.component}", it) }.getOrNull()

    private fun ShortcutInfo.toEntry() =
        Entry(
            id = id,
            label = (shortLabel ?: longLabel)?.toString().orEmpty(),
            enabled = isEnabled,
            rank = rank,
            manifest = isDeclaredInManifest,
            dynamic = isDynamic,
        )

    private fun dataUrl(d: Drawable): String {
        val bmp = Bitmap.createBitmap(ICON_PX, ICON_PX, Bitmap.Config.ARGB_8888)
        d.setBounds(0, 0, ICON_PX, ICON_PX)
        d.draw(Canvas(bmp))
        val png = ByteArrayOutputStream().also { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
        bmp.recycle()
        return "data:image/png;base64," + Base64.encodeToString(png, Base64.NO_WRAP)
    }
}
