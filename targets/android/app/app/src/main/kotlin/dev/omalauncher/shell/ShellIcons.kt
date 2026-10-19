package dev.omalauncher.shell

import android.content.Context
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import dev.omalauncher.Runtime
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.WeakHashMap
import java.util.concurrent.Executors

/**
 * App icons for the page, as files named by what they show: /_icon/<hash>, where the hash is of the icon's pixels as
 * the drawer draws them (themed, badged, at this screen's density). A name never shows anything else, so the page may
 * keep it forever (ShellHost serves them immutable), and an icon's URL changes only when that icon does: an install,
 * an update, a theme change - never because some other icon arrived.
 *
 * The files and which app has which ([INDEX]) outlive the process, in noBackupFilesDir (an update keeps it): after an
 * update or a restart the page's list names each app's last icon at once, served from its file while the catalog is
 * still drawing them from PackageManager. When a drawn icon comes out different, its app gets the new name and
 * [version] moves, which sends the page the list again (ShellBridge's apps.changed).
 *
 * Main thread for [url] and [version]; hashing and writing files on one worker.
 */
internal object ShellIcons {
    private const val TAG = "ShellIcons"
    private const val INDEX = "index.json"
    private val HASH = Regex("[0-9a-f]{32}")

    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor { Thread(it, "shell-icons").apply { priority = Thread.NORM_PRIORITY - 1 } }

    private var dir: File? = null

    /** Each app's icon's hash as last drawn ("a:<key>" / "l:<id>"), this run's or a past one's. */
    private val names = HashMap<String, String>()

    /** The hash of each bitmap hashed already (the maps hold one bitmap per icon until it changes). */
    private val hashed = WeakHashMap<ImageBitmap, String>()
    private val pending = WeakHashMap<ImageBitmap, Boolean>()

    /** Moves when an app's icon has a new name: the page's list is out of date. */
    val version = mutableIntStateOf(0)

    private var saveQueued = false

    /** Once per process (each ShellHost asks): the index read, and every icon the catalogs draw named as it arrives. */
    fun init(
        context: Context,
        runtime: Runtime,
    ) {
        if (dir != null) return
        val d = File(context.noBackupFilesDir, "shell-icons").also { it.mkdirs() }
        dir = d
        runCatching {
            val json = JSONObject(File(d, INDEX).readText())
            for (k in json.keys()) json.getString(k).takeIf { HASH.matches(it) && File(d, "$it.png").isFile }?.let { names[k] = it }
        }
        // Files no app names any more (a theme left, an app gone), from a past run: dropped once, here, before a page
        // of this run could have been handed one.
        val keep = names.values.toSet()
        worker.execute { d.listFiles()?.filter { it.name.endsWith(".png") && it.name.removeSuffix(".png") !in keep }?.forEach { it.delete() } }
        // As they're drawn, not when a page next asks: a page that already has its list learns of a changed icon only
        // through [version].
        MainScope().launch {
            snapshotFlow { runtime.androidApps.icons.map { "a:${it.key}" to it.value } + runtime.linuxIcons.map { "l:${it.key}" to it.value } }
                .collect { all -> for ((key, bitmap) in all) url(key, bitmap) }
        }
    }

    /**
     * The URL of [key]'s icon, whose picture is [bitmap] (null while it isn't drawn yet), or null when there's none
     * to show. A bitmap not hashed yet is: meanwhile the app's last icon's name stands in (most often the same).
     */
    fun url(
        key: String,
        bitmap: ImageBitmap?,
    ): String? {
        if (bitmap != null) {
            hashed[bitmap]?.let { return "${ShellHost.ORIGIN}/_icon/$it" }
            if (pending.put(bitmap, true) == null) worker.execute { store(key, bitmap) }
        }
        return names[key]?.let { "${ShellHost.ORIGIN}/_icon/$it" }
    }

    /** The file of an icon named [hash] (by [url]), or null. */
    fun file(hash: String): File? = dir?.takeIf { HASH.matches(hash) }?.let { File(it, "$hash.png") }?.takeIf { it.isFile }

    /** On the worker: hashes [bitmap], writes its file if it's new, and names it [key]'s icon. */
    private fun store(
        key: String,
        bitmap: ImageBitmap,
    ) {
        val d = dir ?: return
        val hash =
            runCatching {
                val bmp = bitmap.asAndroidBitmap()
                val pixels = ByteBuffer.allocate(bmp.byteCount)
                bmp.copyPixelsToBuffer(pixels)
                val md = MessageDigest.getInstance("SHA-256")
                md.update("${bmp.width}x${bmp.height}:${bmp.config}".toByteArray())
                md.update(pixels.array())
                val hex = md.digest().joinToString("") { "%02x".format(it) }.take(32)
                val file = File(d, "$hex.png")
                if (!file.isFile) {
                    val tmp = File(d, "$hex.tmp")
                    tmp.outputStream().use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
                    tmp.renameTo(file)
                }
                hex
            }.onFailure { Log.w(TAG, "cannot store the icon of $key", it) }.getOrNull()
        main.post {
            pending.remove(bitmap)
            if (hash == null) return@post
            hashed[bitmap] = hash
            if (names[key] != hash) {
                names[key] = hash
                version.intValue++
                save()
            }
        }
    }

    /** Writes the index, a moment after the last change (icons arrive in bursts). */
    private fun save() {
        if (saveQueued) return
        saveQueued = true
        main.postDelayed({
            saveQueued = false
            val json = JSONObject(names as Map<*, *>).toString()
            val d = dir ?: return@postDelayed
            worker.execute {
                runCatching {
                    val tmp = File(d, "$INDEX.tmp")
                    tmp.writeText(json)
                    tmp.renameTo(File(d, INDEX))
                }.onFailure { Log.w(TAG, "cannot save the icon index", it) }
            }
        }, 2000)
    }
}
