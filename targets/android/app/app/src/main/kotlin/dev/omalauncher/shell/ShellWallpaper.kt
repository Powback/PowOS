package dev.omalauncher.shell

import android.app.WallpaperManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.ImageDecoder
import android.graphics.drawable.Drawable
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import dev.omalauncher.theme.ThemeStore
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * The wallpaper behind the shell's page, as a picture the page can use: shell/ui/glass.ts frosts it once and every
 * glass surface on home shows that frosted copy where it sits on the screen. Android draws the wallpaper behind the
 * window, out of the page's reach - CSS backdrop-filter over a transparent page has nothing to blur.
 *
 * Where the picture comes from, the first that has one:
 * - our own live wallpaper (OmarchyWallpaperService): the theme's background - exactly what it draws;
 * - a still wallpaper: WallpaperManager's picture (READ_EXTERNAL_STORAGE, at the app's target SDK);
 * - another app's live wallpaper (OxygenOS's video ones): the frame it shows now, from the compositor; failing that,
 *   rooted, the system's own screenshot of it (a stale frame); else its thumbnail.
 *
 * Scaled to at most [MAX_SIDE] (the page blurs it hard: plenty) and kept until its revision changes. Worked out off
 * the main thread: [info] answers with what's cached and looks again in the background; a new picture is announced
 * through [onChange] ("system.glass").
 */
internal object ShellWallpaper {
    private const val TAG = "PowosWallpaper"
    private const val MAX_SIDE = 720
    private const val LIVE_SETTLE_MS = 2_500L

    /** The session's copy ([writeSession]): the longest side, px - about the inner screen's at Plasma's scale 2. */
    private const val SESSION_SIDE = 1600
    private const val SESSION_PREFIX = "powos-wallpaper-"

    private class Pic(
        val rev: String,
        val source: String,
        val jpeg: ByteArray,
    )

