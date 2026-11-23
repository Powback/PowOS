package dev.omalauncher.devices

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Pow account sign-in's pure parts (PowAccount.kt): PKCE S256, the authorize URL, the loopback callback's query. */
class PowAccountTest {
    @Test fun pkceS256IsRfc7636sExample() {
        assertEquals(
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
            PowAccount.challengeOf("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
        )
    }

    @Test fun theAuthorizeUrlAsksForCodeWithPkceToTheLoopback() {
        val u = PowAccount.authorizeUrl("https://auth.powback.com/api/oidc/authorization", "powos-device",
            "http://127.0.0.1:43123/callback", "openid profile groups", "st", "ch")
        assertTrue(u.startsWith("https://auth.powback.com/api/oidc/authorization?response_type=code&client_id=powos-device&"))
        assertTrue("redirect_uri=http%3A%2F%2F127.0.0.1%3A43123%2Fcallback" in u)
        assertTrue("scope=openid+profile+groups" in u && "code_challenge=ch" in u && "code_challenge_method=S256" in u)
    }

    @Test fun theCallbackQueryIsDecoded() {
        assertEquals(mapOf("code" to "a b", "state" to "x/y"), PowAccount.queryOf("code=a+b&state=x%2Fy"))
        assertEquals(mapOf("error" to "access_denied"), PowAccount.queryOf("error=access_denied&junk"))
    }
}
