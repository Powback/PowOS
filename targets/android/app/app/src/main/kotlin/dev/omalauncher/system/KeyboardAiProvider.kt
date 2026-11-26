package dev.omalauncher.system

import android.app.AppOpsManager
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.database.Cursor
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Binder
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.provider.Settings
import android.util.Base64
import android.util.Log
import dev.omalauncher.PowosAiChat
import dev.omalauncher.assist.LiveCapture
import dev.omalauncher.linux.Guest
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * The keyboard's door into PowOS AI ([KeyboardAi] has the contract and who may call). Every call runs on a binder
 * thread of the caller's choosing: the keyboard calls from a background thread and shows its own state at once, so a
 * draft taking seconds blocks nothing visible.
 */
class KeyboardAiProvider : ContentProvider() {
    override fun onCreate() = true

    override fun call(
        method: String,
        arg: String?,
        extras: Bundle?,
    ): Bundle {
        val c = context ?: return answer(KeyboardAi.error("failed", "no context"))
        val uid = Binder.getCallingUid()
        KeyboardAi.gate(method, KeyboardAi.Caller(uid, packagesOf(c, uid), signersOf(c, uid), currentIme(c)), Process.myUid())?.let {
            Log.w(TAG, "$method refused: ${it.optString("why")}")
            return answer(it)
        }
        val ask = runCatching { JSONObject(arg ?: "{}") }.getOrNull() ?: return answer(KeyboardAi.error("bad-request", "arg isn't JSON"))
        return answer(
            runCatching { if (method.startsWith("clip.")) clip(c, method, ask, extras) else dispatch(c, method, ask) }.getOrElse {
                Log.w(TAG, "$method failed", it)
                KeyboardAi.error("failed", it.toString())
            },
        )
    }

    private fun dispatch(
        c: Context,
        method: String,
        ask: JSONObject,
    ): JSONObject =
        when (method) {
            "probe" -> probe(c)
            "capture" -> capture(c, ask)
            "drafts" -> drafts(ask)
            "outcome" -> outcome(ask)
            "cancel" -> cancel(ask.optString("shot"), drop = true)
            "release" -> KeyboardAi.ok().also { shots.drop(ask.optString("shot")) }
            else -> chat(c, method, ask)
        }

    /**
     * The universal clipboard ([dev.omalauncher.devices.ClipShare], docs/DEVICES.md "Clipboard and Send to"): "clip.push"
     * {text} or an image in extras ("image" bytes, "mime") - a copy made here, offered to the owner's other devices;
     * "clip.offered" - theirs, for the clipboard panel; "clip.image" {id} - one of their images onto this phone's
     * clipboard, for the keyboard to paste; "clip.switch" {on?} - this device's switch (absent: just read it).
     */
    private fun clip(
        c: Context,
        method: String,
        ask: JSONObject,
        extras: Bundle?,
    ): JSONObject {
        val cs = dev.omalauncher.devices.ClipShare
        return when (method) {
            "clip.push" -> {
                val img = extras?.getByteArray("image")
                val item =
                    when {
                        img != null -> dev.omalauncher.devices.Drops.Item("image", img, mime = extras.getString("mime").orEmpty().ifBlank { "image/png" })
                        ask.optString("text").isNotEmpty() -> dev.omalauncher.devices.Drops.Item.ofText(ask.optString("text"))
                        else -> return KeyboardAi.error("bad-request", "nothing to share")
                    }
                KeyboardAi.ok().put("clip", cs.push(c, item))
            }
            "clip.offered" -> cs.offered(c)
            "clip.image" -> KeyboardAi.ok().put("pasteable", cs.image(c, ask.optString("id")))
            "clip.switch" -> {
                if (ask.has("on")) cs.setEnabled(c, ask.optBoolean("on"))
                KeyboardAi.ok().put("on", cs.enabled(c))
            }
            else -> KeyboardAi.error("bad-request", "no method $method")
        }
    }

