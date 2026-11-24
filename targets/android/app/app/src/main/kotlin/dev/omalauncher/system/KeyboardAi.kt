package dev.omalauncher.system

import org.json.JSONArray
import org.json.JSONObject

/**
 * The swipe keyboard's AI reply button (android-app-dev projects/swipe-keyboard, ReplyDrafts.java): the keyboard asks
 * PowOS, through [KeyboardAiProvider] (content://com.powos.app.keyboardai, ContentResolver.call), for a screenshot of
 * the app it types into and a few reply variations drafted from that screenshot, the user's voice note (transcribed by
 * the keyboard on the fleet voice path) and the field's context. The keyboard holds no key and never sees a model:
 * PowOS runs `powos manager --drafts` (lib/ai/manager/reply_drafts.py) in PowOS Linux, signed in exactly like the AI
 * chat (the fleet endpoint's claude-auth tenant, or this device's own Claude login).
 *
 * Contract v1 - every call's arg is a JSON object, every answer a Bundle with one string "json" ({"ok": true, ...} or
 * {"ok": false, "error": <word>, "why": <text>}):
 *  - probe   {}                                    -> {"capture": "root"|"accessibility"|"live"|"none", "ai": bool,
 *                                                      "secure": bool|null}
 *  - capture {"imeTop": px, "screenH": px}         -> {"shot": id, "w", "h", "via"}; errors secure / needs-access /
 *                                                      failed. Taken only on this explicit call; the image is kept in
 *                                                      memory only ([Shots], never written to disk) for [SHOT_TTL_MS]
 *  - drafts  {"shot", "transcript", "text", "app", "hint", "inputType", "n", "avoid": [..]}
 *                                                   -> {"variations": [...], "model"}; errors expired / ai / model /
 *                                                      no-reply / timeout / cancelled / signin / relogin / install
 *  - cancel  {"shot"}                              -> {} the shot's running draft killed, the shot dropped
 *  - release {"shot"}                              -> {} the shot dropped (chips dismissed)
 *
 * Who may call ([admit]): the swipe keyboard signed with [KEYBOARD_SIGNER] while it is the current input method, PowOS
 * itself, and root/shell (which can screencap anyway - the device check calls `content call` from adb).
 *
 * Screenshot paths ([KeyboardAiProvider.capture]): rooted - PowOS's su runs `screencap` (after `dumpsys window` says the
 * focused window isn't FLAG_SECURE); no root - PowOS's accessibility service [KeyboardShotService]
 * (AccessibilityService.takeScreenshot, API 30+, enabled once by the user in Android's accessibility settings), else the
 * live mode's MediaProjection frame when live mode is on ([dev.omalauncher.assist.LiveCapture], its own one-time
 * consent). The keyboard's own rows are cropped off ([cropBottom]); a blacked-out capture (a secure window) is refused.
 */
object KeyboardAi {
    const val AUTHORITY = "com.powos.app.keyboardai"
    const val CONTRACT = 1

    /**
     * SHA-256 of the swipe keyboard's signing certificate: android-app-dev's build key, the one every published build
     * carries and [DefaultKeyboard]'s gate keeps the installed keyboard on.
     */
    const val KEYBOARD_SIGNER = "d284eb721ece90e21d6344ce0cb9a746ab915e4495bb2e00927bd111ab399ae2"

    const val SHOT_TTL_MS = 180_000L
    const val ROOT_UID = 0
    const val SHELL_UID = 2000

    /**
     * Who is calling: its uid, the packages of that uid, their certificates as lowercase SHA-256 hex, and the current
     * input method (Settings.Secure.DEFAULT_INPUT_METHOD, "pkg/.Service").
     */
    data class Caller(
        val uid: Int,
        val packages: List<String>,
        val signers: Set<String>,
        val currentIme: String?,
    )

    /** Why [caller] may not use the button (null: it may); [myUid] is PowOS's own. */
    fun admit(
        caller: Caller,
        myUid: Int,
    ): String? =
        when {
            caller.uid == myUid || caller.uid == ROOT_UID || caller.uid == SHELL_UID -> null
            DefaultKeyboard.PACKAGE !in caller.packages -> "only PowOS's keyboard may ask (uid ${caller.uid}: ${caller.packages.joinToString()})"
            KEYBOARD_SIGNER !in caller.signers -> "the keyboard isn't signed with PowOS's keyboard key"
            caller.currentIme?.substringBefore('/') != DefaultKeyboard.PACKAGE -> "the keyboard isn't the current input method"
            else -> null
        }

