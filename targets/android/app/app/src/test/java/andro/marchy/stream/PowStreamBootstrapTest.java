package andro.marchy.stream;

import org.junit.Test;
import java.net.ServerSocket;
import static org.junit.Assert.*;

/** The production bootstrap parser/validator against the pinned server's real body shape (b0.rs session_json). */
public class PowStreamBootstrapTest {
    private static final String HASH = "00112233445566778899aabbccddeeff00112233445566778899AABBCCDDEEFF";
    private static final String TOKEN = "b0:1763500000:0a1b2c3d";
    private static String body(String hash, int port, String path, String token) {
        return "{\"certHashHex\":\"" + hash + "\",\"wtPort\":" + port + ",\"path\":\"" + path + "\",\"token\":\"" + token + "\"}";
    }
    private static PowStreamBootstrap.Failure.Kind kindOf(ThrowingRunnable r) {
        try { r.run(); } catch (PowStreamBootstrap.Failure f) { return f.kind; }
        fail("expected Failure"); return null;
    }
    interface ThrowingRunnable { void run() throws PowStreamBootstrap.Failure; }

    @Test public void endpointComesFromTheVerifiedOriginNotTheBody() throws Exception {
        try (PowStreamBootstrap.Bootstrap b = PowStreamBootstrap.parse(body(HASH, 47800, "/b0", TOKEN), "desk.example", 1000)) {
            assertEquals("https://desk.example:47800/b0", b.endpoint);
            assertEquals(TOKEN, b.token());
            byte[] pin = b.certSha256();
            assertEquals(32, pin.length);
            assertEquals((byte) 0x00, pin[0]);
            assertEquals((byte) 0xff, pin[31]);
            assertFalse(b.toString().contains(TOKEN));
            assertTrue(b.fresh(1000 + PowStreamBootstrap.FRESH_MS - 1));
            assertFalse(b.fresh(1000 + PowStreamBootstrap.FRESH_MS));
            assertFalse(b.fresh(999)); // clock went backwards: refetch
        }
    }

    @Test public void ipv6OriginIsBracketed() throws Exception {
        assertEquals("https://[fd00::1]:47800/b0",
                PowStreamBootstrap.parse(body(HASH, 47800, "/b0", TOKEN), "[fd00::1]", 0).endpoint);
    }

    @Test public void closeWipesThePin() throws Exception {
        PowStreamBootstrap.Bootstrap b = PowStreamBootstrap.parse(body(HASH, 47800, "/b0", TOKEN), "h", 0);
        b.close();
        assertArrayEquals(new byte[32], b.certSha256());
    }

    @Test public void rejectsWhatTheCoreWouldRefuseOrThatCouldRedirectTheConnect() {
        assertEquals(PowStreamBootstrap.Failure.Kind.INVALID, kindOf(() -> PowStreamBootstrap.parse(body(HASH, 47800, "/other", TOKEN), "h", 0)));
        assertEquals(PowStreamBootstrap.Failure.Kind.INVALID, kindOf(() -> PowStreamBootstrap.parse(body(HASH, 0, "/b0", TOKEN), "h", 0)));
        assertEquals(PowStreamBootstrap.Failure.Kind.INVALID, kindOf(() -> PowStreamBootstrap.parse(body(HASH, 70000, "/b0", TOKEN), "h", 0)));
        assertEquals(PowStreamBootstrap.Failure.Kind.INVALID, kindOf(() -> PowStreamBootstrap.parse(body(HASH.substring(2), 47800, "/b0", TOKEN), "h", 0)));
        assertEquals(PowStreamBootstrap.Failure.Kind.INVALID, kindOf(() -> PowStreamBootstrap.parse(body(HASH.replace('a', 'g'), 47800, "/b0", TOKEN), "h", 0)));
        assertEquals(PowStreamBootstrap.Failure.Kind.INVALID, kindOf(() -> PowStreamBootstrap.parse(body(HASH, 47800, "/b0", "b0:1&vw=1"), "h", 0)));
        assertEquals(PowStreamBootstrap.Failure.Kind.INVALID, kindOf(() -> PowStreamBootstrap.parse(body(HASH, 47800, "/b0", ""), "h", 0)));
        assertEquals(PowStreamBootstrap.Failure.Kind.INVALID, kindOf(() -> PowStreamBootstrap.parse("not json", "h", 0)));
        assertEquals(PowStreamBootstrap.Failure.Kind.DISABLED,
                kindOf(() -> PowStreamBootstrap.parse("{\"error\":\"B0 is disabled on this server\"}", "h", 0)));
    }

    @Test public void failureTextNeverCarriesSecrets() {
        try { PowStreamBootstrap.parse(body(HASH, 47800, "/b0", "secret&x"), "h", 0); fail(); }
        catch (PowStreamBootstrap.Failure f) { assertFalse(f.getMessage().contains("secret")); }
        PowStreamBootstrap.Credential c = PowStreamBootstrap.Credential.sessionCookie("pow:1763500000:abcdef");
        assertFalse(c.toString().contains("abcdef"));
    }

    @Test public void originMustBeABareHttpsOrigin() throws Exception {
        assertEquals("desk.example", PowStreamBootstrap.origin("https://desk.example:8090").getHost());
        assertEquals("desk.example", PowStreamBootstrap.origin("https://desk.example/").getHost());
        for (String bad : new String[] {"http://desk.example:8090", "https://u:p@desk.example", "https://desk.example/b0",
                "https://desk.example/?x=1", "https://desk.example/#f", "desk.example", "https://"})
            assertEquals(bad, PowStreamBootstrap.Failure.Kind.INVALID, kindOf(() -> PowStreamBootstrap.origin(bad)));
    }

    @Test public void credentialRejectsHeaderInjection() {
        for (String bad : new String[] {"", "a\r\nX-Evil: 1", "a; other=1", "a b"}) {
            try { PowStreamBootstrap.Credential.sessionCookie(bad); fail(bad); }
            catch (IllegalArgumentException expected) {}
        }
    }

    @Test public void closedPortIsUnreachableNotATrustBypass() throws Exception {
        int port;
        try (ServerSocket s = new ServerSocket(0)) { port = s.getLocalPort(); }
        PowStreamBootstrap.Credential c = PowStreamBootstrap.Credential.sessionCookie("pow:1:ab");
        final int p = port;
        assertEquals(PowStreamBootstrap.Failure.Kind.UNREACHABLE,
                kindOf(() -> PowStreamBootstrap.fetch("https://127.0.0.1:" + p, c, 2000)));
        assertEquals(PowStreamBootstrap.Failure.Kind.UNAUTHORIZED,
                kindOf(() -> PowStreamBootstrap.fetch("https://127.0.0.1:" + p, null, 2000)));
    }
}
