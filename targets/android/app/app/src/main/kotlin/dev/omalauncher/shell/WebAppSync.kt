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

    // --- Reachability: whether the launcher greys the .pow apps out as "not reachable right now".
    // The user, 11-27: "Pow apps all greyed out as offline while the network works". It used to be one catalog GET's
    // outcome: any failure (a try during a network change before Wi-Fi/VPN/DNS settled, the catalog service down
    // behind a working Traefik, a slow answer) greyed every app until the next network change or the 15-minute
    // periodic sync, and a network change during an in-flight try was folded into it and lost. Now: only "nothing on
    // the .pow network answered", twice in a row, greys them, and the next answer clears it at once.

    /** What one try at the hub's catalog said about the `.pow` network. */
    enum class Probe {
        /** The catalog came back. */
        CATALOG,

        /** The hub answered but with no catalog (its catalog service down/restarting behind Traefik): the network works. */
        ANSWERED,

        /** Nothing on the .pow network answered: no DNS, no connection, a timeout, the LAN-only gate (403), a portal. */
        NO_ANSWER,
    }

    /**
     * One try's [code] (the HTTP status; null: no HTTP answer at all) and [location] (a redirect's target) as a [Probe];
     * [catalog]: the 200's body parsed. 403 is PowStation's `.pow` LAN/VPN-only gate (pow-local-only.yml): the request
     * came from outside, so the sites answer 403 too - not reachable. A redirect counts only to a `.pow` host (an
     * http -> https upgrade on the hub); anywhere else is a captive portal.
     */
    fun probeOf(
        code: Int?,
        catalog: List<WebApps.App>?,
        location: String? = null,
    ): Probe =
        when {
            code == null -> Probe.NO_ANSWER
            code == 200 && catalog != null -> Probe.CATALOG
            code == 403 -> Probe.NO_ANSWER
            code in 300..399 -> if (isPowHost(location?.let(::hostOf))) Probe.ANSWERED else Probe.NO_ANSWER
            // 200 that isn't a catalog: a portal's page served in place.
            code == 200 -> Probe.NO_ANSWER
            else -> Probe.ANSWERED
        }

    /** Tries in a row with no answer before the apps are greyed: one failed try (a network still settling) never does. */
    const val OFFLINE_AFTER = 2

    /** The reachability after one more try: [misses] tries in a row with no answer, and whether that greys the apps. */
    data class Reach(val misses: Int = 0) {
        val offline get() = misses >= OFFLINE_AFTER

        fun after(p: Probe) = Reach(if (p == Probe.NO_ANSWER) misses + 1 else 0)

        /**
         * Seconds to the next try: soon after a miss (3 s: confirm or clear it before anything is greyed), then 30 s,
         * doubling to 5 min while it stays unreachable (off the LAN/VPN for hours costs a GET every 5 min, not every
         * 30 s); null after an answer (the periodic sync and network changes are enough).
         */
        fun retryInSec(): Long? =
            when {
                misses == 0 -> null
                misses < OFFLINE_AFTER -> 3L
                else -> minOf(300L, 30L shl minOf(4, misses - OFFLINE_AFTER))
            }
    }
}
