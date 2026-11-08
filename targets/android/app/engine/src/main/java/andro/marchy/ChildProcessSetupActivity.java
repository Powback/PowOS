package andro.marchy;

import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Intent;
import android.os.Build;
import android.os.Bundle;
import android.provider.Settings;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

/**
 * The one-time setup step for Android 12+'s child process limit (PhantomLimit): what to turn off and where - the
 * Developer options switch on Android 14+ (a button opens Developer options, or About phone while they are hidden),
 * the adb commands on 12-13, selectable and with a Copy button. Opened from SessionService's notification when the
 * session saw Android kill its processes or the guest is at the limit.
 */
public class ChildProcessSetupActivity extends Activity {
    static final String EXTRA_KILLED = "killed";
    static final String EXTRA_PROCESSES = "processes";
    /** Shown before the session's first start (MainActivity): the session waits for it (SetupGate). */
    static final String EXTRA_BEFORE_START = "before_start";
    static final String GATE = "child-processes";

    /** This phone still has the limit on (PhantomLimit.fix). */
    static boolean needed(android.content.Context ctx) {
        return PhantomLimit.fix(Build.VERSION.SDK_INT,
                Settings.Global.getString(ctx.getContentResolver(), PhantomLimit.MONITOR_SETTING)) != PhantomLimit.Fix.NONE;
    }

    @Override
    protected void onResume() {
        super.onResume();
        // Back from Developer options with the restriction off: nothing left to do here, the desktop can start.
        if (getIntent().getBooleanExtra(EXTRA_BEFORE_START, false) && !needed(this))
            finish();
    }

    // Ended in onPause (before MainActivity resumes and asks for storage, which waits for this step); onDestroy too,
    // but not for a recreate (fold/rotation): the step is still on screen then. An unanswered step expires (SetupGate).
    @Override
    protected void onPause() {
        super.onPause();
        if (isFinishing())
            SetupGate.end(GATE);
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        if (isFinishing())
            SetupGate.end(GATE);
    }

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        setTitle("Linux apps: one setup step");
        int sdk = Build.VERSION.SDK_INT;
        PhantomLimit.Fix fix = PhantomLimit.fix(sdk,
                Settings.Global.getString(getContentResolver(), PhantomLimit.MONITOR_SETTING));
        int pad = Math.round(20 * getResources().getDisplayMetrics().density);
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(pad, pad, pad, pad);

        TextView text = new TextView(this);
        text.setTextSize(16);
        text.setText(fix == PhantomLimit.Fix.NONE
                ? "Child process restrictions are off: Android no longer stops PowOS's Linux processes."
                : PhantomLimit.message(fix, sdk, getIntent().getIntExtra(EXTRA_PROCESSES, 0),
                        getIntent().getBooleanExtra(EXTRA_KILLED, false)));
        box.addView(text);

        if (fix == PhantomLimit.Fix.DEVELOPER_OPTIONS) {
            boolean devOn = Settings.Global.getInt(getContentResolver(),
                    Settings.Global.DEVELOPMENT_SETTINGS_ENABLED, 0) != 0;
            Button open = new Button(this);
            open.setText(devOn ? "Open Developer options" : "Open About phone");
            open.setOnClickListener(v -> openSettings(devOn ? Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS
                    : Settings.ACTION_DEVICE_INFO_SETTINGS));
            box.addView(open);
        } else if (fix == PhantomLimit.Fix.ADB) {
            String cmds = PhantomLimit.adbCommands(sdk);
            TextView code = new TextView(this);
            code.setTypeface(android.graphics.Typeface.MONOSPACE);
            code.setTextIsSelectable(true);
            code.setPadding(0, pad / 2, 0, pad / 2);
            code.setText(cmds);
            box.addView(code);
            Button copy = new Button(this);
            copy.setText("Copy");
            copy.setOnClickListener(v -> {
                getSystemService(ClipboardManager.class).setPrimaryClip(ClipData.newPlainText("adb", cmds));
                Toast.makeText(this, "Copied", Toast.LENGTH_SHORT).show();
            });
            box.addView(copy);
        }
        Button done = new Button(this);
        done.setText(getIntent().getBooleanExtra(EXTRA_BEFORE_START, false) ? "Start the desktop" : "Done");
        done.setOnClickListener(v -> finish());
        box.addView(done);

        ScrollView scroll = new ScrollView(this);
        scroll.addView(box);
        setContentView(scroll);
    }

    private void openSettings(String action) {
        try {
            startActivity(new Intent(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        } catch (android.content.ActivityNotFoundException e) {
            startActivity(new Intent(Settings.ACTION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        }
    }
}
