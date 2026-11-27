package dev.omalauncher.livetext

import android.graphics.Bitmap
import android.util.Base64
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL

/**
 * The two readers behind Live Text (docs/research/live-text.md):
 *  - [device]: ML Kit's bundled Latin text recognizer. The model ships inside the APK (com.google.mlkit:text-recognition,
 *    not the Play Services one), so it reads offline, with no Google Play Services and no root, in ~100-300 ms.
 *  - [powstation]: PowScan's /api/ocr "spot" mode, PaddleOCR-VL-1.6 on gpu-195's llm-pool (model "ocr"; the pool owns
 *    GPU1 and swaps the model in itself). Better on handwriting, non-Latin scripts and dense pages; LAN/VPN only.
 * Both blocking: call off the main thread.
 */
object LiveTextOcr {
    /** PowScan's OCR route (LAN/VPN, `.pow` answers 403 elsewhere). */
    const val POWSTATION_URL = "http://powscan.pow/api/ocr"

    fun device(bmp: Bitmap): Read {
        val client = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
        try {
            val text = Tasks.await(client.process(InputImage.fromBitmap(bmp, 0)))
            val w = bmp.width.toFloat()
            val h = bmp.height.toFloat()
            val lines =
                text.textBlocks.flatMap { block ->
                    block.lines.map { line ->
                        line.elements.mapNotNull { el ->
                            val b = el.boundingBox ?: return@mapNotNull null
                            Word(el.text, b.left / w, b.top / h, b.right / w, b.bottom / h, 0)
                        }
                    }
                }
            return Read.ofLines(lines, "device")
        } finally {
            client.close()
        }
    }

    /** PaddleOCR-VL through PowScan; null when PowStation isn't reachable or answers nothing usable. */
    fun powstation(
        bmp: Bitmap,
        url: String = POWSTATION_URL,
    ): Read? =
        runCatching {
            val scaled = scaleTo(bmp, 1600)
            val jpeg = ByteArrayOutputStream().also { scaled.compress(Bitmap.CompressFormat.JPEG, 88, it) }.toByteArray()
            val body =
                JSONObject()
                    .put("image", "data:image/jpeg;base64," + Base64.encodeToString(jpeg, Base64.NO_WRAP))
                    .put("mode", "spot")
                    .toString()
                    .toByteArray()
            val c = URL(url).openConnection() as HttpURLConnection
            c.connectTimeout = 1500
            c.readTimeout = 60_000 // a cold pool swaps the model in first (~50 s measured)
            c.requestMethod = "POST"
            c.doOutput = true
            c.setRequestProperty("content-type", "application/json")
            try {
                c.outputStream.use { it.write(body) }
                if (c.responseCode != 200) return null
                parseSpots(c.inputStream.use { String(it.readBytes()) })
            } finally {
                c.disconnect()
            }
        }.getOrNull()

    /** PowScan's { spots: [{ text, quad: [[x,y]x4] in 0-1 }] } into a [Read] (line boxes split into words). */
    fun parseSpots(json: String): Read? {
        val spots = JSONObject(json).optJSONArray("spots") ?: return null
        val lines = mutableListOf<List<Word>>()
        for (i in 0 until spots.length()) {
            val s = spots.getJSONObject(i)
            val quad = s.optJSONArray("quad") ?: continue
            val xs = (0 until quad.length()).map { quad.getJSONArray(it).getDouble(0).toFloat() }
            val ys = (0 until quad.length()).map { quad.getJSONArray(it).getDouble(1).toFloat() }
            if (xs.isEmpty()) continue
            lines += Read.splitLine(s.optString("text"), xs.min(), ys.min(), xs.max(), ys.max())
        }
        return Read.ofLines(lines, "powstation").takeIf { it.words.isNotEmpty() }
    }

    private fun scaleTo(
        bmp: Bitmap,
        max: Int,
    ): Bitmap {
        val m = maxOf(bmp.width, bmp.height)
        if (m <= max) return bmp
        val k = max.toFloat() / m
        return Bitmap.createScaledBitmap(bmp, (bmp.width * k).toInt(), (bmp.height * k).toInt(), true)
    }
}
