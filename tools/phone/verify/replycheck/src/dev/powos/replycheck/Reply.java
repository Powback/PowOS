package dev.powos.replycheck;

import android.app.NotificationManager;
import android.app.RemoteInput;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.Bundle;
import android.util.Log;
import java.io.File;
import java.io.FileOutputStream;

/**
 * What the Reply action received: "<token>\t<text>" in files/last-reply (the check reads it as root) and logcat
 * (PowosReplyCheck), then the notification is cancelled, as an app does once a reply is in.
 */
public class Reply extends BroadcastReceiver {
    static final String KEY = "reply";

    @Override
    public void onReceive(Context c, Intent in) {
        Bundle r = RemoteInput.getResultsFromIntent(in);
        CharSequence text = r == null ? null : r.getCharSequence(KEY);
        String token = in.getStringExtra("token");
        String line = token + "\t" + (text == null ? "" : text.toString().replace('\n', ' '));
        try {
            FileOutputStream o = new FileOutputStream(new File(c.getFilesDir(), "last-reply"));
            o.write(line.getBytes("UTF-8"));
            o.close();
        } catch (Exception e) {
            Log.w(Post.TAG, "can't keep the reply", e);
        }
        Log.i(Post.TAG, "reply " + line);
        c.getSystemService(NotificationManager.class).cancel(Post.ID);
    }
}
