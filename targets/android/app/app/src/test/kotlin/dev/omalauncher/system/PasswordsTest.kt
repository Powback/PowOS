package dev.omalauncher.system

import dev.omalauncher.system.Passwords.State
import org.junit.Assert.assertEquals
import org.junit.Test

/** The passwords tile (Passwords.kt): PowPass missing, installed but not the phone's provider, or filling. */
class PasswordsTest {
    @Test fun missingWhenNotInstalled() {
        assertEquals(State.MISSING, Passwords.state(false, "pow.powpass/.autofill.PowPassAutofillService", null))
    }

    @Test fun onWhenPickedForAutofillOrCredentials() {
        assertEquals(State.ON, Passwords.state(true, "pow.powpass/pow.powpass.autofill.PowPassAutofillService", ""))
        assertEquals(State.ON, Passwords.state(true, "com.google.android.gms/x", "com.google.android.gms/y:pow.powpass/z"))
    }

    @Test fun notPickedWhenAnotherProviderFills() {
        assertEquals(State.NOT_PICKED, Passwords.state(true, "com.google.android.gms/.autofill.AutofillService", ""))
        assertEquals(State.NOT_PICKED, Passwords.state(true, "", ""))
        // A look-alike package is not PowPass.
        assertEquals(State.NOT_PICKED, Passwords.state(true, "pow.powpass.evil/x", null))
    }

    @Test fun unknownWhenAndroidHidesTheSettings() {
        assertEquals(State.UNKNOWN, Passwords.state(true, null, null))
    }
}
