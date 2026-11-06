package andro.marchy;

/**
 * PowOS: when a Linux web window's keyboard ask (KWin's OUTPUT_TYPE_KEYBOARD show, kwin 0012/0043) raises Android's
 * keyboard. A show is the user's only right after they touched that window: opening System Settings focused its search
 * field and KWin asked at once (Qt enables text input on the focus), so the keyboard came up over a window nobody had
 * tapped yet (11-04 emulator, no root; the rooted path is the same consumer). An ask with no touch behind it is kept; the
 * user's next tap in that window raises it (the field had the focus already, so KWin asks nothing new), a hide drops it.
 * While KWin's ask stands, every tap raises it again (the user put it away with Android's back: KWin still counts it up).
 * PowOS's own text fields keep showing it on their tap: this only gates asks that no touch came before.
 *
 * HACK: "a tap in the window" stands in for "a tap on the text field" - with a field focused, a tap anywhere else in that
 * window that leaves the focus there raises the keyboard too. Real fix: KWin sends the field's text-input cursor
 * rectangle with the ask (kwin anland backend) and only a tap inside it counts. docs/REMOTE-POWOS.md S4.
 *
 * Only with a KWin that moves a keyboard asked for before the window went live to its consumer (cap "keyboard-live",
 * kwin 0054): an older one never asks again, so holding its ask would leave a tap raising nothing - there every ask
 * raises the keyboard at once, as before.
 *
 * A game's window never raises it on KWin's ask or on a touch ([setGame]): Wine/Proton and Unity keep text input
 * enabled on the focused game window for its whole life, so KWin's ask stands from the first frame and every touch on
 * the game raised the keyboard (11-06 Broforce on the unfolded screen: "the keyboard opens any time I touch the game").
 * Steam, apps and PowOS's own fields are not games and keep the behaviour above.
 *
 * Plain state, no Android: WebWindowSource keeps one per window consumer, on the main thread.
 */
public final class TapKeyboard {
    /** A show this soon after a touch down in the window is that touch's (KWin's ask follows the focus change). */
    public static final long TOUCH_ASK_MS = 1000;
    /** A tap: up this soon after its down ... */
    public static final long TAP_MS = 600;
    /** ... and this close to it (window px). */
    public static final float TAP_SLOP = 32f;

    /** KWin has "keyboard-live": asks are held for a tap. Without it, the old behaviour (every ask raises it). */
    private final boolean gate;
    private long downAt = Long.MIN_VALUE / 2;
    private float downX, downY;
    private boolean pending;
    /** KWin's keyboard is asked for (show .. hide): a tap raises it, also after the user put it away. */
    private boolean asked;
    /** The window is a game's ([setGame]): no ask or touch of it raises the keyboard. */
    private volatile boolean game;

    /** KWin asked for the keyboard at [now] (uptime ms): true = raise it now; false = held for the next tap. */
    public TapKeyboard(boolean gate) {
        this.gate = gate;
    }

    /** The window is a game's (WebWindows.isGame): from now on KWin's asks and the user's touches on it raise nothing. */
    public void setGame(boolean game) {
        this.game = game;
        if (game)
            pending = false;
    }

    public boolean show(long now) {
        if (game) {
            asked = true;
            pending = false;
            return false;
        }
        if (!gate)
            return true;
        asked = true;
        if (now - downAt <= TOUCH_ASK_MS) {
            pending = false;
            return true;
        }
        pending = true;
        return false;
    }

    /** KWin hid it (the field lost the focus): a held ask goes. */
    public void hide() {
        pending = false;
        asked = false;
    }

    public void down(long now, float x, float y) {
        downAt = now;
        downX = x;
        downY = y;
    }

    /** The touch ended: true when it was a tap and KWin's ask stands - raise the keyboard (unless a hide comes first). */
    public boolean up(long now, float x, float y) {
        if (!gate || game)
            return false;
        boolean tap = now - downAt <= TAP_MS && Math.abs(x - downX) <= TAP_SLOP && Math.abs(y - downY) <= TAP_SLOP;
        if (tap && asked)
            pending = true;
        return tap && asked;
    }

    /** The tap's raise is still wanted (its delayed raise checks it: KWin's hide for a focus the tap moved wins). */
    public boolean held() {
        return pending && asked && !game;
    }

    /** The delayed raise happened. */
    public void shown() {
        pending = false;
    }
}
