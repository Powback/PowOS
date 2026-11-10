package com.powos.verifybackground;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;

public final class StartActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        String nonce = getIntent().getStringExtra("nonce");
        if (nonce != null && nonce.matches("[a-f0-9]{32}")) {
            startForegroundService(new Intent(this, WorkService.class).putExtra("nonce", nonce));
        }
        finishAndRemoveTask();
    }
}
