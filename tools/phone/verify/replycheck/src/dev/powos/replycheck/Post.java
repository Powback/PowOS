package dev.powos.replycheck;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Person;
import android.app.RemoteInput;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

/**
 * am broadcast -n dev.powos.replycheck/.Post -a dev.powos.replycheck.POST --es token T: posts "Reply check T" as a
 * MessagingStyle notification with one Reply action (RemoteInput "reply", SEMANTIC_ACTION_REPLY) - what Discord,
 * WhatsApp and Gmail post. Its reply goes to Reply (this app only).
 */
public class Post extends BroadcastReceiver {
    static final String TAG = "PowosReplyCheck";
    static final String CHANNEL = "reply-check";
    static final int ID = 0x4e4d;

    @Override
    public void onReceive(Context c, Intent in) {
        String token = in.getStringExtra("token");
        if (token == null || token.isEmpty()) token = "t";
        NotificationManager nm = c.getSystemService(NotificationManager.class);
        nm.createNotificationChannel(new NotificationChannel(CHANNEL, "Reply check", NotificationManager.IMPORTANCE_LOW));
        Intent target = new Intent(c, Reply.class).setAction("dev.powos.replycheck.REPLY").putExtra("token", token);
        PendingIntent pi = PendingIntent.getBroadcast(c, 1, target, PendingIntent.FLAG_MUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        RemoteInput input = new RemoteInput.Builder(Reply.KEY).setLabel("Reply").build();
        Notification.Action reply = new Notification.Action.Builder(null, "Reply", pi)
            .addRemoteInput(input)
            .setSemanticAction(Notification.Action.SEMANTIC_ACTION_REPLY)
            .build();
        Person who = new Person.Builder().setName("Reply check " + token).setKey("replycheck-" + token).build();
        Person me = new Person.Builder().setName("Me").build();
        Notification n = new Notification.Builder(c, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_dialog_email)
            .setContentTitle("Reply check " + token)
            .setContentText("type anything and send")
            .setStyle(new Notification.MessagingStyle(me).addMessage("type anything and send", System.currentTimeMillis(), who))
            .addAction(reply)
            .build();
        nm.notify(ID, n);
        Log.i(TAG, "posted " + token);
    }
}
