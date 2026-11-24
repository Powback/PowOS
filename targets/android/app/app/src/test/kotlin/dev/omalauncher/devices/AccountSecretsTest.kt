package dev.omalauncher.devices

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test

class AccountSecretsTest {
    @Test
    fun outcomes() {
        assertEquals(AccountSecrets.Got.Value("k"), AccountSecrets.outcome(200, JSONObject().put("value", "k")))
        assertEquals(AccountSecrets.Got.None, AccountSecrets.outcome(404, JSONObject()))
        // A revoked device: what it took from the account goes.
        assertEquals(AccountSecrets.Got.Revoked, AccountSecrets.outcome(401, JSONObject()))
        // Anything else (5xx, an empty answer) keeps the device's copy.
        assertEquals(AccountSecrets.Got.Unknown, AccountSecrets.outcome(503, JSONObject()))
        assertEquals(AccountSecrets.Got.Unknown, AccountSecrets.outcome(200, JSONObject()))
    }
}
