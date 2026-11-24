package dev.omalauncher.shell

import org.json.JSONObject

/**
 * The pure half of [WebApps]' catalog sync (no Android types; WebAppSyncTest): PowStation's `GET /v1/apps` answer
 * parsed, and what the launcher's web apps become with it. Every `.pow` site is an app (the user, 11-23); one the
 * catalog no longer lists goes - but only on a catalog that was fetched and has apps in it: a failed fetch (off the
 * LAN/VPN, the hub down) or an empty list (the hub just restarted, Traefik not answering yet) changes nothing.
 */
object WebAppSync {
    /** What the launcher shows about a web app: an installable PWA (it has a manifest), a plain page, a sleeping service. */
    const val PWA = "pwa"
    const val PAGE = "page"
    const val SLEEPS = "sleeps"

    private val HOST = Regex("[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\\.pow")

    /** [host] is a `.pow` name (never `.powback.com`, never an address). */
    fun isPowHost(host: String?) = host != null && HOST.matches(host)

    /** The host of an http(s) URL, lowercased; null for anything else. */
    fun hostOf(url: String): String? {
        val m = Regex("^https?://([^/?#:]+)(:\\d+)?([/?#].*)?$", RegexOption.IGNORE_CASE).find(url.trim()) ?: return null
        return m.groupValues[1].lowercase()
    }

    /**
     * The catalog's entries as apps, only `.pow` sites whose URL is on their own host; null when [body] isn't a catalog
     * at all (an error page, a captive portal) - treated like a failed fetch.
     */
    fun parse(body: String): List<WebApps.App>? {
        val apps = runCatching { JSONObject(body).getJSONArray("apps") }.getOrNull() ?: return null
        val out = LinkedHashMap<String, WebApps.App>()
        for (i in 0 until apps.length()) apps.optJSONObject(i)?.let(::entryOf)?.let { out[it.id] = it }
        return out.values.toList()
    }

    /** One catalog entry (powos-enroll's {host,url,name,icon,theme_color,manifest,sleeps,category}); null: not a .pow site. */
    private fun entryOf(o: JSONObject): WebApps.App? {
        val host = o.optString("host").lowercase()
        val url = o.optString("url").ifEmpty { "http://$host/" }
        if (!isPowHost(host) || hostOf(url) != host) return null
        val web = if (o.optBoolean("sleeps")) SLEEPS else if (o.optBoolean("manifest")) PWA else PAGE
        val icon = o.optString("icon").takeIf { it.startsWith("http://") || it.startsWith("https://") }.orEmpty()
        val name = o.optString("name").trim().take(60).ifEmpty { host.removeSuffix(".pow") }
        return WebApps.App(host, name, url, icon, o.optString("theme_color").take(32), WebApps.Kind(web, o.optString("category").take(32)))
    }

    /** [a] and [b] list different apps or say something different about one (what's saved and shown). */
    fun differ(
        a: List<WebApps.App>,
        b: List<WebApps.App>,
    ): Boolean {
        fun key(x: WebApps.App) = listOf(x.id, x.name, x.url, x.icon, x.theme, x.web, x.category)
        return a.map(::key) != b.map(::key)
    }

    /** The web apps after a sync, and which of them need their icon (re)read. */
    class Result(
        val apps: List<WebApps.App>,
        val added: List<String>,
        val removed: List<String>,
        val iconsToFetch: List<String>,
    ) {
        val changed get() = added.isNotEmpty() || removed.isNotEmpty() || iconsToFetch.isNotEmpty()
    }

    /**
     * [current] made to follow [catalog]: new hosts added (unless the user removed them: [removedByUser]), hosts it no
     * longer lists removed, the rest updated in place (same id "w:<host>", so home/dock/quick-launch places, the icon
     * file and the site's own data stay). [catalog] null or empty: [current] unchanged. [hasIcon]: the icon file is
     * there (a missing one is read again).
     */
    fun apply(
        current: List<WebApps.App>,
        catalog: List<WebApps.App>?,
        removedByUser: Set<String>,
        hasIcon: (String) -> Boolean,
    ): Result {
        if (catalog.isNullOrEmpty()) return Result(current, emptyList(), emptyList(), emptyList())
        val byHost = catalog.associateBy { it.id }
        val removed = current.filter { it.id !in byHost }.map { it.id }
        val icons = ArrayList<String>()
        val kept =
            current.filter { it.id in byHost }.map { old ->
                val e = byHost.getValue(old.id)
                if (e.icon != old.icon || !hasIcon(old.id)) icons += old.id
                e
            }
        val have = kept.map { it.id }.toSet()
        val added = catalog.filter { it.id !in have && it.id !in removedByUser }
        icons += added.map { it.id }
        return Result(
            kept + added,
            added.map { it.id },
            removed,
            // A sleeping service with no icon of its own: nothing to read without waking it (its favicon is read once
            // it was opened, WebApps.opened).
            icons.filter { id -> byHost.getValue(id).let { it.web != SLEEPS || it.icon.isNotEmpty() } },
        )
    }
}
