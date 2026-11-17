package andro.marchy.stream;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URI;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import javax.net.ssl.HttpsURLConnection;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Acquires one B0 bootstrap ({@code GET /b0/session.json}, PowStream {@code powstream-webrtc-server}) over HTTPS that
 * the PLATFORM trusts: no custom TrustManager, HostnameVerifier or pin override, no redirects, no cache. The response's
 * certificate hash is trusted only because it arrived over that verified channel; the WebTransport endpoint is always
 * built from the verified origin host, never from the body.
 *
 * <p>The credential and the returned token are transient: never logged, persisted or put in exception text. Server
 * tokens are single-connect and short-lived (120 s at the pinned revision); use {@link Bootstrap#fresh} and fetch a new
 * one for every receiver open. The server-side contract and what is still missing is in docs/REMOTE-WINDOWS.md
 * ("Bootstrap contract").
 */
public final class PowStreamBootstrap {
    public static final String PATH = "/b0/session.json";
    /** Server TTL is 120 s; leave the handshake (10 s in the core) plenty of room. */
    public static final long FRESH_MS = 60_000;
    static final int MAX_BODY = 8 * 1024;
    private PowStreamBootstrap() {}

    /** Why acquisition failed. Messages are fixed strings: safe to show in the window's error state. */
    public static final class Failure extends Exception {
        public enum Kind { UNTRUSTED, UNAUTHORIZED, DISABLED, UNREACHABLE, INVALID }
        public final Kind kind;
        Failure(Kind kind, String message) { super(message, null, false, false); this.kind = kind; }
    }

    /** How the caller proves it may stream. The value is borrowed for one request and never kept. */
    public static final class Credential {
        final String header;
        final String value;
        private Credential(String header, String value) { this.header = header; this.value = value; }
        /** Today's server: the signed {@code powstream_session} cookie its own {@code /api/login} sets. */
        public static Credential sessionCookie(String signed) {
            if (signed == null || signed.isEmpty() || signed.length() > 1024 || !tokenAlphabet(signed))
                throw new IllegalArgumentException("Invalid session credential");
            return new Credential("Cookie", "powstream_session=" + signed);
        }
        @Override public String toString() { return "Credential(" + header + ", redacted)"; }
    }

    /** One authenticated bootstrap. {@link #close} wipes the pin copy; the token String is dropped with it. */
    public static final class Bootstrap implements AutoCloseable {
        public final String endpoint;
        private final String token;
        private final byte[] certSha256;
        public final long fetchedAtMs;
        Bootstrap(String endpoint, String token, byte[] certSha256, long fetchedAtMs) {
            this.endpoint = endpoint; this.token = token; this.certSha256 = certSha256; this.fetchedAtMs = fetchedAtMs;
        }
        public boolean fresh(long nowMs) { return nowMs >= fetchedAtMs && nowMs - fetchedAtMs < FRESH_MS; }
        public String token() { return token; }
        public byte[] certSha256() { return certSha256.clone(); }
        @Override public void close() { Arrays.fill(certSha256, (byte) 0); }
        @Override public String toString() { return "Bootstrap(" + endpoint + ", token redacted)"; }
    }

    /**
     * Validates the origin a remote window may bootstrap from: {@code https://host[:port]} only (no user info, path,
     * query or fragment), so the verified TLS identity and the WebTransport host are the same name.
     */
    public static URI origin(String origin) throws Failure {
        try {
            URI u = new URI(origin);
            if (!"https".equals(u.getScheme()) || u.getHost() == null || u.getRawUserInfo() != null
                    || (u.getRawPath() != null && !u.getRawPath().isEmpty() && !"/".equals(u.getRawPath()))
                    || u.getRawQuery() != null || u.getRawFragment() != null)
                throw new Failure(Failure.Kind.INVALID, "Stream source must be an https:// origin");
            return u;
        } catch (java.net.URISyntaxException e) {
            throw new Failure(Failure.Kind.INVALID, "Stream source must be an https:// origin");
        }
    }

    /** Blocking; call OFF the UI thread. */
    public static Bootstrap fetch(String originText, Credential credential, int timeoutMs) throws Failure {
        URI origin = origin(originText);
        if (credential == null) throw new Failure(Failure.Kind.UNAUTHORIZED, "Sign in to the stream source first");
        HttpsURLConnection c = null;
        try {
            URL url = new URL("https", origin.getHost(), origin.getPort(), PATH);
            c = (HttpsURLConnection) url.openConnection(); // platform trust + hostname verification, unmodified
            c.setInstanceFollowRedirects(false);
            c.setUseCaches(false);
            c.setConnectTimeout(timeoutMs);
            c.setReadTimeout(timeoutMs);
            c.setRequestProperty("Accept", "application/json");
            c.setRequestProperty(credential.header, credential.value);
            int status = c.getResponseCode();
            if (status == HttpURLConnection.HTTP_UNAUTHORIZED || status == HttpURLConnection.HTTP_FORBIDDEN)
                throw new Failure(Failure.Kind.UNAUTHORIZED, "Stream source refused the sign-in; sign in again");
            if (status != HttpURLConnection.HTTP_OK)
                throw new Failure(Failure.Kind.UNREACHABLE, "Stream source answered HTTP " + status);
            String body;
            try (InputStream in = c.getInputStream()) { body = readBounded(in); }
            return parse(body, origin.getHost(), System.currentTimeMillis());
        } catch (javax.net.ssl.SSLException e) {
            throw new Failure(Failure.Kind.UNTRUSTED, "Stream source's HTTPS certificate is not trusted");
        } catch (IOException e) {
            throw new Failure(Failure.Kind.UNREACHABLE, "Stream source unreachable");
        } finally {
            if (c != null) c.disconnect();
        }
    }

    static String readBounded(InputStream in) throws IOException, Failure {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buf = new byte[1024];
        for (int n; (n = in.read(buf)) > 0; ) {
            if (out.size() + n > MAX_BODY) throw new Failure(Failure.Kind.INVALID, "Bootstrap response too large");
            out.write(buf, 0, n);
        }
        return new String(out.toByteArray(), StandardCharsets.UTF_8);
    }

    /** Parses the pinned server's body: {@code {"certHashHex","wtPort","path":"/b0","token"}} or {@code {"error"}}. */
    static Bootstrap parse(String body, String trustedHost, long nowMs) throws Failure {
        try {
            JSONObject o = new JSONObject(body);
            if (o.has("error")) throw new Failure(Failure.Kind.DISABLED, "B0 streaming is disabled on the source");
            String hash = o.getString("certHashHex");
            int port = o.getInt("wtPort");
            String path = o.getString("path");
            String token = o.getString("token");
            if (!"/b0".equals(path) || port < 1 || port > 65535)
                throw new Failure(Failure.Kind.INVALID, "Bootstrap names an unexpected endpoint");
            if (token.isEmpty() || token.length() > 4096 || !tokenAlphabet(token))
                throw new Failure(Failure.Kind.INVALID, "Bootstrap token malformed");
            byte[] pin = hex32(hash);
            String host = trustedHost.indexOf(':') >= 0 && !trustedHost.startsWith("[") ? "[" + trustedHost + "]" : trustedHost;
            return new Bootstrap("https://" + host + ":" + port + "/b0", token, pin, nowMs);
        } catch (JSONException e) {
            throw new Failure(Failure.Kind.INVALID, "Bootstrap response malformed");
        }
    }

    /** The core's accepted token alphabet (powstream-client-core bootstrap_url): ASCII alphanumerics and ':'. */
    static boolean tokenAlphabet(String s) {
        for (int i = 0; i < s.length(); i++) {
            char ch = s.charAt(i);
            if (!((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == ':')) return false;
        }
        return true;
    }

    static byte[] hex32(String hex) throws Failure {
        if (hex.length() != 64) throw new Failure(Failure.Kind.INVALID, "Bootstrap certificate hash malformed");
        byte[] out = new byte[32];
        for (int i = 0; i < 32; i++) {
            int hi = Character.digit(hex.charAt(2 * i), 16), lo = Character.digit(hex.charAt(2 * i + 1), 16);
            if (hi < 0 || lo < 0) {
                Arrays.fill(out, (byte) 0);
                throw new Failure(Failure.Kind.INVALID, "Bootstrap certificate hash malformed");
            }
            out[i] = (byte) ((hi << 4) | lo);
        }
        return out;
    }
}
