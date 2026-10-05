package com.gaurav.touchremote;

import android.content.Context;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.widget.LinearLayout;
import android.widget.TextView;

/** Small styling helpers — the whole UI is built in code, so there are no resources to ship. */
final class Ui {
    static final int BG      = Color.parseColor("#000000");
    static final int PANEL   = Color.parseColor("#0E0E10");
    static final int KEY     = Color.parseColor("#1B1B1F");
    static final int KEY_ON  = Color.parseColor("#D62828");
    static final int TEXT    = Color.parseColor("#E8E8EA");
    static final int MUTED   = Color.parseColor("#7A7A80");
    static final int ACCENT  = Color.parseColor("#D62828");
    static final int OKBG    = Color.parseColor("#14251A");

    static int dp(Context c, float v) {
        return Math.round(TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v,
                c.getResources().getDisplayMetrics()));
    }

    static GradientDrawable round(int fill, int radiusDp, Context c) {
        GradientDrawable g = new GradientDrawable();
        g.setColor(fill);
        g.setCornerRadius(dp(c, radiusDp));
        return g;
    }

    static TextView key(Context c, String label, float textSp) {
        TextView t = new TextView(c);
        t.setText(label);
        t.setTextColor(TEXT);
        t.setTextSize(textSp);
        t.setGravity(Gravity.CENTER);
        t.setBackground(round(KEY, 14, c));
        t.setPadding(dp(c, 6), dp(c, 14), dp(c, 6), dp(c, 14));
        return t;
    }

    static LinearLayout row(Context c) {
        LinearLayout l = new LinearLayout(c);
        l.setOrientation(LinearLayout.HORIZONTAL);
        return l;
    }

    static LinearLayout.LayoutParams weighted(Context c, float weight) {
        LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(0,
                LinearLayout.LayoutParams.WRAP_CONTENT, weight);
        p.setMargins(dp(c, 4), dp(c, 4), dp(c, 4), dp(c, 4));
        return p;
    }

    static TextView label(Context c, String text, int color, float sp) {
        TextView t = new TextView(c);
        t.setText(text);
        t.setTextColor(color);
        t.setTextSize(sp);
        return t;
    }

    static View spacer(Context c, int h) {
        View v = new View(c);
        v.setLayoutParams(new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, dp(c, h)));
        return v;
    }
}