    /**
     * Whether `dumpsys window windows` says the focused window is FLAG_SECURE (null: no focused window found). Reads the
     * "Window #N Window{h u0 name}:" blocks, their `fl=` flag lines (not `pfl=`), and mCurrentFocus.
     */
    fun focusedWindowSecure(dump: String): Boolean? {
        val header = Regex("""Window #\d+ (Window\{[^}]+\})""")
        val focus = Regex("""mCurrentFocus=(Window\{[^}]+\})""").find(dump)?.groupValues?.get(1) ?: return null
        val secure = HashMap<String, Boolean>()
        var current: String? = null
        for (line in dump.lineSequence()) {
            header.find(line)?.let {
                current = it.groupValues[1]
                secure.putIfAbsent(it.groupValues[1], false)
            }
            val w = current ?: continue
            Regex("""(?<![A-Za-z])fl=(.*)""").find(line)?.let { m ->
                // Flags run until the next key=value (pfl=, vsysui=, ...).
                val flags = m.groupValues[1].split(' ').takeWhile { '=' !in it }
                if ("SECURE" in flags) secure[w] = true
            }
        }
        return secure[focus] ?: false
    }

    /** True when a capture is (almost) all black: what a FLAG_SECURE window becomes in a screenshot. [argb] samples. */
    fun blackedOut(argb: IntArray): Boolean {
        if (argb.isEmpty()) return true
        val dark =
            argb.count {
                (it shr 16 and 0xff) < 10 && (it shr 8 and 0xff) < 10 && (it and 0xff) < 10
            }
        return dark >= argb.size * 0.98
    }

    /**
     * Rows of a [bitmapH]-tall capture to keep: those above the keyboard. [imeTop] is the keyboard window's top on a
     * [screenH]-tall screen (the keyboard's own coordinates); the capture may be scaled (live mode's third). Invalid
     * input keeps everything.
     */
    fun cropBottom(
        bitmapH: Int,
        imeTop: Int,
        screenH: Int,
    ): Int {
        if (imeTop <= 0 || screenH <= 0 || imeTop >= screenH) return bitmapH
        return (bitmapH.toLong() * imeTop / screenH).toInt().coerceIn(1, bitmapH)
    }

    /** The JSON request `powos manager --drafts` reads (reply_drafts.py's contract v1) from the keyboard's [ask]. */
    fun guestRequest(
        ask: JSONObject,
        imageB64: String,
    ): JSONObject {
        val avoid = JSONArray()
        ask.optJSONArray("avoid")?.let { a -> for (i in 0 until minOf(a.length(), 10)) a.optString(i).takeIf { it.isNotBlank() }?.let(avoid::put) }
        return JSONObject()
            .put("v", CONTRACT)
            .put("image", imageB64)
            .put("mime", "image/jpeg")
            .put("transcript", ask.optString("transcript").take(2000))
            .put("text", ask.optString("text").take(2000))
            .put("app", ask.optString("app").take(200))
            .put("hint", ask.optString("hint").take(200))
            .put("inputType", ask.optInt("inputType"))
            .put("n", ask.optInt("n", 3).coerceIn(1, 5))
            .put("avoid", avoid)
    }

    /** The guest's answer (its last JSON line) as the keyboard's answer; anything else is a "model" error. */
    fun guestAnswer(
        out: String,
        exit: Int,
    ): JSONObject {
        val line = out.lineSequence().map { it.trim() }.lastOrNull { it.startsWith("{") }
        val o = line?.let { runCatching { JSONObject(it) }.getOrNull() }
        if (o == null || !o.has("ok")) return error("model", "PowOS AI answered nothing (exit $exit)${out.trim().takeLast(200).let { if (it.isEmpty()) "" else ": $it" }}")
        if (o.optBoolean("ok")) {
            val v = o.optJSONArray("variations")
            if (v == null || v.length() == 0) return error("no-reply", "no variations")
        }
        return o
    }

    fun ok(): JSONObject = JSONObject().put("ok", true)

    fun error(
        word: String,
        why: String,
    ): JSONObject = JSONObject().put("ok", false).put("error", word).put("why", why)

    /** Screenshots between the keyboard's capture and its last draft: in memory only, gone after [SHOT_TTL_MS]. */
    class Shots(private val now: () -> Long = System::currentTimeMillis) {
        private class Shot(
            val jpeg: ByteArray,
            val at: Long,
        )

        private val shots = HashMap<String, Shot>()
        private var serial = 0L

        @Synchronized fun put(jpeg: ByteArray): String {
            expire()
            val id = "s${now()}-${++serial}"
            shots[id] = Shot(jpeg, now())
            return id
        }

        @Synchronized fun get(id: String): ByteArray? {
            expire()
            return shots[id]?.jpeg
        }

        @Synchronized fun drop(id: String) {
            shots.remove(id)
        }

        @Synchronized fun size(): Int {
            expire()
            return shots.size
        }

        private fun expire() {
            val t = now()
            shots.entries.removeAll { t - it.value.at > SHOT_TTL_MS }
        }
    }
}
