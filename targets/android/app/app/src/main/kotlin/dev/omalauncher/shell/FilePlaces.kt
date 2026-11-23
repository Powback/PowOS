package dev.omalauncher.shell

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.provider.DocumentsContract
import dev.omalauncher.Runtime
import org.json.JSONArray
import org.json.JSONObject

/**
 * The launcher's "quick launch" places (shell/ui/drawer.tsx QuickLaunch; the user, 11-23: "other quick launch options
 * like idk file locations"): the phone's own folders opened in the system Files app (DocumentsUI, through the
 * external storage provider - no storage permission, root or not), and the Linux home folder in PowOS's Files app
 * (FilesActivity) when Linux is set up. [list] offers only places that open here, so every tile the page draws works.
 */
class FilePlaces(
    private val context: Context,
    private val runtime: Runtime,
) {
    private class Place(val id: String, val label: String, val doc: String?)

    private val places =
        listOf(
            Place("downloads", "Downloads", "primary:Download"),
            Place("documents", "Documents", "primary:Documents"),
            Place("camera", "Camera", "primary:DCIM/Camera"),
            Place("pictures", "Pictures", "primary:Pictures"),
            Place("music", "Music", "primary:Music"),
            Place("linux", "Linux home", null),
        )

    /** The folder's view intent in the system Files app. */
    private fun view(doc: String) =
        Intent(Intent.ACTION_VIEW)
            .setDataAndType(DocumentsContract.buildDocumentUri(STORAGE, doc), DocumentsContract.Document.MIME_TYPE_DIR)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)

    private fun opens(p: Place) =
        if (p.doc == null) runtime.bootstrap.wanted else view(p.doc).resolveActivity(context.packageManager) != null

    /** [{id, label}] of the places that open on this phone, in the order shown. */
    fun list(): JSONArray =
        JSONArray(places.filter(::opens).map { JSONObject().put("id", it.id).put("label", it.label) })

    /** Opens place [id]; false when it can't (unknown, or no app takes it). */
    fun open(id: String): Boolean {
        val p = places.firstOrNull { it.id == id } ?: return false
        if (p.doc == null) {
            if (!runtime.bootstrap.wanted) return false
            runtime.openFiles(LINUX_HOME)
            return true
        }
        return try {
            context.startActivity(view(p.doc))
            true
        } catch (_: ActivityNotFoundException) {
            false
        }
    }

    private companion object {
        const val STORAGE = "com.android.externalstorage.documents"
        const val LINUX_HOME = "/root"
    }
}
