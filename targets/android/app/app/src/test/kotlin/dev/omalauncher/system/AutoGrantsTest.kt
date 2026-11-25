package dev.omalauncher.system

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** What PowOS grants an app it installs itself (rooted): only its allowlist, only what the app declares, only what's missing. */
class AutoGrantsTest {
    private val mic = "android.permission.RECORD_AUDIO"

    @Test
    fun theKeyboardGetsItsMic() {
        assertEquals(listOf(mic), AutoGrants.toGrant(DefaultKeyboard.PACKAGE, listOf("android.permission.INTERNET", mic)) { false })
    }

    @Test
    fun nothingAlreadyHeldUndeclaredOrUnlisted() {
        assertEquals(emptyList<String>(), AutoGrants.toGrant(DefaultKeyboard.PACKAGE, listOf(mic)) { it == mic })
        assertEquals("not declared by the app", emptyList<String>(), AutoGrants.toGrant(DefaultKeyboard.PACKAGE, listOf("android.permission.INTERNET")) { false })
        assertEquals("not on the allowlist", emptyList<String>(), AutoGrants.toGrant("com.example.other", listOf(mic)) { false })
    }

    @Test
    fun theAllowlistGrantsOnlyRuntimeMediaPermissions() {
        // A guard on what the list may hold: no settings/special access slips in through it.
        val ok = setOf(mic, "android.permission.CAMERA", "android.permission.ACCESS_FINE_LOCATION", "android.permission.ACCESS_COARSE_LOCATION", "android.permission.POST_NOTIFICATIONS")
        for ((pkg, perms) in AutoGrants.ALLOWLIST) for (p in perms) assertTrue("$pkg: $p", p in ok)
    }
}
