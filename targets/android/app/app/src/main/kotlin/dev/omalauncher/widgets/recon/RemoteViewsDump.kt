package dev.omalauncher.widgets.recon

import android.app.PendingIntent
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.res.ColorStateList
import android.content.res.Resources
import android.graphics.Bitmap
import android.graphics.drawable.Icon
import android.os.Build
import android.util.SizeF
import android.widget.RemoteViews
import org.json.JSONArray
import org.json.JSONObject
import java.lang.reflect.Modifier

/**
 * What a provider's RemoteViews say, read by reflection: the layout and the list of actions Android applies to it
 * (`setText` on R.id.title, `setImageViewBitmap`, `setOnClickResponse`...), with their values. RemoteViews keeps
 * these in hidden fields (`mActions` and each action's own); our targetSdk 28 lets us read the ones Android lists as
 * unsupported-but-reachable, and reflection simply doesn't see the blocked ones, so a field missing here is
 * Android's restriction rather than an empty value ([hidden] lists the action classes that showed no fields at all).
 *
 * Pending intents are only described (creator package, kind): reading the Intent inside needs a system permission,
 * and they're never sent.
 */
internal class RemoteViewsDump(
    /** The provider app's resources, which name its ids, layouts, colors. */
    private val res: Resources,
    private val images: Images,
) {
    /** Per view id name, short descriptions of the top-level actions on it, for the view tree ([ViewTreeDump]). */
    val byView = HashMap<String, MutableList<String>>()

    /** Action classes whose fields reflection couldn't see. */
    val hidden = sortedSetOf<String>()

    private var bitmapCache: List<*>? = null

    fun dump(rv: RemoteViews): JSONObject = remoteViews(rv, 0, top = true)

    private fun remoteViews(
        rv: RemoteViews,
        depth: Int,
        top: Boolean = false,
    ): JSONObject {
        val o = JSONObject()
        o.put("package", rv.`package`)
        o.put("layout", resName(rv.layoutId))
        val outerCache = bitmapCache
        bitmapCache = field(rv, "mBitmapCache")?.let { field(it, "mBitmaps") as? List<*> } ?: outerCache
        try {
            for (name in listOf("mLandscape", "mPortrait")) {
                (field(rv, name) as? RemoteViews)?.let { o.put(name.removePrefix("m").lowercase(), remoteViews(it, depth + 1)) }
            }
            (field(rv, "mSizedRemoteViews") as? List<*>)?.let { sized ->
                o.put(
                    "sized",
                    JSONArray(
                        sized.filterIsInstance<RemoteViews>().map { s ->
                            remoteViews(s, depth + 1).also { j -> (field(s, "mIdealSize") as? SizeF)?.let { j.put("idealSizeDp", "${it.width}x${it.height}") } }
                        },
                    ),
                )
            }
            // A RemoteViews without actions has none (null) rather than an empty list.
            val actions = field(rv, "mActions") as? List<*> ?: if (visible(rv, "mActions")) emptyList<Any>() else null
            if (actions == null) {
                o.put("actions", JSONObject.NULL)
                o.put("actionsHidden", true)
            } else {
                o.put(
                    "actions",
                    JSONArray(
                        actions.filterNotNull().map { a ->
                            action(a, depth).also { if (top) note(it) }
                        },
                    ),
                )
            }
        } finally {
            bitmapCache = outerCache
        }
        return o
    }

    private fun action(
        a: Any,
        depth: Int,
    ): JSONObject {
        val o = obj(a, depth + 1)
        o.put("action", a.javaClass.name.substringAfterLast('$').substringAfterLast('.'))
        if (o.length() == 1) hidden += o.getString("action")
        // BitmapReflectionAction refers to the RemoteViews' bitmap cache by index.
        if (o.has("bitmapId") && !o.has("bitmap")) {
            (bitmapCache?.getOrNull(o.optInt("bitmapId", -1)) as? Bitmap)?.let { o.put("bitmap", images.bitmap(it)) }
        }
        return o
    }

    /** Fields of an object of one of RemoteViews' own classes (actions, responses, collection items). */
    private fun obj(
        x: Any,
        depth: Int,
    ): JSONObject {
        val o = JSONObject()
        var c: Class<*>? = x.javaClass
        while (c != null && c != Any::class.java) {
            for (f in c.declaredFields) {
                if (Modifier.isStatic(f.modifiers) || f.isSynthetic || f.name in SKIP) continue
                val v = runCatching { f.isAccessible = true; f.get(x) }.getOrNull() ?: continue
                val key = f.name.removePrefix("m").replaceFirstChar { it.lowercase() }
                if (o.has(key)) continue
                o.put(key, value(v, depth + 1, key))
            }
            c = c.superclass
        }
        // ReflectionAction & co: a method and its argument. Name what the number means.
        val method = o.optString("methodName")
        val v = o.opt("value")
        if (v is Int && method.contains("color", ignoreCase = true)) o.put("valueHex", hex(v))
        if (v is Int && (method.endsWith("Resource") || method.contains("Res"))) resName(v)?.let { o.put("valueRes", it) }
        return o
    }

    private fun value(
        v: Any?,
        depth: Int,
        key: String = "",
    ): Any? {
        if (v == null) return JSONObject.NULL
        if (depth > MAX_DEPTH) return v.javaClass.simpleName
        return when (v) {
            is Boolean, is String, is Long -> v
            is Int -> if (key.endsWith("Id", ignoreCase = true) && key != "bitmapId" && key != "intentId") (idName(v) ?: v) else v
            is Float -> if (v.isFinite()) v.toDouble() else v.toString()
            is Double -> if (v.isFinite()) v else v.toString()
            is Number, is Char, is Enum<*> -> v.toString()
            is CharSequence -> v.toString()
            is Bitmap -> images.bitmap(v)
            is Icon -> JSONObject().put("icon", images.icon(v) ?: JSONObject.NULL).put("type", v.type)
            is PendingIntent -> pending(v)
            is Intent -> JSONObject().put("intent", v.toUri(Intent.URI_INTENT_SCHEME))
            is RemoteViews -> remoteViews(v, depth)
            is ColorStateList -> hex(v.defaultColor)
            is SizeF -> "${v.width}x${v.height}"
            is ApplicationInfo -> v.packageName
            is IntArray -> JSONArray(v.map { idName(it) ?: it })
            is LongArray -> JSONArray(v.toList())
            is FloatArray -> JSONArray(v.map { it.toDouble() })
            is Array<*> -> JSONArray(v.take(MAX_ITEMS).map { value(it, depth + 1) })
            is Collection<*> -> JSONArray(v.take(MAX_ITEMS).map { value(it, depth + 1) })
            is Map<*, *> -> JSONObject().also { m -> v.entries.take(MAX_ITEMS).forEach { (k, e) -> m.put(k.toString(), value(e, depth + 1)) } }
            else ->
                if (v.javaClass.name.startsWith("android.widget.RemoteViews")) {
                    obj(v, depth)
                } else {
                    v.javaClass.name
                }
        }
    }

    /** Where a tap would go, without the Intent (reading it needs GET_INTENT_SENDER_INTENT, a system permission). */
    private fun pending(p: PendingIntent): JSONObject {
        val o = JSONObject().put("pendingIntent", p.creatorPackage)
        if (Build.VERSION.SDK_INT >= 31) {
            o.put(
                "kind",
                when {
                    p.isActivity -> "activity"
                    p.isForegroundService -> "foregroundService"
                    p.isService -> "service"
                    p.isBroadcast -> "broadcast"
                    else -> "unknown"
                },
            )
        }
        return o
    }

    /** One line per action for the view it targets: `setText "12°"`, `setOnClickResponse -> activity in com.x`. */
    private fun note(a: JSONObject) {
        val view = a.opt("viewId") as? String ?: return
        val op = a.optString("methodName").ifEmpty { a.getString("action") }
        val v = a.opt("value")
        val what =
            when {
                v is String && v.isNotEmpty() -> " \"${v.take(60)}\""
                a.has("valueHex") -> " ${a.getString("valueHex")}"
                a.has("valueRes") -> " ${a.getString("valueRes")}"
                v is Number || v is Boolean -> " $v"
                else -> ""
            } + (findPending(a)?.let { " -> ${it.optString("kind", "pending intent")} in ${it.optString("pendingIntent")}" } ?: "")
        byView.getOrPut(view) { mutableListOf() } += op + what
    }

    private fun findPending(j: Any?): JSONObject? =
        when (j) {
            is JSONObject -> if (j.has("pendingIntent")) j else j.keys().asSequence().firstNotNullOfOrNull { findPending(j.opt(it)) }
            is JSONArray -> (0 until j.length()).firstNotNullOfOrNull { findPending(j.opt(it)) }
            else -> null
        }

    /** A view id as its entry name (`title`), as the view tree shows it. */
    private fun idName(id: Int): String? = if (id == 0 || id == -1) null else runCatching { res.getResourceEntryName(id) }.getOrNull()

    /** A resource as `package:type/name`. */
    private fun resName(id: Int): String? = if (id == 0 || id == -1) null else runCatching { res.getResourceName(id) }.getOrNull()

    private fun field(
        x: Any,
        name: String,
    ): Any? {
        var c: Class<*>? = x.javaClass
        while (c != null) {
            runCatching { return c.getDeclaredField(name).apply { isAccessible = true }.get(x) }
            c = c.superclass
        }
        return null
    }

    /** Whether reflection sees field [name] at all (Android hides blocked ones). */
    private fun visible(
        x: Any,
        name: String,
    ): Boolean {
        var c: Class<*>? = x.javaClass
        while (c != null) {
            if (runCatching { c.getDeclaredField(name) }.isSuccess) return true
            c = c.superclass
        }
        return false
    }

    private companion object {
        const val MAX_DEPTH = 10
        const val MAX_ITEMS = 200

        /** Plumbing, not content (and the bitmap cache, read separately). */
        val SKIP = setOf("mBitmapCache", "mApplication", "mClassCookie", "mApplyFlags", "this\$0", "mActions", "shadow\$_klass_", "shadow\$_monitor_")
    }
}

internal fun hex(c: Int) = "#%08X".format(c)
