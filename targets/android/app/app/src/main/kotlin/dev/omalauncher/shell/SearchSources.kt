package dev.omalauncher.shell

import android.Manifest
import android.app.Activity
import android.app.SearchManager
import android.content.ActivityNotFoundException
import android.content.ContentResolver
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.ContactsContract
import android.provider.MediaStore
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Executors

/**
 * The launcher search's personal sources (shell/searchsources.ts): the phone's contacts and its files, and the web.
 *
 * Read-only lookups, run off the main thread (ShellBridge LOOKUPS). The page only ever gets back ids and names: opening
 * a result hands back an id, and the content URI / phone number is rebuilt here, so the page can't make PowOS open an
 * arbitrary URI. Contacts need READ_CONTACTS, files READ_MEDIA_* (Android 13+; READ_EXTERNAL_STORAGE before): asked the
 * PowOS way - explicitly, once (the search's "Allow" row, [ask]); rooted, granted with pm grant instead. A "no" is kept:
 * never asked again, those sources stay empty.
 */
object SearchSources {
    const val REQUEST = 46
    private const val PREFS = "search-permission"
    private const val ASKED = "asked-contacts-files"
    private const val LIMIT = 8
    private const val TAG = "PowosSearch"

    private val MEDIA: Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO, Manifest.permission.READ_MEDIA_AUDIO)
        } else {
            arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        }
    internal val ALL = arrayOf(Manifest.permission.READ_CONTACTS) + MEDIA

    private fun granted(context: Context, p: String) = context.checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

    /** {contacts, files: granted; ask: the "Allow" row is still wanted (not all granted, never asked)}. */
    fun state(context: Context): JSONObject {
        val contacts = granted(context, Manifest.permission.READ_CONTACTS)
        val files = MEDIA.any { granted(context, it) }
        val asked = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(ASKED, false)
        return JSONObject().put("contacts", contacts).put("files", files).put("ask", !asked && !(contacts && files))
    }

    /**
     * Asks once for what isn't granted: "granted" (rooted: pm grant), "asked" (the dialog is up; "search.permission"
     * follows), "done" (asked before, or nothing missing).
     */
    fun ask(context: Context, activity: Activity?): String {
        val missing = ALL.filterNot { granted(context, it) }
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (missing.isEmpty() || prefs.getBoolean(ASKED, false)) return "done"
        prefs.edit().putBoolean(ASKED, true).apply()
        if (andro.marchy.RootMode.enabled()) return rootGrant(context.packageName, missing)
        // The launcher overlay has no activity of its own: a transparent one asks (as HealthGrantActivity does).
        if (activity != null) {
            activity.requestPermissions(missing.toTypedArray(), REQUEST)
        } else {
            context.startActivity(Intent(context, SearchGrantActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
        return "asked"
    }

    /** Rooted: granted with pm grant (no dialog), then the open searches run again. */
    private fun rootGrant(
        pkg: String,
        missing: List<String>,
    ): String {
        Executors.newSingleThreadExecutor().execute {
            for (p in missing) {
                val r = andro.marchy.RootShell.run("pm grant $pkg $p")
                Log.i(TAG, "pm grant $p: ${if (r.code == 0) "ok" else r.output}")
            }
            answered()
        }
        return "granted"
    }

    /** The answer came ([Activity.onRequestPermissionsResult]): every open search runs again with what it may read now. */
    fun answered() = ShellBridge.broadcastAll("search.permission", "null")

    /** Contacts whose name (or nickname, email, number) matches [text]: [{id, name, number?}]; id = "<contactId>/<lookupKey>". */
    fun contacts(context: Context, text: String): JSONArray {
        val out = JSONArray()
        if (text.isBlank() || !granted(context, Manifest.permission.READ_CONTACTS)) return out
        val uri = ContactsContract.Contacts.CONTENT_FILTER_URI.buildUpon().appendPath(text.trim())
            .appendQueryParameter(ContactsContract.LIMIT_PARAM_KEY, LIMIT.toString()).build()
        val cols = arrayOf(ContactsContract.Contacts._ID, ContactsContract.Contacts.LOOKUP_KEY, ContactsContract.Contacts.DISPLAY_NAME_PRIMARY, ContactsContract.Contacts.HAS_PHONE_NUMBER)
        runCatching {
            context.contentResolver.query(uri, cols, null, null, null)?.use { c ->
                while (c.moveToNext() && out.length() < LIMIT) {
                    val id = c.getLong(0)
                    val name = c.getString(2) ?: continue
                    val row = JSONObject().put("id", "$id/${c.getString(1)}").put("name", name)
                    if (c.getInt(3) > 0) number(context, id)?.let { row.put("number", it) }
                    out.put(row)
                }
            }
        }.onFailure { Log.w(TAG, "contacts query failed", it) }
        return out
    }

    /** Contact [id]'s main number (its default one, else the first). */
    private fun number(context: Context, id: Long): String? =
        context.contentResolver.query(
            ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
            arrayOf(ContactsContract.CommonDataKinds.Phone.NUMBER),
            "${ContactsContract.CommonDataKinds.Phone.CONTACT_ID} = ?",
            arrayOf(id.toString()),
            "${ContactsContract.CommonDataKinds.Phone.IS_SUPER_PRIMARY} DESC, ${ContactsContract.CommonDataKinds.Phone.IS_PRIMARY} DESC",
        )?.use { c -> if (c.moveToFirst()) c.getString(0) else null }

    /**
     * Files by name, newest first: [{id, name, mime, folder, modified (ms), size}]. "recent" / "recent files": the newest
     * ones, whatever their name. id = "<mediaStoreId>".
     */
    fun files(context: Context, text: String): JSONArray {
        val out = JSONArray()
        val q = text.trim().lowercase()
        if (q.isEmpty() || MEDIA.none { granted(context, it) }) return out
        val query = fileQuery(q)
        val cols = arrayOf(MediaStore.MediaColumns._ID, MediaStore.MediaColumns.DISPLAY_NAME, MediaStore.MediaColumns.MIME_TYPE, MediaStore.MediaColumns.RELATIVE_PATH, MediaStore.MediaColumns.DATE_MODIFIED, MediaStore.MediaColumns.SIZE)
        runCatching {
            context.contentResolver.query(MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL), cols, query, null)?.use { c ->
                while (c.moveToNext() && out.length() < LIMIT) fileRow(c)?.let { out.put(it) }
            }
        }.onFailure { Log.w(TAG, "files query failed", it) }
        return out
    }

    /** The MediaStore query: every word in the name (LIKE, escaped), files only, newest first; "recent": any name. */
    private fun fileQuery(q: String): Bundle {
        val words = if (q == "recent" || q == "recent files") emptyList() else q.split(Regex("\\s+")).filter { it.isNotEmpty() }
        val selection = (listOf("${MediaStore.MediaColumns.MIME_TYPE} IS NOT NULL") +
            words.map { "${MediaStore.MediaColumns.DISPLAY_NAME} LIKE ? ESCAPE '\\'" }).joinToString(" AND ")
        val args = words.map { "%" + it.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%" }.toTypedArray()
        return Bundle().apply {
            putString(ContentResolver.QUERY_ARG_SQL_SELECTION, selection)
            putStringArray(ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, args)
            putString(ContentResolver.QUERY_ARG_SQL_SORT_ORDER, "${MediaStore.MediaColumns.DATE_MODIFIED} DESC")
            putInt(ContentResolver.QUERY_ARG_LIMIT, LIMIT)
        }
    }

    /** One row of [files]' cursor (id, name, mime, relative path, modified s, size); null: no name. */
    private fun fileRow(c: android.database.Cursor): JSONObject? {
        val name = c.getString(1) ?: return null
        return JSONObject().put("id", c.getLong(0).toString()).put("name", name).put("mime", c.getString(2))
            .put("folder", (c.getString(3) ?: "").trimEnd('/')).put("modified", c.getLong(4) * 1000).put("size", c.getLong(5))
    }

    /** Opens result [id] of [kind]: "contact" its card, "call" the dialer with its number, "file" in its viewer. False: it can't. */
    fun open(context: Context, kind: String, id: String): Boolean {
        val intent = when (kind) {
            "contact" -> contactUri(id)?.let { Intent(Intent.ACTION_VIEW, it) }
            "call" -> id.substringBefore('/').toLongOrNull()?.let { number(context, it) }?.let { Intent(Intent.ACTION_DIAL, Uri.fromParts("tel", it, null)) }
            "file" -> fileView(context, id)
            else -> null
        } ?: return false
        return start(context, intent)
    }

    private fun contactUri(id: String): Uri? {
        val contact = id.substringBefore('/').toLongOrNull() ?: return null
        return ContactsContract.Contacts.getLookupUri(contact, id.substringAfter('/', ""))
    }

    private fun fileView(context: Context, id: String): Intent? {
        val n = id.toLongOrNull() ?: return null
        val any = ContentUris.withAppendedId(MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL), n)
        val mime = runCatching { context.contentResolver.query(any, arrayOf(MediaStore.MediaColumns.MIME_TYPE), null, null, null)?.use { if (it.moveToFirst()) it.getString(0) else null } }.getOrNull() ?: return null
        val uri = mediaCollection(mime)?.let { ContentUris.withAppendedId(it, n) } ?: any
        return Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }

    /** The media's own collection where it is one: viewers take those URIs more readily than the generic files one. */
    private fun mediaCollection(mime: String): Uri? =
        when {
            mime.startsWith("image/") -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            mime.startsWith("video/") -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            mime.startsWith("audio/") -> MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
            else -> null
        }

    /** "Search the web for [text]": the phone's web search (its search app), else the default browser's search page. */
    fun web(context: Context, text: String): Boolean {
        val q = text.trim().take(500)
        if (q.isEmpty()) return false
        return start(context, Intent(Intent.ACTION_WEB_SEARCH).putExtra(SearchManager.QUERY, q)) ||
            start(context, Intent(Intent.ACTION_VIEW, Uri.parse("https://www.google.com/search?q=" + Uri.encode(q))))
    }

    private fun start(context: Context, intent: Intent): Boolean =
        try {
            context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (_: ActivityNotFoundException) {
            false
        } catch (e: SecurityException) {
            Log.w(TAG, "can't open ${intent.action}", e)
            false
        }
}

/** The search's permission dialog from a window with no activity (the launcher overlay): transparent, gone once answered. */
class SearchGrantActivity : Activity() {
    override fun onCreate(saved: Bundle?) {
        super.onCreate(saved)
        if (saved != null) return
        val missing = SearchSources.ALL.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isEmpty()) return finish()
        requestPermissions(missing.toTypedArray(), SearchSources.REQUEST)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        SearchSources.answered()
        finish()
    }
}
