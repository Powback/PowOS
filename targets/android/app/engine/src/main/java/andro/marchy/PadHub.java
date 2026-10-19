package andro.marchy;

import android.content.Context;

/**
 * The one connection to powos-padd (the virtual controller in PowOS), shared by every control surface in the app:
 * the on-screen overlay (GamepadOverlay) and the cover screen (CoverPadActivity). The daemon takes one client, and
 * the surfaces must not undo each other: each owns its own buttons, combined on the way out, so hiding the overlay
 * releases only what the overlay held. Analog values (sticks, triggers) come from the overlay.
 */
final class PadHub {

    static final int OVERLAY = 0, COVER = 1;

    /** Deck-only button bits (powos-padd PAD2), after PadSender's 0..14. */
    static final int L4 = 1 << 15, L5 = 1 << 16, R4 = 1 << 17, R5 = 1 << 18, QUICK_ACCESS = 1 << 19;

    /**
     * powos-padd's socket, in the abstract namespace (no file, SessionService.DISPLAY_SOCKET says why); the same name
     * as SOCK in targets/android/session/powos-padd. padd is root, so the peer check is root's uid.
     */
    static final String PADD_SOCKET = "@powos.padd";

    private static PadHub instance;

    static synchronized PadHub get(Context ctx) {
        if (instance == null) {
            instance = new PadHub(PADD_SOCKET);
        }
        return instance;
    }

    private final PadSender sender;
    private final int[] buttons = new int[2];
    private float lx, ly, rx, ry, lt, rt;

    private PadHub(String socket) {
        sender = new PadSender(socket);
        sender.start();
    }

    synchronized void setButtons(int source, int bits) {
        if (buttons[source] == bits) return;
        buttons[source] = bits;
        send();
    }

    synchronized void setAnalog(float lx, float ly, float rx, float ry, float lt, float rt) {
        this.lx = lx;
        this.ly = ly;
        this.rx = rx;
        this.ry = ry;
        this.lt = lt;
        this.rt = rt;
        send();
    }

    /** The overlay's whole state (buttons + analog) in one packet. */
    synchronized void setOverlay(int bits, float lx, float ly, float rx, float ry, float lt, float rt) {
        buttons[OVERLAY] = bits;
        this.lx = lx;
        this.ly = ly;
        this.rx = rx;
        this.ry = ry;
        this.lt = lt;
        this.rt = rt;
        send();
    }

    private void send() {
        sender.post(buttons[OVERLAY] | buttons[COVER], lx, ly, rx, ry, lt, rt);
    }
}