    /** The chat panel's calls ([KeyboardAi]'s "Chat"): the AI page's conversation. */
    private fun chat(
        c: Context,
        method: String,
        ask: JSONObject,
    ): JSONObject =
        when (method) {
            "chat.send" -> chatSend(c, ask)
            "chat.poll" -> onMain { page(c, KeyboardAi.ChatCursor(ask.optInt("after", -1), ask.optInt("epoch", -1), ask.optInt("turn", -1))) }
            "chat.history" -> onMain { page(c, KeyboardAi.ChatCursor(last = ask.optInt("n", CHAT_PAGE))) }
            "chat.stop" -> onMain { KeyboardAi.ok().put("stopping", PowosAiChat.busy.also { if (it) PowosAiChat.stop() }) }
            else -> KeyboardAi.error("bad-request", "no method $method")
        }

    /**
     * The keyboard's chat message into the AI page's conversation ([PowosAiChat.send]: a turn now, or queued behind the
     * one under way). "turn": the cursor its items start at.
     */
    private fun chatSend(
        c: Context,
        ask: JSONObject,
    ): JSONObject {
        val text = KeyboardAi.chatText(ask) ?: return KeyboardAi.error("bad-request", "nothing to send")
        return onMain {
            PowosAiChat.load(c)
            val queued = PowosAiChat.busy
            val turn = PowosAiChat.trimmed + PowosAiChat.items.size
            PowosAiChat.send(c, text)
            KeyboardAi.ok().put("turn", turn).put("queued", queued).put("epoch", PowosAiChat.epoch)
        }
    }

    /** On main: [PowosAiChat]'s state is the page's (Compose state), read and changed there only. */
    private fun page(
        c: Context,
        cursor: KeyboardAi.ChatCursor,
    ): JSONObject {
        PowosAiChat.load(c)
        val state =
            KeyboardAi.ChatState(PowosAiChat.items.map { it.json() }, PowosAiChat.trimmed, PowosAiChat.epoch, PowosAiChat.busy, PowosAiChat.queued.size)
        return KeyboardAi.chatPage(state, cursor)
    }

    private fun onMain(block: () -> JSONObject): JSONObject {
        if (Looper.myLooper() == Looper.getMainLooper()) return block()
        var out: JSONObject? = null
        var failed: Throwable? = null
        val done = CountDownLatch(1)
        Handler(Looper.getMainLooper()).post {
            try {
                out = block()
            } catch (t: Throwable) {
                failed = t
            } finally {
                done.countDown()
            }
        }
        if (!done.await(CHAT_MAIN_MS, TimeUnit.MILLISECONDS)) return KeyboardAi.error("timeout", "PowOS is busy - try again")
        failed?.let { throw it }
        return out ?: KeyboardAi.error("failed", "no answer")
    }

    private fun answer(o: JSONObject) = Bundle().apply { putString("json", o.toString()) }

    /** Which screenshot path this phone has, whether PowOS AI can run, and (rooted) whether the focused window is secure. */
    private fun probe(c: Context): JSONObject {
        val via = captureVia()
        return KeyboardAi.ok()
            .put("contract", KeyboardAi.CONTRACT)
            .put("chat", true)
            .put("clips", true)
            .put("capture", via)
            .put("access", if (via == "none") KeyboardAccess.why(restricted(c)) else JSONObject.NULL)
            .put("ai", Guest.enabled)
            .put("secure", if (andro.marchy.RootMode.enabled()) rootFocusSecure() ?: JSONObject.NULL else JSONObject.NULL)
    }

    private fun captureVia(): String =
        KeyboardAccess.via(
            root = andro.marchy.RootMode.enabled(),
            accessibility = KeyboardShotService.instance != null,
            share = KeyboardShare.available(),
            live = LiveCapture.running,
        )

    /**
     * Whether Android blocks the "PowOS keyboard screenshots" toggle (restricted settings, [KeyboardAccess.restricted]):
     * PowOS's own appop, else its install source.
     */
    private fun restricted(c: Context): Boolean {
        val mode =
            runCatching {
                c.getSystemService(AppOpsManager::class.java).unsafeCheckOpNoThrow(KeyboardAccess.OP_RESTRICTED_SETTINGS, Process.myUid(), c.packageName)
            }.getOrNull()
        val source = if (Build.VERSION.SDK_INT >= 33) runCatching { c.packageManager.getInstallSourceInfo(c.packageName).packageSource }.getOrNull() else null
        return KeyboardAccess.restricted(Build.VERSION.SDK_INT, mode, source)
    }

