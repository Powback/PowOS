package com.powos.verifybackground;

import android.app.*;
import android.content.Intent;
import android.os.*;
import java.io.*;
import java.nio.charset.StandardCharsets;

/** A real local workload: writes a private heartbeat, bounded by elapsed time, never sticky. */
public final class WorkService extends Service {
    private final Lease lease = new Lease();
    private final Handler handler = new Handler(Looper.getMainLooper());
    private int ticks;
    private File stateFile() { return new File(getFilesDir(), "run"); }
    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        String nonce = intent == null ? null : intent.getStringExtra("nonce");
        if (!lease.start(nonce, SystemClock.elapsedRealtime())) {
            if (lease.nonce() == null) stopSelf();
            return START_NOT_STICKY;
        }
        NotificationManager manager = getSystemService(NotificationManager.class);
        manager.createNotificationChannel(new NotificationChannel("check", "Background verification", NotificationManager.IMPORTANCE_LOW));
        startForeground(1, new Notification.Builder(this, "check")
            .setSmallIcon(android.R.drawable.ic_menu_info_details).setContentTitle("PowOS background check")
            .setContentText("Expires in 90 seconds; no user data").build());
        heartbeat();
        return START_NOT_STICKY;
    }
    private void heartbeat() {
        if (lease.expired(SystemClock.elapsedRealtime())) { stopSelf(); return; }
        try (FileOutputStream out = new FileOutputStream(stateFile())) {
            String state = lease.nonce() + " " + Process.myPid() + " " + lease.deadline() + " " + (++ticks) + "\n";
            out.write(state.getBytes(StandardCharsets.UTF_8));
        } catch (IOException failure) { stopSelf(); return; }
        handler.postDelayed(this::heartbeat, 1000);
    }
    @Override public void onDestroy() {
        handler.removeCallbacksAndMessages(null);
        stateFile().delete();
        super.onDestroy();
    }
    @Override public IBinder onBind(Intent intent) { return null; }
}
