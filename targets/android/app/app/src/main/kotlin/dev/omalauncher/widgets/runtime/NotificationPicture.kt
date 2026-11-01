package dev.omalauncher.widgets.runtime

import android.app.Notification
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Icon
import android.os.Bundle
import android.service.notification.StatusBarNotification
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.URLEncoder

/**
 * A notification's big picture (BigPictureStyle's EXTRA_PICTURE, or EXTRA_PICTURE_ICON), for the shade's expanded
 * card (shell/ui/notifications.tsx). The list only says one exists - a URL ([url]) the page loads on its own,
 * /_npic/<key> (ShellHost) - so no image bytes ride the notification JSON and the list never waits on a decode;
 * the JPEG is made when the card asks ([jpeg]), at most [MAX_WIDTH] wide, its scaled copy recycled at once.
 */
object NotificationPicture {
    /** The widest picture sent: the expanded card's width on a phone, at the most. */
    const val MAX_WIDTH = 720

    /** ...and the tallest (a tall strip would otherwise scale to 720 wide and huge). */
    const val MAX_HEIGHT = 1440

    /** The JPEG quality: a photo in a card. */
    const val QUALITY = 80

    /** The small icon's side, in px: the card's 20 dp icon at up to 3x. */
    const val ICON_PX = 64

    /**
     * The page's URL of [key]'s small icon (Notification.getSmallIcon: the status bar's monochrome glyph, which the
     * page tints with [color]) - every Android notification has one; posted at [time], so an update is fetched again.
     */
    fun smallUrl(
        origin: String,
        key: String,
        time: Long,
    ): String = "$origin/_nicon/${URLEncoder.encode(key, "UTF-8")}?t=$time"

    /** Notification.color as the page's CSS ("#rrggbb"), null: the app set none (COLOR_DEFAULT). */
    fun color(argb: Int): String? = if (argb == Notification.COLOR_DEFAULT) null else String.format("#%06x", argb and 0xffffff)

    /** [sbn]'s small icon as a PNG, [ICON_PX] square (its shape in its alpha: the page masks with it), null: none. */
    fun smallPng(
        sbn: StatusBarNotification,
        context: android.content.Context,
    ): ByteArray? =
        runCatching {
            val d = sbn.notification.smallIcon?.loadDrawable(context) ?: return null
            val b = Bitmap.createBitmap(ICON_PX, ICON_PX, Bitmap.Config.ARGB_8888)
            try {
                d.setBounds(0, 0, ICON_PX, ICON_PX)
                d.draw(Canvas(b))
                ByteArrayOutputStream().also { b.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
            } finally {
                b.recycle()
            }
        }.getOrNull()

    /** Whether [extras] carry a big picture - a key check, nothing decoded. */
    fun has(extras: Bundle?): Boolean =
        extras != null && (extras.containsKey(Notification.EXTRA_PICTURE) || extras.containsKey(Notification.EXTRA_PICTURE_ICON))

    /** The page's URL of [key]'s picture (posted at [time], so an update is fetched again), null: none - no field. */
    fun url(
        origin: String,
        key: String,
        time: Long,
        has: Boolean,
    ): String? = if (has) "$origin/_npic/${URLEncoder.encode(key, "UTF-8")}?t=$time" else null

    /** [o] (a notification's JSON) with "picture": [url] - left out, not null, when there's none. */
    fun put(
        o: JSONObject,
        url: String?,
    ): JSONObject = o.apply { url?.let { put("picture", it) } }

    /**
     * The size a [width] x [height] picture is sent at: scaled down (never up) to fit [MAX_WIDTH] x [MAX_HEIGHT],
     * aspect kept, at least 1 px; null for an empty one.
     */
    fun scaled(
        width: Int,
        height: Int,
    ): Pair<Int, Int>? {
        if (width <= 0 || height <= 0) return null
        val f = minOf(1.0, MAX_WIDTH.toDouble() / width, MAX_HEIGHT.toDouble() / height)
        if (f >= 1.0) return width to height
        return maxOf(1, (width * f).toInt()) to maxOf(1, (height * f).toInt())
    }

    /** [sbn]'s picture as a JPEG ([scaled]), or null: none, or it couldn't be read. */
    fun jpeg(
        sbn: StatusBarNotification,
        context: android.content.Context,
    ): ByteArray? =
        runCatching {
            val extras = sbn.notification.extras
            @Suppress("DEPRECATION")
            val bitmap = runCatching { extras.getParcelable<Bitmap>(Notification.EXTRA_PICTURE) }.getOrNull()
            // The notification's own bitmap is never recycled here; only the copies made below are.
            if (bitmap != null) encode(bitmap, owned = false) else iconBitmap(extras, context)?.let { encode(it, owned = true) }
        }.getOrNull()

    /** EXTRA_PICTURE_ICON drawn straight at the sent size: a large one is never kept as a second full-size bitmap. */
    private fun iconBitmap(
        extras: Bundle,
        context: android.content.Context,
    ): Bitmap? {
        @Suppress("DEPRECATION")
        val icon = runCatching { extras.getParcelable<Icon>(Notification.EXTRA_PICTURE_ICON) }.getOrNull() ?: return null
        val d = icon.loadDrawable(context) ?: return null
        val (w, h) = scaled(d.intrinsicWidth, d.intrinsicHeight) ?: return null
        return Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888).also { b ->
            d.setBounds(0, 0, w, h)
            d.draw(Canvas(b))
        }
    }

    /** [src] scaled ([scaled]) and JPEG'd; every bitmap made on the way - and [src] when [owned] - recycled. */
    private fun encode(
        src: Bitmap,
        owned: Boolean,
    ): ByteArray? {
        val made = ArrayList<Bitmap>(2)
        if (owned) made += src
        try {
            val (w, h) = scaled(src.width, src.height) ?: return null
            // A hardware bitmap can't be scaled or compressed in software: a software copy first.
            val soft = if (src.config == Bitmap.Config.HARDWARE) src.copy(Bitmap.Config.ARGB_8888, false).also { made += it } else src
            val out = if (w == soft.width && h == soft.height) soft else Bitmap.createScaledBitmap(soft, w, h, true).also { made += it }
            return ByteArrayOutputStream().also { out.compress(Bitmap.CompressFormat.JPEG, QUALITY, it) }.toByteArray()
        } finally {
            made.forEach { it.recycle() }
        }
    }
}