    private fun capture(
        c: Context,
        ask: JSONObject,
    ): JSONObject {
        val via = captureVia()
        if (via == "root" && rootFocusSecure() == true) return KeyboardAi.error("secure", "this screen is private (FLAG_SECURE)")
        if (via == "none") return KeyboardAi.error("needs-access", "PowOS needs to see the screen - tap ✨ to set it up").put("access", KeyboardAccess.why(restricted(c)))
        val full = grab(c, via) ?: return KeyboardAi.error("failed", "the $via screenshot failed")
        val keep = KeyboardAi.cropBottom(full.height, ask.optInt("imeTop"), ask.optInt("screenH"))
        val cropped = if (keep < full.height) Bitmap.createBitmap(full, 0, 0, full.width, keep) else full
        if (cropped !== full) full.recycle()
        val blank = KeyboardAi.blackedOut(sample(cropped))
        val jpeg = if (blank) null else jpeg(cropped)
        val w = cropped.width
        val h = cropped.height
        cropped.recycle()
        if (jpeg == null) return KeyboardAi.error("secure", "this screen is private (the capture is blacked out)")
        Log.i(TAG, "capture via $via: ${w}x$h, ${jpeg.size / 1024} KB")
        return KeyboardAi.ok().put("shot", shots.put(jpeg)).put("w", w).put("h", h).put("via", via)
    }

    private fun grab(
        c: Context,
        via: String,
    ): Bitmap? =
        when (via) {
            "root" -> rootScreencap(c)
            "accessibility" -> accessibilityShot()
            "share" -> KeyboardShare.grab()
            "live" -> LiveCapture.latest()
            else -> null
        }

    private fun drafts(ask: JSONObject): JSONObject {
        val id = ask.optString("shot")
        val jpeg = shots.get(id) ?: return KeyboardAi.error("expired", "the screenshot is gone - tap the button again")
        Guest.unavailable()?.let { return KeyboardAi.error("ai", it) }
        val request = KeyboardAi.guestRequest(ask, Base64.encodeToString(jpeg, Base64.NO_WRAP))
        val p = Guest.process("exec powos manager --drafts", mergeErrors = false).start()
        synchronized(running) { running[id] = p }
        try {
            Thread({ runCatching { p.errorStream.bufferedReader().forEachLine { Log.i(TAG, "drafts: $it") } } }, "kb-ai-err").start()
            runCatching { p.outputStream.use { it.write(request.toString().toByteArray()) } }
            val out = StringBuilder()
            val reader = Thread({ runCatching { out.append(p.inputStream.bufferedReader().readText()) } }, "kb-ai-out")
            reader.start()
            if (!p.waitFor(DRAFTS_MS, TimeUnit.MILLISECONDS)) {
                p.destroyForcibly()
                return KeyboardAi.error("timeout", "PowOS AI took over ${DRAFTS_MS / 1000} s")
            }
            reader.join(2_000)
            val cancelled = synchronized(running) { running[id] !== p }
            if (cancelled) return KeyboardAi.error("cancelled", "cancelled")
            return KeyboardAi.guestAnswer(out.toString(), p.exitValue())
        } finally {
            synchronized(running) { if (running[id] === p) running.remove(id) }
        }
    }

    /**
     * The keyboard's report on an answer: recorded by PowOS Linux in the background (`powos manager --kb-outcome`), so
     * the keyboard's call returns at once; one at a time (a profile regeneration can take a model turn).
     */
    private fun outcome(ask: JSONObject): JSONObject {
        val request = KeyboardAi.outcomeRequest(ask) ?: return KeyboardAi.ok().put("recorded", false)
        if (Guest.unavailable() != null) return KeyboardAi.ok().put("recorded", false)
        outcomes.execute {
            runCatching {
                val p = Guest.process("exec powos manager --kb-outcome", mergeErrors = true).start()
                p.outputStream.use { it.write(request.toString().toByteArray()) }
                val out = Thread({ runCatching { p.inputStream.bufferedReader().forEachLine { Log.i(TAG, "outcome: $it") } } }, "kb-ai-outcome")
                out.start()
                if (!p.waitFor(OUTCOME_MS, TimeUnit.MILLISECONDS)) p.destroyForcibly()
            }.onFailure { Log.w(TAG, "outcome failed", it) }
        }
        return KeyboardAi.ok().put("recorded", true)
    }