    @Volatile private var cached: Pic? = null
    private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "shell-wallpaper").apply { isDaemon = true } }
    private val main = Handler(Looper.getMainLooper())

    /** Told (on the main thread) when the picture is another one: the bridges emit "system.glass". */
    val onChange = java.util.concurrent.CopyOnWriteArraySet<() -> Unit>()

    /**
     * What the page gets (system.glass): the picture's URL and revision (null until there is one), and [blurBehind].
     * [look]: the page asked (it loaded, or folded) - the wallpaper is looked at again. Not when the answer is the
     * announcement of a new picture ([onChange]): looking again there found a live (video) wallpaper's next frame, a
     * new picture, announced again - a loop, several compositor captures a second in every page, for as long as the
     * wallpaper played (seen 2026-10-21: 339 pictures in the log's few minutes).
     */
    fun info(
        context: Context,
        blurBehind: Boolean,
        look: Boolean = true,
    ): JSONObject {
        if (look) {
            refresh(context)
            // A live wallpaper (a fold just asked again): looked at once more when its playing is over.
            if (cached?.source == "live") refresh(context, LIVE_SETTLE_MS)
        }
        val p = cached
        val wp = p?.let { JSONObject().put("url", "/_wallpaper?v=${Uri.encode(it.rev)}").put("rev", it.rev).put("source", it.source) }
        return JSONObject().put("wallpaper", wp ?: JSONObject.NULL).put("blurBehind", blurBehind)
    }

    /** The picture as it is now (its revision, its bytes), if it's been read; [refresh] reads it. */
    fun current(): Pair<String, ByteArray>? = cached?.let { it.rev to it.jpeg }

    /** The picture's bytes (ShellHost's /_wallpaper, on the WebView's loader thread). */
    fun jpeg(context: Context): ByteArray? = cached?.jpeg ?: load(context)?.jpeg

    /** Looks again in the background (the wallpaper or theme changed, the screen did): a new picture is announced. */
    fun refresh(
        context: Context,
        delayMs: Long = 0,
    ) {
        val app = context.applicationContext
        val run = Runnable { worker.execute { load(app) } }
        if (delayMs > 0) main.postDelayed(run, delayMs) else run.run()
    }

    @Synchronized
    private fun load(context: Context): Pic? {
        val (rev, source, read) = which(context) ?: return null
        cached?.takeIf { it.rev == rev }?.let { return it }
        val bitmap = runCatching { read() }.onFailure { Log.w(TAG, "no picture from $source", it) }.getOrNull() ?: return cached
        val jpeg = ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.JPEG, 88, it) }.toByteArray()
        bitmap.recycle()
        val pic = Pic(rev, source, jpeg)
        val changed = cached?.rev != rev
        cached = pic
        Log.i(TAG, "wallpaper picture: $source, ${jpeg.size / 1024} KB")
        if (changed) {
            main.post { onChange.forEach { it() } }
            worker.execute { writeSession(context) }
        }
        return pic
    }

    /**
     * The same picture for the PowOS session (Plasma's desktop, org.powos.transparent): the run dir's
     * powos-wallpaper-<ms>.jpg (/run/powos-app in the session), sharper than the page's ([SESSION_SIDE]) - Plasma draws
     * it full screen, not blurred. A new name per picture (written aside, then renamed; all but the last two deleted), so
     * the wallpaper's folder watch sees a new file. Why the desktop draws it instead of staying transparent over Android's
     * wallpaper: every snapshot Android takes of the desktop's task (the starting window when it comes back, recents,
     * PowOS's switcher cards, the assist screenshot) leaves the wallpaper out, and showed the desktop on black.
     */
    private fun writeSession(context: Context) {
        val read = which(context, SESSION_SIDE)?.third ?: return
        val bitmap = runCatching { read() }.onFailure { Log.w(TAG, "no session picture", it) }.getOrNull() ?: return
        runCatching {
            val dir = andro.marchy.SessionService.runDir(context).apply { mkdirs() }
            val name = "$SESSION_PREFIX${System.currentTimeMillis()}.jpg"
            val tmp = java.io.File(dir, ".$name")
            tmp.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 90, it) }
            check(tmp.renameTo(java.io.File(dir, name))) { "rename failed" }
            // The one before stays (Plasma shows it until the new one has loaded); older ones go.
            dir.listFiles { f -> f.name.startsWith(SESSION_PREFIX) }?.sortedByDescending { it.name }?.drop(2)?.forEach { it.delete() }
            Log.i(TAG, "session wallpaper: $name ${bitmap.width}x${bitmap.height}")
        }.onFailure { Log.w(TAG, "can't write the session wallpaper", it) }
        bitmap.recycle()
    }

    /** The current wallpaper's revision, where it comes from, and how to read it. */
    private fun which(
        context: Context,
        side: Int = MAX_SIDE,
    ): Triple<String, String, () -> Bitmap?>? {
        val wm = WallpaperManager.getInstance(context)
        val info = wm.wallpaperInfo
        if (info == null) {
            val id = wm.getWallpaperId(WallpaperManager.FLAG_SYSTEM)
            return Triple("still-$id", "still") { wm.drawable?.let { draw(it, side) } }
        }
        if (info.packageName == context.packageName) {
            val file = ThemeStore.savedSelection(context)?.second ?: return null
            return Triple("theme-${file.path.hashCode()}-${file.lastModified()}", "theme") { decode(ImageDecoder.createSource(file), side) }
        }
        // Another app's live wallpaper (OxygenOS's video ones): the frame it shows now, from the compositor (its surface
        // mirrored - WallpaperBackdrop.still, READ_FRAME_BUFFER through the recents role). Its revision is the picture's
        // own (a sampled hash): another frame - after an unlock, a fold - is another picture; the same one isn't.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val shot = liveFrame(context, side)
            if (shot != null) {
                val rev = "live-${info.component.flattenToShortString().hashCode()}-${sample(shot)}"
                return Triple(rev, "live") { shot }
            }
        }
        if (andro.marchy.RootMode.enabled()) rootShot(context, info, side)?.let { return it }
        return Triple("thumb-${info.component.flattenToShortString()}", "thumbnail") { info.loadThumbnail(context.packageManager)?.let { draw(it, side) } }
    }

    /** Rooted: OxygenOS's own screenshot of another app's live wallpaper (null: none, or an empty one). */
    private fun rootShot(
        context: Context,
        info: android.app.WallpaperInfo,
        side: Int,
    ): Triple<String, String, () -> Bitmap?>? {
        // HACK: another app's live wallpaper has no picture an app can ask for (WallpaperManager hands out still
        // ones only); OxygenOS keeps a screenshot of it for its own previews, read here as root. Real fix: none in
        // the platform API - on a ROM without that file, which() falls to the wallpaper's thumbnail.
        val path = "/data/system/users/${android.os.Process.myUid() / 100000}/wallpaper_screenshot.png"
        // Its time and size: OxygenOS sometimes leaves it empty (0 bytes, seen 2026-10-21) - then the thumbnail.
        val stamp = andro.marchy.RootShell.run("stat -c '%Y %s' $path", null, 5_000)
        val (time, size) = stamp.output.trim().split(' ').let { (it.getOrNull(0) ?: "") to (it.getOrNull(1)?.toLongOrNull() ?: 0L) }
        if (stamp.code == 0 && time.isNotEmpty() && size > 0) {
            return Triple("shot-${info.component.flattenToShortString().hashCode()}-$time", "screenshot") {
                // Copied as a file into our cache (ours: owner, mode, SELinux label) and decoded from there - its bytes
                // through the root shell's output came back garbled (ImageDecoder: "Input contained an error").
                val dst = java.io.File(context.cacheDir, "wallpaper-shot.png")
                val uid = android.os.Process.myUid()
                val r =
                    andro.marchy.RootShell.run(
                        "cat '$path' > '${dst.path}' && chown $uid:$uid '${dst.path}' && chmod 600 '${dst.path}' && restorecon '${dst.path}'",
                        null,
                        10_000,
                    )
                check(r.code == 0) { "copy failed (${r.code}): ${r.output.take(200)}" }
                decode(ImageDecoder.createSource(dst), side)
            }
        }
        return null
    }

    /** The live wallpaper's current frame, at most [side] (null: not this way). */
    @androidx.annotation.RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun liveFrame(
        context: Context,
        side: Int,
    ): Bitmap? {
        val display = context.getSystemService(android.hardware.display.DisplayManager::class.java).getDisplay(android.view.Display.DEFAULT_DISPLAY) ?: return null
        val size = android.graphics.Point()
        @Suppress("DEPRECATION")
        display.getRealSize(size)
        if (size.x <= 0 || size.y <= 0) return null
        val scale = minOf(1f, side.toFloat() / max(size.x, size.y))
        return WallpaperBackdrop.still(display.displayId, android.graphics.Rect(0, 0, size.x, size.y), scale)
    }

    /** A cheap fingerprint of a picture: a 16 x 16 grid of its pixels. */
    private fun sample(b: Bitmap): Int {
        var h = b.width * 31 + b.height
        for (y in 0 until 16) for (x in 0 until 16) h = h * 31 + b.getPixel(x * (b.width - 1) / 15, y * (b.height - 1) / 15)
        return h
    }

    private fun decode(
        src: ImageDecoder.Source,
        side: Int,
    ): Bitmap =
        ImageDecoder.decodeBitmap(src) { decoder, i, _ ->
            val scale = side.toFloat() / max(i.size.width, i.size.height)
            if (scale < 1f) decoder.setTargetSize((i.size.width * scale).roundToInt(), (i.size.height * scale).roundToInt())
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        }

    private fun draw(
        d: Drawable,
        side: Int,
    ): Bitmap? {
        val w = d.intrinsicWidth
        val h = d.intrinsicHeight
        if (w <= 0 || h <= 0) return null
        val scale = minOf(1f, side.toFloat() / max(w, h))
        val b = Bitmap.createBitmap((w * scale).roundToInt().coerceAtLeast(1), (h * scale).roundToInt().coerceAtLeast(1), Bitmap.Config.ARGB_8888)
        d.setBounds(0, 0, b.width, b.height)
        d.draw(Canvas(b))
        return b
    }
}
