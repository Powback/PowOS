package dev.omalauncher.system

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The keyboard AI button's door (KeyboardAi / KeyboardAiProvider): who may call, the secure-window check, the contract. */
class KeyboardAiTest {
    private val me = 10_100
    private val kb = 10_200
    private val pkg = listOf(DefaultKeyboard.PACKAGE)
    private val signer = setOf(KeyboardAi.KEYBOARD_SIGNER)
    private val ime = DefaultKeyboard.IME

    @Test fun keyboardSignedAndActiveMayCall() {
        assertNull(KeyboardAi.admit(kb, me, pkg, signer, ime))
    }

    @Test fun powosRootAndShellMayCall() {
        assertNull(KeyboardAi.admit(me, me, emptyList(), emptySet(), null))
        assertNull(KeyboardAi.admit(KeyboardAi.ROOT_UID, me, emptyList(), emptySet(), null))
        assertNull(KeyboardAi.admit(KeyboardAi.SHELL_UID, me, emptyList(), emptySet(), null))
    }

    @Test fun otherAppsAreRefused() {
        assertNotNull(KeyboardAi.admit(kb, me, listOf("com.evil"), signer, ime))
        assertNotNull(KeyboardAi.admit(kb, me, emptyList(), emptySet(), ime))
    }

    @Test fun keyboardPackageWithAnotherSignerIsRefused() {
        val why = KeyboardAi.admit(kb, me, pkg, setOf("00".repeat(32)), ime)
        assertTrue(why!!.contains("signed"))
    }

    @Test fun keyboardNotTheInputMethodIsRefused() {
        assertTrue(KeyboardAi.admit(kb, me, pkg, signer, "com.google.android.inputmethod.latin/.LatinIME")!!.contains("input method"))
        assertNotNull(KeyboardAi.admit(kb, me, pkg, signer, null))
    }

    private val dump =
        """
          Window #0 Window{aa11 u0 InputMethod}:
            mAttrs={(0,0)(fillxwrap) gr=BOTTOM ty=INPUT_METHOD fmt=TRANSPARENT
              fl=NOT_FOCUSABLE LAYOUT_IN_SCREEN
              pfl=SECURE_ISH USE_BLAST
          Window #1 Window{bb22 u0 com.bank/com.bank.Login}:
            mAttrs={(0,0)(fillxfill) ty=BASE_APPLICATION fmt=TRANSPARENT
              fl=LAYOUT_IN_SCREEN LAYOUT_INSET_DECOR SECURE HARDWARE_ACCELERATED
          Window #2 Window{cc33 u0 com.whatsapp/com.whatsapp.Conversation}:
            mAttrs={(0,0)(fillxfill) sim={adjust=resize} ty=BASE_APPLICATION fmt=TRANSPARENT wanim=0x10302f8 fl=LAYOUT_IN_SCREEN HARDWARE_ACCELERATED
              pfl=SECURE
        """.trimIndent()

    @Test fun focusedSecureWindowIsSeen() {
        assertEquals(true, KeyboardAi.focusedWindowSecure("$dump\n  mCurrentFocus=Window{bb22 u0 com.bank/com.bank.Login}"))
    }

    @Test fun focusedPlainWindowIsNotSecure() {
        // pfl=SECURE (a private flag) and SECURE on another window don't count.
        assertEquals(false, KeyboardAi.focusedWindowSecure("$dump\n  mCurrentFocus=Window{cc33 u0 com.whatsapp/com.whatsapp.Conversation}"))
    }

    @Test fun noFocusIsUnknown() {
        assertNull(KeyboardAi.focusedWindowSecure(dump))
    }

    @Test fun blackedOutCaptureIsRefused() {
        assertTrue(KeyboardAi.blackedOut(IntArray(100) { 0xff000000.toInt() }))
        assertTrue(KeyboardAi.blackedOut(IntArray(0)))
        assertFalse(KeyboardAi.blackedOut(IntArray(100) { if (it < 10) 0xffffffff.toInt() else 0xff000000.toInt() }))
    }

    @Test fun cropKeepsWhatIsAboveTheKeyboard() {
        assertEquals(1500, KeyboardAi.cropBottom(2400, 1500, 2400))
        assertEquals(500, KeyboardAi.cropBottom(800, 1500, 2400)) // live mode's third
        assertEquals(2400, KeyboardAi.cropBottom(2400, 0, 2400))
        assertEquals(2400, KeyboardAi.cropBottom(2400, 2600, 2400))
    }

    @Test fun guestRequestIsContractV1() {
        val ask =
            JSONObject()
                .put("shot", "s1")
                .put("transcript", "say I'm late")
                .put("text", "x".repeat(5000))
                .put("app", "com.whatsapp")
                .put("hint", "Message")
                .put("inputType", 0x20041)
                .put("n", 9)
                .put("avoid", JSONArray().put("On my way").put(" "))
        val r = KeyboardAi.guestRequest(ask, "aGk=")
        assertEquals(1, r.getInt("v"))
        assertEquals("aGk=", r.getString("image"))
        assertEquals("image/jpeg", r.getString("mime"))
        assertEquals(2000, r.getString("text").length)
        assertEquals(5, r.getInt("n"))
        assertEquals(1, r.getJSONArray("avoid").length())
        assertFalse(r.has("shot"))
    }

    @Test fun guestAnswerParsing() {
        val ok = KeyboardAi.guestAnswer("noise\n{\"ok\": true, \"variations\": [\"a\", \"b\"], \"model\": \"m\"}\n", 0)
        assertTrue(ok.getBoolean("ok"))
        assertEquals(2, ok.getJSONArray("variations").length())
        assertEquals("signin", KeyboardAi.guestAnswer("{\"ok\": false, \"error\": \"signin\", \"why\": \"x\"}", 4).getString("error"))
        assertEquals("model", KeyboardAi.guestAnswer("Traceback ...", 1).getString("error"))
        assertEquals("no-reply", KeyboardAi.guestAnswer("{\"ok\": true, \"variations\": []}", 0).getString("error"))
    }

    @Test fun shotsLiveInMemoryForTheirTtl() {
        var t = 1_000L
        val shots = KeyboardAi.Shots { t }
        val id = shots.put(byteArrayOf(1, 2))
        assertEquals(2, shots.get(id)!!.size)
        t += KeyboardAi.SHOT_TTL_MS + 1
        assertNull(shots.get(id))
        val id2 = shots.put(byteArrayOf(3))
        shots.drop(id2)
        assertEquals(0, shots.size())
    }
}
