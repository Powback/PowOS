package dev.omalauncher.devices

import android.content.Context
import android.content.Intent
import android.net.Uri
import dev.omalauncher.shell.ShellActivity
import dev.omalauncher.shell.WebAppActivity
import dev.omalauncher.shell.WebApps
import org.json.JSONArray
import org.json.JSONObject

/**
 * Handoff - "Continue on <device>" (docs/DEVICES.md "Handoff"): a switcher card's page or app goes to another of the
 * account's devices as a sealed drop ([Drops], kind "send", item type "handoff"; the realm sees nothing new), and the
 * other device offers "Continue <title> from <device>" ([DropInbox]). The item's body is JSON:
 *   {v: 1, title, url?: an http(s) page, app?: a launcher key ("p:<id>" PowOS app, "l:<id>" Linux, "a:<package>"), route?}
 * A web app's card ("w:<host>") goes as its page now (WebAppActivity.here), so it opens where it was.
 */
object Handoff {
    const val TYPE = "handoff"
    const val EXTRA = "dev.omalauncher.devices.handoff"

    /** The account's other devices it can go to: [{id, name}] (test devices left out, as Send to does). */
    fun targets(c: Context): JSONArray =
        JSONArray().also { a -> Drops.devices(c)?.forEach { (id, name) -> a.put(JSONObject().put("id", id).put("name", name)) } }

    /** Sends [what] ({app?, url?, title?, route?}) to device [to]: {ok} or {ok: false, why}. */
    fun send(
        c: Context,
        to: String,
        what: JSONObject,
    ): JSONObject {
        val body = payload(what) { host -> WebAppActivity.here[host] ?: WebApps.get(c, host)?.let { it.url to it.name } }
        if (body == null) return JSONObject().put("ok", false).put("why", "Nothing here to continue elsewhere")
        val item = Drops.Item(TYPE, body.toString().toByteArray(), name = body.optString("title"), mime = "application/json")
        return when (val r = Drops.put(c, "send", to, item)) {
            is Drops.Sent.Ok -> JSONObject().put("ok", true)
            is Drops.Sent.No -> JSONObject().put("ok", false).put("why", r.why)
        }
    }

    /**
     * The handoff's body for [what] (pure: HandoffTest): a web app ("w:<host>") becomes its page now ([page]: URL,
     * title), an Android app its package alone (activity and profile are this device's); null: nothing to hand off.
     */
    fun payload(
        what: JSONObject,
        page: (String) -> Pair<String, String>?,
    ): JSONObject? {
        val (app, url, title) = resolve(what, page)
        if (url.isEmpty() && app.isEmpty()) return null
        val o = JSONObject().put("v", 1).put("title", title.ifBlank { url.ifBlank { app } }.take(200))
        if (url.isNotEmpty()) o.put("url", url)
        if (app.isNotEmpty()) o.put("app", app)
        what.optJSONObject("route")?.takeIf { app.startsWith("p:") }?.let { o.put("route", it) }
        return o
    }

    private val WEB = Regex("^https?://\\S+$")
    private val KEY = Regex("^[pla]:[\\w.@/-]+$")

    /** (app key, url, title) of [what], each "" when it isn't a valid one. */
    private fun resolve(
        what: JSONObject,
        page: (String) -> Pair<String, String>?,
    ): Triple<String, String, String> {
        val app = what.optString("app")
        val title = what.optString("title")
        if (app.startsWith("w:")) {
            val (u, t) = page(app.removePrefix("w:")) ?: return Triple("", "", title)
            return Triple("", u.takeIf { WEB.matches(it) } ?: "", title.ifBlank { t })
        }
        val key = if (app.startsWith("a:")) "a:" + app.removePrefix("a:").substringBefore('/').substringBefore('@') else app
        return Triple(key.takeIf { KEY.matches(it) } ?: "", what.optString("url").takeIf { WEB.matches(it) } ?: "", title)
    }

    /** A received handoff's body, or null when it isn't one. */
    fun parse(body: ByteArray): JSONObject? =
        runCatching { JSONObject(String(body, Charsets.UTF_8)) }.getOrNull()?.takeIf { it.optString("url").isNotBlank() || it.optString("app").isNotBlank() }

    /**
     * Where "Continue" goes: a page in a PowOS web window (a .pow site, WebAppActivity) or the browser; an Android app
     * (its store page when it isn't here); a PowOS or Linux app through home's page ("handoff.open": openApp / launch).
     */
    fun openIntent(
        c: Context,
        p: JSONObject,
    ): Intent {
        val app = p.optString("app")
        val url = p.optString("url")
        if (app.startsWith("a:")) {
            val pkg = app.removePrefix("a:")
            return c.packageManager.getLaunchIntentForPackage(pkg)?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                ?: Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=$pkg")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        if (app.startsWith("p:") || app.startsWith("l:") || url.isEmpty()) {
            return Intent(c, ShellActivity::class.java).putExtra(EXTRA, p.toString())
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        if (WebApps.idOf(url) != null) return WebAppActivity.intent(c, url)
        return Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
}
