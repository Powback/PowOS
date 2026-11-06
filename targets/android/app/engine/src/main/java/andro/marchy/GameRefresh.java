package andro.marchy;

import java.util.function.Predicate;

/**
 * The display mode a window task asks for (PowosWindowActivity.gameRefresh): a game's, while its task is the top one,
 * asks for its screen's fastest mode at the screen's current resolution; anything else asks for none (0: the system's
 * choice). Pure, so the JVM tests drive it.
 */
public final class GameRefresh {
    private GameRefresh() {}

    /**
     * The mode id to ask for. [front]: the task is the top resumed one; [app]: its app id; [isGame]: which app ids are
     * games (null: not known yet); the screen's modes as parallel arrays [ids], [widths], [heights], [hz] and its current
     * physical size [curW] x [curH].
     */
    public static int wanted(boolean front, String app, Predicate<String> isGame, int[] ids, int[] widths, int[] heights,
                      float[] hz, int curW, int curH) {
        if (!front || app == null || app.isEmpty() || isGame == null || !isGame.test(app))
            return 0;
        int best = -1;
        for (int i = 0; i < ids.length; i++)
            if (widths[i] == curW && heights[i] == curH && (best < 0 || hz[i] > hz[best]))
                best = i;
        return best < 0 ? 0 : ids[best];
    }

    /**
     * The frame rate a game's window surface votes for (PowosWindowActivity.surfaceVote): the rate of the mode
     * [wanted] picked ([want], from [ids] / [hz]), 0 (no vote) when none is wanted or the id is not among them.
     */
    public static float rate(int want, int[] ids, float[] hz) {
        if (want == 0)
            return 0f;
        for (int i = 0; i < ids.length; i++)
            if (ids[i] == want)
                return hz[i];
        return 0f;
    }
}
