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
import android.util.Base64
import android.util.Log
import dev.omalauncher.theme.ThemeStore
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
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

    /** What the page gets (system.glass): the picture's URL and revision (null until there is one), and [blurBehind]. */
    fun info(
        context: Context,
        blurBehind: Boolean,
    ): JSONObject {
        refresh(context)
        // A live wallpaper (a fold just asked again): looked at once more when its playing is over.
        if (cached?.source == "live") refresh(context, LIVE_SETTLE_MS)
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
        if (changed) main.post { onChange.forEach { it() } }
        return pic
    }

    /** The current wallpaper's revision, where it comes from, and how to read it. */
    private fun which(context: Context): Triple<String, String, () -> Bitmap?>? {
        val wm = WallpaperManager.getInstance(context)
        val info = wm.wallpaperInfo
        if (info == null) {
            val id = wm.getWallpaperId(WallpaperManager.FLAG_SYSTEM)
            return Triple("still-$id", "still") { wm.drawable?.let(::draw) }
        }
        if (info.packageName == context.packageName) {
            val file = ThemeStore.savedSelection(context)?.second ?: return null
            return Triple("theme-${file.path.hashCode()}-${file.lastModified()}", "theme") { decode(ImageDecoder.createSource(file)) }
        }
        // Another app's live wallpaper (OxygenOS's video ones): the frame it shows now, from the compositor (its surface
        // mirrored - WallpaperBackdrop.still, READ_FRAME_BUFFER through the recents role). Its revision is the picture's
        // own (a sampled hash): another frame - after an unlock, a fold - is another picture; the same one isn't.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val shot = liveFrame(context)
            if (shot != null) {
                val rev = "live-${info.component.flattenToShortString().hashCode()}-${sample(shot)}"
                return Triple(rev, "live") { shot }
            }
        }
        if (andro.marchy.RootMode.enabled()) {
            // HACK: another app's live wallpaper has no picture an app can ask for (WallpaperManager hands out still
            // ones only); OxygenOS keeps a screenshot of it for its own previews, read here as root. Real fix: none in
            // the platform API - on a ROM without that file, the wallpaper's thumbnail below.
            val path = "/data/system/users/${android.os.Process.myUid() / 100000}/wallpaper_screenshot.png"
            val stamp = andro.marchy.RootShell.run("stat -c %Y $path", null, 5_000)
            if (stamp.code == 0 && stamp.output.trim().isNotEmpty()) {
                return Triple("shot-${info.component.flattenToShortString().hashCode()}-${stamp.output.trim()}", "screenshot") {
                    val r = andro.marchy.RootShell.run("base64 -w 0 $path", null, 10_000)
                    check(r.code == 0) { "base64 failed (${r.code})" }
                    decode(ImageDecoder.createSource(ByteBuffer.wrap(Base64.decode(r.output.trim(), Base64.DEFAULT))))
                }
            }
        }
        return Triple("thumb-${info.component.flattenToShortString()}", "thumbnail") { info.loadThumbnail(context.packageManager)?.let(::draw) }
    }

    /** The live wallpaper's current frame, at most [MAX_SIDE] (null: not this way). */
    @androidx.annotation.RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun liveFrame(context: Context): Bitmap? {
        val display = context.getSystemService(android.hardware.display.DisplayManager::class.java).getDisplay(android.view.Display.DEFAULT_DISPLAY) ?: return null
        val size = android.graphics.Point()
        @Suppress("DEPRECATION")
        display.getRealSize(size)
        if (size.x <= 0 || size.y <= 0) return null
        val scale = minOf(1f, MAX_SIDE.toFloat() / max(size.x, size.y))
        return WallpaperBackdrop.still(display.displayId, android.graphics.Rect(0, 0, size.x, size.y), scale)
    }

    /** A cheap fingerprint of a picture: a 16 x 16 grid of its pixels. */
    private fun sample(b: Bitmap): Int {
        var h = b.width * 31 + b.height
        for (y in 0 until 16) for (x in 0 until 16) h = h * 31 + b.getPixel(x * (b.width - 1) / 15, y * (b.height - 1) / 15)
        return h
    }

    private fun decode(src: ImageDecoder.Source): Bitmap =
        ImageDecoder.decodeBitmap(src) { decoder, i, _ ->
            val scale = MAX_SIDE.toFloat() / max(i.size.width, i.size.height)
            if (scale < 1f) decoder.setTargetSize((i.size.width * scale).roundToInt(), (i.size.height * scale).roundToInt())
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        }

    private fun draw(d: Drawable): Bitmap? {
        val w = d.intrinsicWidth
        val h = d.intrinsicHeight
        if (w <= 0 || h <= 0) return null
        val scale = minOf(1f, MAX_SIDE.toFloat() / max(w, h))
        val b = Bitmap.createBitmap((w * scale).roundToInt().coerceAtLeast(1), (h * scale).roundToInt().coerceAtLeast(1), Bitmap.Config.ARGB_8888)
        d.setBounds(0, 0, b.width, b.height)
        d.draw(Canvas(b))
        return b
    }
}
