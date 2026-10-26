package com.oneplus.calculator;

import android.app.Activity;
import android.graphics.Color;
import android.os.Bundle;
import android.view.Gravity;
import android.widget.Button;
import android.widget.GridLayout;
import android.widget.LinearLayout;
import android.widget.TextView;

/** tools/emu/testwin: a calculator-shaped window that fills whatever bounds it gets (the window checks compare the
 *  layer SurfaceFlinger composes with the task's bounds), and redraws at each new size. */
public class Calculator extends Activity {
    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(Color.rgb(245, 245, 247));
        final TextView display = new TextView(this);
        display.setText("0");
        display.setTextSize(48);
        display.setGravity(Gravity.END | Gravity.BOTTOM);
        display.setPadding(32, 32, 32, 32);
        root.addView(display, new LinearLayout.LayoutParams(-1, 0, 1));
        GridLayout keys = new GridLayout(this);
        keys.setColumnCount(4);
        String[] k = {"7", "8", "9", "/", "4", "5", "6", "*", "1", "2", "3", "-", "0", ".", "=", "+"};
        for (final String s : k) {
            Button btn = new Button(this);
            btn.setText(s);
            btn.setOnClickListener(new android.view.View.OnClickListener() {
                @Override
                public void onClick(android.view.View v) {
                    display.setText("0".equals(display.getText().toString()) ? s : display.getText() + s);
                }
            });
            GridLayout.LayoutParams p = new GridLayout.LayoutParams(GridLayout.spec(GridLayout.UNDEFINED, 1f), GridLayout.spec(GridLayout.UNDEFINED, 1f));
            p.width = 0;
            p.height = 0;
            keys.addView(btn, p);
        }
        root.addView(keys, new LinearLayout.LayoutParams(-1, 0, 2));
        setContentView(root);
    }
}
