package dev.omalauncher.shell

import org.json.JSONArray
import org.json.JSONObject

/**
 * The pure half of a `.pow` web app's permissions (no Android types; WebPermissionsTest). The user, 11-25: "the apps
 * added automatically dont have microphone permissions etc". A site in a web window (WebAppActivity) asks the WebView
 * for the mic, the camera, location or MIDI; this maps each ask to a kind the user grants per site, and each kind to
 * the Android runtime permission PowOS itself must hold for it (WebAppPermissions: the files/webapp-permissions.json
 * store and the asking).
 *
 * Rules: only a `.pow` site of the app's own host (or a host under it) is ever granted - the key is the app id (the
 * host, launcher key "w:<host>"); anything else is refused without asking. A kind the user hasn't allowed for the
 * site is asked in PowOS's own dialog first; Android's permission dialog follows only for what PowOS doesn't hold yet.
 */
object WebPermissions {
    /** What the user grants a site (also the words the app menu shows). */
    const val MIC = "microphone"
    const val CAMERA = "camera"
    const val LOCATION = "location"
    const val MIDI = "midi"

    /** android.webkit.PermissionRequest's RESOURCE_* values. */
    const val RES_AUDIO = "android.webkit.resource.AUDIO_CAPTURE"
    const val RES_VIDEO = "android.webkit.resource.VIDEO_CAPTURE"
    const val RES_MIDI = "android.webkit.resource.MIDI_SYSEX"
    const val RES_PROTECTED_MEDIA = "android.webkit.resource.PROTECTED_MEDIA_ID"

    private const val RECORD_AUDIO = "android.permission.RECORD_AUDIO"
    private const val CAMERA_PERMISSION = "android.permission.CAMERA"
    private const val FINE = "android.permission.ACCESS_FINE_LOCATION"
    private const val COARSE = "android.permission.ACCESS_COARSE_LOCATION"

    /** The order kinds are shown in. */
    val KINDS = listOf(MIC, CAMERA, LOCATION, MIDI)

    /** A WebView resource's kind; null: never granted (DRM ids, anything new). */
    fun kindOf(resource: String): String? =
        when (resource) {
            RES_AUDIO -> MIC
            RES_VIDEO -> CAMERA
            RES_MIDI -> MIDI
            else -> null
        }

    /** The WebView resource for [kind] (location has none: it is the WebView's geolocation prompt). */
    fun resourceOf(kind: String): String? =
        when (kind) {
            MIC -> RES_AUDIO
            CAMERA -> RES_VIDEO
            MIDI -> RES_MIDI
            else -> null
        }

    /** The Android permissions PowOS must hold for [kind]; any one of them is enough (location: fine or coarse). */
    fun androidPermissions(kind: String): List<String> =
        when (kind) {
            MIC -> listOf(RECORD_AUDIO)
            CAMERA -> listOf(CAMERA_PERMISSION)
            LOCATION -> listOf(FINE, COARSE)
            else -> emptyList()
        }

    /** PowOS holds what [kind] needs ([held]: Android says the permission is granted). */
    fun holds(
        kind: String,
        held: (String) -> Boolean,
    ): Boolean = androidPermissions(kind).let { it.isEmpty() || it.any(held) }

    /**
     * The site [origin] (the asking frame's origin, "http://host[:port]/") grants under in the web app [appId]: [appId]
     * when the origin is a `.pow` host equal to it or under it, else null (an embedded other site, a non-.pow app).
     */
    fun siteOf(
        origin: String?,
        appId: String,
    ): String? {
        val host = origin?.let(WebAppSync::hostOf) ?: return null
        if (!WebAppSync.isPowHost(host) || !WebAppSync.isPowHost(appId)) return null
        return appId.takeIf { host == it || host.endsWith(".$it") }
    }

    /**
     * What to do with [asked] kinds for a site that has [allowed]: [ask] the user (PowOS's dialog) for these first,
     * then [request] these Android permissions; [ready] can be granted right away.
     */
    class Plan(val ask: List<String>, val request: List<String>, val ready: List<String>)

    fun plan(
        asked: List<String>,
        allowed: Set<String>,
        held: (String) -> Boolean,
    ): Plan {
        val kinds = KINDS.filter { it in asked }
        val ask = kinds.filter { it !in allowed }
        val mine = kinds.filter { it in allowed }
        val ready = mine.filter { holds(it, held) }
        val request = mine.filter { !holds(it, held) }.flatMap(::androidPermissions).distinct()
        return Plan(ask, request, ready)
    }

    /** After Android's dialog: the [allowed] kinds of [asked] PowOS holds now. */
    fun granted(
        asked: List<String>,
        allowed: Set<String>,
        held: (String) -> Boolean,
    ): List<String> = KINDS.filter { it in asked && it in allowed && holds(it, held) }

    /** The store's JSON ({"<host>": ["microphone", ...]}) read; junk entries (non-.pow, unknown kinds) dropped. */
    fun parse(text: String?): Map<String, Set<String>> {
        val o = runCatching { JSONObject(text ?: "{}") }.getOrNull() ?: return emptyMap()
        val out = LinkedHashMap<String, Set<String>>()
        for (site in o.keys()) {
            if (!WebAppSync.isPowHost(site)) continue
            val a = o.optJSONArray(site) ?: continue
            val kinds = (0 until a.length()).map { a.optString(it) }.filter { it in KINDS }.toSet()
            if (kinds.isNotEmpty()) out[site] = kinds
        }
        return out
    }

    fun format(grants: Map<String, Set<String>>): String {
        val o = JSONObject()
        for ((site, kinds) in grants.toSortedMap()) if (kinds.isNotEmpty()) o.put(site, JSONArray(KINDS.filter { it in kinds }))
        return o.toString()
    }

    /** "microphone", "microphone and camera", "microphone, camera and location". */
    fun words(kinds: List<String>): String =
        when (kinds.size) {
            0 -> ""
            1 -> kinds[0]
            else -> kinds.dropLast(1).joinToString(", ") + " and " + kinds.last()
        }
}
