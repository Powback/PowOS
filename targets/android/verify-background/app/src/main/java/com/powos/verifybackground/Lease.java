package com.powos.verifybackground;

/** No extension or adoption: a second start cannot replace even its own live nonce. */
public final class Lease {
    public static final long TTL_MS = 90_000;
    private String nonce;
    private long deadline;
    public boolean start(String candidate, long now) {
        if (nonce != null || candidate == null || !candidate.matches("[a-f0-9]{32}")) return false;
        nonce = candidate;
        deadline = now + TTL_MS;
        return true;
    }
    public boolean expired(long now) { return nonce != null && now >= deadline; }
    public String nonce() { return nonce; }
    public long deadline() { return deadline; }
}
