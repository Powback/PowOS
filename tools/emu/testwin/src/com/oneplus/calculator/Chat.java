package com.oneplus.calculator;

import android.app.Activity;
import android.graphics.Color;
import android.os.Bundle;
import android.util.Log;
import android.view.Gravity;
import android.view.View;
import android.view.WindowInsets;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;

/** tools/emu/testwin: a chat-shaped window - messages filling the top, a text field pinned to the bottom (adjustResize),
 *  as a messenger's. The keyboard checks (ww-keyboard.sh) tap the field and assert the field's bottom is above the
 *  keyboard's top; each layout logs "PowosTestChat field <x> <y> <w> <h> root <h> ime <px> display <id>" (window px on
 *  its display) so a check can read where the app put its field without a screenshot. */
public class Chat extends Activity {
    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        final LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(Color.rgb(236, 239, 244));
        TextView log = new TextView(this);
        StringBuilder s = new StringBuilder();
        for (int i = 1; i <= 40; i++) s.append("message ").append(i).append('\n');
        log.setText(s);
        log.setGravity(Gravity.BOTTOM);
        log.setPadding(32, 32, 32, 32);
        root.addView(log, new LinearLayout.LayoutParams(-1, 0, 1));
        final EditText field = new EditText(this);
        field.setHint("Message");
        field.setBackgroundColor(Color.WHITE);
        field.setPadding(32, 32, 32, 32);
        root.addView(field, new LinearLayout.LayoutParams(-1, -2));
        root.addOnLayoutChangeListener(new View.OnLayoutChangeListener() {
            @Override
            public void onLayoutChange(View v, int l, int t, int r, int bt, int ol, int ot, int or, int ob) {
                int[] at = new int[2];
                field.getLocationInWindow(at);
                WindowInsets w = v.getRootWindowInsets();
                int ime = w == null ? -1 : w.getInsets(WindowInsets.Type.ime()).bottom;
                int d = getDisplay() == null ? -1 : getDisplay().getDisplayId();
                Log.i("PowosTestChat", "field " + at[0] + " " + at[1] + " " + field.getWidth() + " " + field.getHeight()
                        + " root " + v.getHeight() + " ime " + ime + " display " + d);
            }
        });
        setContentView(root);
    }
}
