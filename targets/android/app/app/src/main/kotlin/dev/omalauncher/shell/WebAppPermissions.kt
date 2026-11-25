package dev.omalauncher.shell

import android.content.Context
import android.util.Log
import java.io.File

/**
 * What the user allowed each `.pow` web app (WebPermissions: the rules), kept in files/webapp-permissions.json as
 * {"<host>": ["microphone", ...]}. Granted in WebAppActivity's dialog, shown and revoked in the app's menu on the
 * launcher (bridge "webapps.permissions" / "webapps.revoke"). Removing the app from the launcher forgets them.
 */
object WebAppPermissions {
    private const val TAG = "PowosWebPerms"

    private fun file(context: Context) = File(context.filesDir, "webapp-permissions.json")

    // Read each time (a few hundred bytes): the bridge and the web app's window may live in different processes.
    private fun all(context: Context): MutableMap<String, Set<String>> =
        WebPermissions.parse(runCatching { file(context).takeIf { it.isFile }?.readText() }.getOrNull()).toMutableMap()

    /** The kinds [site] (an app id, the host) is allowed. */
    fun of(
        context: Context,
        site: String,
    ): Set<String> = synchronized(this) { all(context)[site].orEmpty() }

    fun allow(
        context: Context,
        site: String,
        kinds: Collection<String>,
    ) = change(context, site) { it + kinds.filter { k -> k in WebPermissions.KINDS } }

    /** Takes [kind] back from [site] (null: everything). True when something was allowed. */
    fun revoke(
        context: Context,
        site: String,
        kind: String?,
    ): Boolean {
        var had = false
        change(context, site) {
            had = if (kind == null) it.isNotEmpty() else kind in it
            if (kind == null) emptySet() else it - kind
        }
        if (had) Log.i(TAG, "$site: revoked ${kind ?: "everything"}")
        return had
    }

    private fun change(
        context: Context,
        site: String,
        f: (Set<String>) -> Set<String>,
    ) {
        if (!WebAppSync.isPowHost(site)) return
        synchronized(this) {
            val m = all(context)
            val next = f(m[site].orEmpty())
            if (next == m[site].orEmpty()) return
            if (next.isEmpty()) m.remove(site) else m[site] = next
            val tmp = File(context.filesDir, "webapp-permissions.json.tmp")
            tmp.writeText(WebPermissions.format(m))
            tmp.renameTo(file(context))
        }
    }
}