    private fun cancel(
        id: String,
        drop: Boolean,
    ): JSONObject {
        val p = synchronized(running) { running.remove(id) }
        p?.destroyForcibly()
        if (drop) shots.drop(id)
        return KeyboardAi.ok().put("killed", p != null)
    }

    private fun rootFocusSecure(): Boolean? {
        val r = andro.marchy.RootShell.run("dumpsys window windows | grep -E 'Window #|fl=|mCurrentFocus'", null, 5_000)
        return if (r.code == 0) KeyboardAi.focusedWindowSecure(r.output) else null
    }

    /** PowOS's su (the app's one root shell) runs screencap into the app's cache; read at once and deleted. */
    private fun rootScreencap(c: Context): Bitmap? {
        val f = File(c.cacheDir, "kb-shot-${System.nanoTime()}.png")
        val uid = Process.myUid()
        return try {
            val r = andro.marchy.RootShell.run("screencap -p '${f.path}' && chown $uid:$uid '${f.path}' && chmod 600 '${f.path}'", null, 10_000)
            if (r.code != 0) {
                Log.w(TAG, "screencap: ${r.output}")
                null
            } else {
                BitmapFactory.decodeFile(f.path)
            }
        } finally {
            f.delete()
        }
    }

    private fun accessibilityShot(): Bitmap? {
        val svc = KeyboardShotService.instance ?: return null
        var shot: Bitmap? = null
        val done = CountDownLatch(1)
        svc.shoot { b, why ->
            shot = b
            if (why != null) Log.w(TAG, why)
            done.countDown()
        }
        done.await(5, TimeUnit.SECONDS)
        return shot
    }

    private fun sample(b: Bitmap): IntArray {
        val n = 48
        return IntArray(n * n) { i -> b.getPixel((i % n) * (b.width - 1) / (n - 1), (i / n) * (b.height - 1) / (n - 1)) }
    }

    /** A JPEG the model reads text from: the long side at most [MAX_SIDE] px. */
    private fun jpeg(b: Bitmap): ByteArray {
        val scale = minOf(1f, MAX_SIDE.toFloat() / maxOf(b.width, b.height))
        val s = if (scale < 1f) Bitmap.createScaledBitmap(b, (b.width * scale).toInt(), (b.height * scale).toInt(), true) else b
        val out = ByteArrayOutputStream()
        s.compress(Bitmap.CompressFormat.JPEG, 82, out)
        if (s !== b) s.recycle()
        return out.toByteArray()
    }

    private fun packagesOf(
        c: Context,
        uid: Int,
    ): List<String> = c.packageManager.getPackagesForUid(uid)?.toList().orEmpty()

    private fun signersOf(
        c: Context,
        uid: Int,
    ): Set<String> {
        val pkg = c.packageManager.getPackagesForUid(uid)?.firstOrNull { it == DefaultKeyboard.PACKAGE } ?: return emptySet()
        val info = runCatching { c.packageManager.getPackageInfo(pkg, PackageManager.GET_SIGNING_CERTIFICATES) }.getOrNull()
        val sha = MessageDigest.getInstance("SHA-256")
        return info?.signingInfo?.apkContentsSigners.orEmpty().map { s -> sha.digest(s.toByteArray()).joinToString("") { "%02x".format(it) } }.toSet()
    }

    private fun currentIme(c: Context): String? = Settings.Secure.getString(c.contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD)

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? = null

    override fun getType(uri: Uri): String? = null

    override fun insert(
        uri: Uri,
        values: ContentValues?,
    ): Uri? = null

    override fun delete(
        uri: Uri,
        selection: String?,
        selectionArgs: Array<out String>?,
    ) = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ) = 0

    private companion object {
        const val TAG = "PowosKeyboardAi"
        const val DRAFTS_MS = 75_000L
        const val OUTCOME_MS = 180_000L
        const val MAX_SIDE = 1600
        const val CHAT_MAIN_MS = 5_000L
        const val CHAT_PAGE = KeyboardAi.CHAT_PAGE
        val shots = KeyboardAi.Shots()
        val running = HashMap<String, java.lang.Process>()
        val outcomes: java.util.concurrent.ExecutorService = java.util.concurrent.Executors.newSingleThreadExecutor()
    }
}
