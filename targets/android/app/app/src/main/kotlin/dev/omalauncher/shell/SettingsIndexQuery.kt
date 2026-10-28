package dev.omalauncher.shell

import android.content.Context
import android.database.Cursor
import android.database.CursorWrapper
import android.net.Uri
import android.os.Binder
import android.os.IBinder
import android.os.Process

/** Root's short-lived app_process worker has no registered ApplicationThread: use Android's external-provider API,
 * as the platform `content` command does. Normal privileged app installs use their own ContentResolver. */
internal object SettingsIndexQuery {
    fun query(context: Context, uri: Uri): Cursor? {
        if (Process.myUid() != 0) return context.contentResolver.query(uri, null, null, null, null)
        val am = Class.forName("android.app.ActivityManager").getMethod("getService").invoke(null)
        val api = Class.forName("android.app.IActivityManager")
        val token = Binder()
        val holder = api.getMethod("getContentProviderExternal", String::class.java, Int::class.javaPrimitiveType, IBinder::class.java, String::class.java)
            .invoke(am, uri.authority, 0, token, "powos-settings-index") ?: return null
        val provider = holder.javaClass.getField("provider").get(holder)
        val release = { api.getMethod("removeContentProviderExternalAsUser", String::class.java, IBinder::class.java, Int::class.javaPrimitiveType)
            .invoke(am, uri.authority, token, 0); Unit }
        try {
            val cursor = read(provider, uri)
            if (cursor == null) { release(); return null }
            return object : CursorWrapper(cursor) {
                override fun close() { try { super.close() } finally { release() } }
            }
        } catch (e: Exception) { release(); throw e }
    }

    private fun read(provider: Any, uri: Uri): Cursor? {
        val query = Class.forName("android.content.IContentProvider").methods.first { it.name == "query" }
        val args = query.parameterTypes.map { type -> when (type.name) {
            "android.content.AttributionSource" -> attribution()
            "android.net.Uri" -> uri
            "java.lang.String" -> "root"
            else -> null
        } }.toTypedArray()
        return query.invoke(provider, *args) as? Cursor
    }

    private fun attribution(): Any {
        val type = Class.forName("android.content.AttributionSource\$Builder")
        val builder = type.getConstructor(Int::class.javaPrimitiveType).newInstance(0)
        type.getMethod("setPackageName", String::class.java).invoke(builder, "root")
        return type.getMethod("build").invoke(builder)
    }
}
