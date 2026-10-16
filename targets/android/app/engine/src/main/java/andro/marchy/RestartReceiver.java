package andro.marchy;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

/**
 * Rooted mode: the PowOS session (and with it the fold handling, the launcher's terminals) comes back on its own
 * after the phone boots and after an app update - an update ends the app's process, and until the desktop was opened
 * again folding did nothing special and a terminal tile found no session.
 */
public final class RestartReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context ctx, Intent intent) {
        if (!RootMode.enabled())
            return;
        Log.i("RestartReceiver", intent.getAction() + ": starting the PowOS session");
        SessionService.start(ctx);
    }
}
