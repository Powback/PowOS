package dev.omalauncher.system

import android.graphics.BitmapFactory
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/**
 * Each switcher card's last good picture, on disk (the app's cache dir, thumbs/<key>.jpg), so a card always has one:
 * after a restart the system has no snapshot of a task not opened since ("sometimes native apps fail to render in the
 * switcher ... cache the last working screenshot of it", the user, 2026-11-01 18:27). Keyed by the card's app key (its
 * drawer key, the same across restarts; else "task-<id>"). Every picture served for a card ([serve]) that isn't blank
 * ([blank]: all dark or near uniform - a task's black first frame, a display not drawn yet) replaces its last good one;
 * a blank one never does. The card's picture, in order: the live / system snapshot ([serve]'s live: Tasks.snapshot reads
 * the in-memory snapshot, else the one the system persisted under /data/system_ce/0/snapshots), the cached one, none
 * (the page draws the app's icon on its tinted glass, ui/switcher.tsx).
 */
object ThumbCache {
    /** Card id -> its app key, as the switcher's list last named it (ShellBridge.tasks). */
    private val keys = ConcurrentHashMap<Int, String>()

    @Volatile private var dir: File? = null

    fun init(cacheDir: File) {
        if (dir == null) dir = File(cacheDir, "thumbs").apply { mkdirs() }
    }

    fun name(
        id: Int,
        key: String?,
    ) {
        if (!key.isNullOrEmpty()) keys[id] = key
    }

    fun keyOf(id: Int): String = keys[id] ?: "task-$id"

    /** The picture card [id] shows: [live] when it's a real one (kept as its last good), else the last good, else null. */
    fun serve(
        id: Int,
        live: ByteArray?,
    ): ByteArray? {
        val store = dir?.let(::Store) ?: return live?.takeUnless(::blankJpeg)
        return choose(keyOf(id), live, live != null && blankJpeg(live), store)
    }

    /** [serve]'s order, pure: a good live picture (stored), else the stored one, else nothing (never a blank one). */
    fun choose(
        key: String,
        live: ByteArray?,
        liveBlank: Boolean,
        store: Store,
    ): ByteArray? {
        if (live != null && !liveBlank) {
            runCatching { store.put(key, live) }
            return live
        }
        return store.get(key)
    }

    /**
     * Blank: every pixel dark (luma under [DARK]) or the whole frame one colour (luma spread under [FLAT]) - what a task
     * shows before its first draw. [px]: ARGB pixels (a downsampled frame).
     */
    fun blank(px: IntArray): Boolean {
        if (px.isEmpty()) return true
        var max = 0
        var sum = 0L
        var sq = 0L
        for (p in px) {
            val l = luma(p)
            if (l > max) max = l
            sum += l
            sq += l.toLong() * l
        }
        if (max < DARK) return true
        val n = px.size
        val mean = sum.toDouble() / n
        val variance = sq.toDouble() / n - mean * mean
        return variance < FLAT * FLAT
    }

    private fun luma(p: Int): Int = (((p shr 16) and 0xff) * 299 + ((p shr 8) and 0xff) * 587 + (p and 0xff) * 114) / 1000

    private fun blankJpeg(jpeg: ByteArray): Boolean =
        runCatching {
            val b = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, BitmapFactory.Options().apply { inSampleSize = 16 }) ?: return true
            val px = IntArray(b.width * b.height)
            b.getPixels(px, 0, b.width, 0, 0, b.width, b.height)
            b.recycle()
            blank(px)
        }.getOrDefault(false)

    /** Below this luma (0-255) everywhere: a black frame. */
    const val DARK = 20

    /** A luma spread (standard deviation) under this: one flat colour. */
    const val FLAT = 3.0

    /** The pictures on disk, one file per key (its name made safe). */
    class Store(
        private val dir: File,
    ) {
        private fun file(key: String) = File(dir, key.replace(Regex("[^A-Za-z0-9._-]"), "_").take(160) + ".jpg")

        fun get(key: String): ByteArray? = file(key).takeIf { it.isFile }?.readBytes()

        fun put(
            key: String,
            jpeg: ByteArray,
        ) {
            dir.mkdirs()
            val f = file(key)
            val tmp = File(dir, f.name + ".tmp")
            tmp.writeBytes(jpeg)
            tmp.renameTo(f)
        }
    }
}
