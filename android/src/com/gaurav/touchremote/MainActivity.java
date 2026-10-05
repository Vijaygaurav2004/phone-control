package com.gaurav.touchremote;

import android.app.Activity;
import android.content.Context;
import android.media.projection.MediaProjectionManager;
import android.content.Intent;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.VibrationEffect;
import android.os.Vibrator;
import android.text.Editable;
import android.text.TextWatcher;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowManager;
import android.view.inputmethod.InputMethodManager;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import android.content.SharedPreferences;
import android.animation.ValueAnimator;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * Touch Remote — the phone as a full Mac control surface.
 *
 * Four panels: a multi-touch trackpad, a key pad of Mac shortcuts, media and
 * display controls, and a live list of the Mac's running apps. Everything rides
 * one long-lived TCP socket, which the Mac also uses to answer back.
 */
public class MainActivity extends Activity {

    static final int PORT = 8788;
    static final float SWIPE = 90f, SLOP = 24f;
    static final long TAP_MS = 260, HOLD_MS = 420, DOUBLE_MS = 320;

    private volatile String host = null;
    private SharedPreferences prefs;
    volatile boolean connected = false;

    private FrameLayout stage;
    private TrackpadView pad;
    private LinearLayout appsList;
    private TextView status, clipText;
    private EditText keyboard;
    private Vibrator vibrator;

    // Latched modifier keys, shared by the trackpad and the key pad.
    private boolean mCmd, mOpt, mCtrl, mShift;
    private final List<TextView> modButtons = new ArrayList<>();

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        vibrator = (Vibrator) getSystemService(Context.VIBRATOR_SERVICE);

        prefs = getSharedPreferences("touchremote", MODE_PRIVATE);
        String h = getIntent().getStringExtra("host");
        if (h == null) h = prefs.getString("host", null);
        if (h != null) { host = h; saveHost(h); } else { host = null; }

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(Ui.BG);

        // Status strip
        status = Ui.label(this, "looking for your Mac…", Ui.MUTED, 12f);
        status.setGravity(Gravity.CENTER);
        status.setBackground(Ui.round(Ui.PANEL, 20, this));
        LinearLayout.LayoutParams sp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        sp.gravity = Gravity.CENTER_HORIZONTAL;
        sp.setMargins(0, Ui.dp(this, 10), 0, Ui.dp(this, 6));
        status.setPadding(Ui.dp(this, 16), Ui.dp(this, 7), Ui.dp(this, 16), Ui.dp(this, 7));
        root.addView(status, sp);

        stage = new FrameLayout(this);
        root.addView(stage, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f));

        root.addView(tabBar());

        // Off-screen field: focusing it raises the keyboard; keystrokes go to the Mac.
        keyboard = new EditText(this);
        keyboard.setAlpha(0f);
        keyboard.addTextChangedListener(new TextWatcher() {
            public void beforeTextChanged(CharSequence s, int a, int c, int d) {}
            public void onTextChanged(CharSequence s, int a, int before, int count) {
                if (count > 0) send("K " + s.subSequence(a, a + count).toString().replace("\n", "\\n"));
            }
            public void afterTextChanged(Editable e) { if (e.length() > 0) e.clear(); }
        });
        keyboard.setOnKeyListener((v, code, ev) -> {
            if (ev.getAction() != KeyEvent.ACTION_DOWN) return false;
            if (code == KeyEvent.KEYCODE_DEL)   { send("P back");  return true; }
            if (code == KeyEvent.KEYCODE_ENTER) { send("P enter"); return true; }
            return false;
        });
        FrameLayout wrap = new FrameLayout(this);
        wrap.addView(root);
        wrap.addView(keyboard, new FrameLayout.LayoutParams(1, 1));
        setContentView(wrap);

        show(0);
        immersive();

        Link link = Link.get();
        link.setListener(new Link.Listener() {
            public void onLine(String line) { handleFromMac(line); }
            public void onState(boolean up, String h) {
                connected = up;
                ui(() -> setStatus(up ? "connected · " + h : "looking for your Mac…", up));
            }
        });
        link.start(host);

        new Thread(() -> {
            while (true) {
                try { Thread.sleep(3000); } catch (InterruptedException e) { return; }
                if (connected) send("PING");
            }
        }, "heartbeat").start();
    }

    // ------------------------------------------------------------ chrome

    private LinearLayout tabBar() {
        LinearLayout bar = Ui.row(this);
        bar.setBackgroundColor(Ui.PANEL);
        bar.setPadding(Ui.dp(this, 6), Ui.dp(this, 6), Ui.dp(this, 6), Ui.dp(this, 10));
        String[] names = {"Trackpad", "Keys", "Media", "Apps"};
        for (int i = 0; i < names.length; i++) {
            final int index = i;
            TextView t = Ui.key(this, names[i], 13f);
            t.setBackground(Ui.round(Ui.PANEL, 12, this));
            t.setTextColor(i == 0 ? Ui.TEXT : Ui.MUTED);
            t.setOnClickListener(v -> {
                tap();
                for (int j = 0; j < bar.getChildCount(); j++)
                    ((TextView) bar.getChildAt(j)).setTextColor(j == index ? Ui.TEXT : Ui.MUTED);
                show(index);
            });
            bar.addView(t, Ui.weighted(this, 1f));
        }
        return bar;
    }

    private void show(int index) {
        stage.removeAllViews();
        View v;
        switch (index) {
            case 1:  v = keysPanel(); break;
            case 2:  v = mediaPanel(); break;
            case 3:  v = appsPanel(); send("APPS"); break;
            default: v = trackpadPanel(); break;
        }
        stage.addView(v, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));
    }

    private void immersive() {
        getWindow().getDecorView().setSystemUiVisibility(
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY | View.SYSTEM_UI_FLAG_FULLSCREEN
              | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION | View.SYSTEM_UI_FLAG_LAYOUT_STABLE
              | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION);
    }

    @Override public void onWindowFocusChanged(boolean f) {
        super.onWindowFocusChanged(f);
        if (f) immersive();
    }

    private void tap() {
        if (vibrator == null || !vibrator.hasVibrator()) return;
        if (Build.VERSION.SDK_INT >= 26)
            vibrator.vibrate(VibrationEffect.createOneShot(8, 60));
    }

    // ------------------------------------------------------------ panels

    private View trackpadPanel() {
        LinearLayout col = new LinearLayout(this);
        col.setOrientation(LinearLayout.VERTICAL);

        pad = new TrackpadView(this);
        col.addView(pad, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f));

        LinearLayout mods = Ui.row(this);
        mods.setPadding(Ui.dp(this, 6), 0, Ui.dp(this, 6), Ui.dp(this, 6));
        modButtons.clear();
        String[][] defs = {{"⌘","cmd"},{"⌥","opt"},{"⌃","ctrl"},{"⇧","shift"},{"⌨","kb"}};
        for (String[] d : defs) {
            TextView t = Ui.key(this, d[0], 18f);
            modButtons.add(t);
            t.setOnClickListener(v -> {
                tap();
                if (d[1].equals("kb")) { showKeyboard(); return; }
                switch (d[1]) {
                    case "cmd":   mCmd = !mCmd; break;
                    case "opt":   mOpt = !mOpt; break;
                    case "ctrl":  mCtrl = !mCtrl; break;
                    case "shift": mShift = !mShift; break;
                }
                syncMods();
            });
            mods.addView(t, Ui.weighted(this, 1f));
        }
        col.addView(mods);
        syncMods();
        return col;
    }

    private void syncMods() {
        String[] keys = {"cmd", "opt", "ctrl", "shift"};
        boolean[] on = {mCmd, mOpt, mCtrl, mShift};
        for (int i = 0; i < 4 && i < modButtons.size(); i++)
            modButtons.get(i).setBackground(Ui.round(on[i] ? Ui.KEY_ON : Ui.KEY, 14, this));
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < 4; i++) if (on[i]) { if (sb.length() > 0) sb.append(','); sb.append(keys[i]); }
        send("MOD " + sb);
    }

    private View keysPanel() {
        ScrollView sv = new ScrollView(this);
        LinearLayout col = new LinearLayout(this);
        col.setOrientation(LinearLayout.VERTICAL);
        col.setPadding(Ui.dp(this, 8), Ui.dp(this, 8), Ui.dp(this, 8), Ui.dp(this, 8));

        String[][][] groups = {
            {{"Navigation",""}, {"esc","Esc"},{"tab","Tab"},{"back","⌫"},{"enter","⏎"}},
            {{"Arrows",""},     {"left","←"},{"down","↓"},{"up","↑"},{"right","→"}},
            {{"Editing",""},    {"copy","Copy"},{"paste","Paste"},{"cut","Cut"},{"undo","Undo"}},
            {{"",""},           {"redo","Redo"},{"save","Save"},{"selectall","All"},{"find","Find"}},
            {{"System",""},     {"spotlight","Spotlight"},{"switcher","⌘Tab"},{"screenshot","Snip"},{"lock","Lock"}},
            {{"Windows",""},    {"mission","Mission"},{"expose","Exposé"},{"launchpad","Launch"},{"spotlight","Search"}},
            {{"Switch apps",""}, {"prevApp","◀ App"},{"nextApp","App ▶"},{"mission","Mission"},{"switcher","⌘Tab"}},
            {{"Window",""},      {"close","⌘W"},{"quit","⌘Q"},{"fullscreen","Full"},{"switcher","⌘Tab"}},
        };
        for (String[][] g : groups) {
            if (!g[0][0].isEmpty()) {
                TextView h = Ui.label(this, g[0][0].toUpperCase(Locale.US), Ui.MUTED, 11f);
                h.setPadding(Ui.dp(this, 6), Ui.dp(this, 12), 0, Ui.dp(this, 2));
                col.addView(h);
            }
            LinearLayout r = Ui.row(this);
            for (int i = 1; i < g.length; i++) {
                final String cmd = g[i][0];
                TextView t = Ui.key(this, g[i][1], 14f);
                t.setOnClickListener(v -> { tap(); send("X " + cmd); clearMods(); });
                r.addView(t, Ui.weighted(this, 1f));
            }
            col.addView(r);
        }
        sv.addView(col);
        return sv;
    }

    private void clearMods() {
        if (!(mCmd || mOpt || mCtrl || mShift)) return;
        mCmd = mOpt = mCtrl = mShift = false;
        send("MOD ");
    }

    private View mediaPanel() {
        LinearLayout col = new LinearLayout(this);
        col.setOrientation(LinearLayout.VERTICAL);
        col.setPadding(Ui.dp(this, 10), Ui.dp(this, 10), Ui.dp(this, 10), Ui.dp(this, 10));

        col.addView(Ui.label(this, "SCREEN", Ui.MUTED, 11f));
        TextView mirror = Ui.key(this, ScreenCaptureService.active
                ? "Stop Mirroring" : "Mirror my Screen to the Mac", 16f);
        mirror.setPadding(Ui.dp(this, 10), Ui.dp(this, 18), Ui.dp(this, 10), Ui.dp(this, 18));
        mirror.setOnClickListener(v -> {
            tap();
            startMirroring();
            mirror.postDelayed(() -> mirror.setText(ScreenCaptureService.active
                    ? "Stop Mirroring" : "Mirror my Screen to the Mac"), 1200);
        });
        col.addView(mirror);
        col.addView(Ui.spacer(this, 18));

        col.addView(Ui.label(this, "PLAYBACK", Ui.MUTED, 11f));
        LinearLayout media = Ui.row(this);
        String[][] m = {{"prev","⏮"},{"play","⏯"},{"next","⏭"}};
        for (String[] d : m) {
            TextView t = Ui.key(this, d[1], 26f);
            t.setOnClickListener(v -> { tap(); send("MED " + d[0]); });
            media.addView(t, Ui.weighted(this, 1f));
        }
        col.addView(media);

        col.addView(Ui.spacer(this, 14));
        col.addView(Ui.label(this, "VOLUME", Ui.MUTED, 11f));
        LinearLayout vol = Ui.row(this);
        String[][] v = {{"down","−"},{"mute","🔇"},{"up","+"}};
        for (String[] d : v) {
            TextView t = Ui.key(this, d[1], 22f);
            t.setOnClickListener(x -> { tap(); send("V " + d[0]); });
            vol.addView(t, Ui.weighted(this, 1f));
        }
        col.addView(vol);

        col.addView(Ui.spacer(this, 14));
        col.addView(Ui.label(this, "BRIGHTNESS", Ui.MUTED, 11f));
        LinearLayout br = Ui.row(this);
        String[][] bs = {{"down","☀ −"},{"up","☀ +"}};
        for (String[] d : bs) {
            TextView t = Ui.key(this, d[1], 20f);
            t.setOnClickListener(x -> { tap(); send("B " + d[0]); });
            br.addView(t, Ui.weighted(this, 1f));
        }
        col.addView(br);

        col.addView(Ui.spacer(this, 20));
        col.addView(Ui.label(this, "CLIPBOARD", Ui.MUTED, 11f));
        clipText = Ui.label(this, "—", Ui.TEXT, 14f);
        clipText.setBackground(Ui.round(Ui.KEY, 12, this));
        clipText.setPadding(Ui.dp(this, 12), Ui.dp(this, 12), Ui.dp(this, 12), Ui.dp(this, 12));
        clipText.setMaxLines(4);
        col.addView(clipText);

        LinearLayout clip = Ui.row(this);
        TextView get = Ui.key(this, "Get from Mac", 14f);
        get.setOnClickListener(x -> { tap(); send("CLIPGET"); });
        TextView put = Ui.key(this, "Send to Mac", 14f);
        put.setOnClickListener(x -> {
            tap();
            android.content.ClipboardManager cm =
                    (android.content.ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
            if (cm != null && cm.hasPrimaryClip() && cm.getPrimaryClip() != null
                    && cm.getPrimaryClip().getItemCount() > 0) {
                CharSequence t = cm.getPrimaryClip().getItemAt(0).coerceToText(this);
                send("CLIPSET " + t.toString().replace("\n", "\\n"));
                clipText.setText(t);
            }
        });
        clip.addView(get, Ui.weighted(this, 1f));
        clip.addView(put, Ui.weighted(this, 1f));
        col.addView(clip);
        return col;
    }

    private View appsPanel() {
        LinearLayout col = new LinearLayout(this);
        col.setOrientation(LinearLayout.VERTICAL);
        col.setPadding(Ui.dp(this, 10), Ui.dp(this, 10), Ui.dp(this, 10), Ui.dp(this, 10));

        LinearLayout head = Ui.row(this);
        head.addView(Ui.label(this, "MAC APPS", Ui.MUTED, 11f),
                new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
        TextView refresh = Ui.label(this, "Refresh", Ui.ACCENT, 13f);
        refresh.setOnClickListener(v -> { tap(); send("APPS"); });
        head.addView(refresh);
        col.addView(head);

        ScrollView sv = new ScrollView(this);
        appsList = new LinearLayout(this);
        appsList.setOrientation(LinearLayout.VERTICAL);
        appsList.addView(Ui.label(this, "asking the Mac…", Ui.MUTED, 14f));
        sv.addView(appsList);
        col.addView(sv);
        return col;
    }

    private void renderApps(String[] names) {
        if (appsList == null) return;
        appsList.removeAllViews();
        for (String n : names) {
            if (n.trim().isEmpty()) continue;
            TextView t = Ui.key(this, n, 16f);
            t.setGravity(Gravity.CENTER_VERTICAL);
            t.setPadding(Ui.dp(this, 16), Ui.dp(this, 16), Ui.dp(this, 16), Ui.dp(this, 16));
            LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
            p.setMargins(0, Ui.dp(this, 4), 0, Ui.dp(this, 4));
            t.setOnClickListener(v -> { tap(); send("ACT " + n); });
            appsList.addView(t, p);
        }
    }

    void showKeyboard() {
        keyboard.requestFocus();
        InputMethodManager im = (InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE);
        if (im != null) im.showSoftInput(keyboard, InputMethodManager.SHOW_IMPLICIT);
    }

    /** Remember where the Mac was, so the next launch skips discovery. */
    private void saveHost(String h) {
        host = h;
        if (prefs != null) prefs.edit().putString("host", h).apply();
        Link.get().setHost(h);
    }

    // ------------------------------------------------------------ link

    void send(String line) { Link.get().sendLine(line); }

    private void handleFromMac(String line) {
        if (line.startsWith("APPS ")) {
            String[] names = line.substring(5).split("\\|");
            ui(() -> renderApps(names));
        } else if (line.startsWith("CLIP ")) {
            String text = line.substring(5).replace("\\n", "\n");
            ui(() -> { if (clipText != null) clipText.setText(text.isEmpty() ? "—" : text); });
        } else if (line.equals("KEYFRAME")) {
            ScreenCaptureService.requestKeyframe();
        }
    }

    private void ui(Runnable r) { new Handler(Looper.getMainLooper()).post(r); }

    private void setStatus(String text, boolean ok) {
        status.setText((ok ? "● " : "○ ") + text);
        status.setTextColor(ok ? Ui.TEXT : Ui.MUTED);
        status.setBackground(Ui.round(ok ? Ui.OKBG : Ui.PANEL, 20, this));
    }

    // ------------------------------------------------------------ mirroring

    private static final int REQ_CAPTURE = 1001;

    /** Opens the system's own consent dialog. No developer options involved. */
    void startMirroring() {
        if (ScreenCaptureService.active) {
            Intent stop = new Intent(this, ScreenCaptureService.class);
            stop.setAction(ScreenCaptureService.ACTION_STOP);
            startService(stop);
            return;
        }
        MediaProjectionManager mpm =
                (MediaProjectionManager) getSystemService(Context.MEDIA_PROJECTION_SERVICE);
        if (mpm != null) startActivityForResult(mpm.createScreenCaptureIntent(), REQ_CAPTURE);
    }

    @Override protected void onActivityResult(int req, int result, Intent data) {
        super.onActivityResult(req, result, data);
        if (req != REQ_CAPTURE) return;
        if (result != RESULT_OK || data == null) {
            ui(() -> setStatus("mirroring declined", false));
            return;
        }
        // The token is single-use and the service must be foregrounded before
        // it is redeemed, so hand it straight over and start immediately —
        // deferring this past onActivityResult risks a background-start block.
        Intent svc = new Intent(this, ScreenCaptureService.class);
        svc.putExtra(ScreenCaptureService.EXTRA_CODE, result);
        svc.putExtra(ScreenCaptureService.EXTRA_DATA, data);
        if (Build.VERSION.SDK_INT >= 26) startForegroundService(svc); else startService(svc);
    }

    // ------------------------------------------------------------ trackpad    // ------------------------------------------------------------ trackpad

    class TrackpadView extends View {
        private final Paint dim = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint faint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint dot = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint touch = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint ring = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final float[] fx = new float[10], fy = new float[10];
        private int fingers = 0;

        private float lastX, lastY, startX, startY, travelled;
        private long downAt, lastTapAt;
        private int maxPointers;
        private boolean fired, dragging;
        private final Handler h = new Handler(Looper.getMainLooper());
        private final Runnable hold = () -> {
            if (travelled < SLOP && maxPointers == 1) { dragging = true; tap(); send("D 1"); }
        };

        TrackpadView(Context c) {
            super(c);
            dim.setColor(Ui.MUTED); dim.setTextSize(44f);
            dim.setFakeBoldText(true); dim.setTextAlign(Paint.Align.CENTER);
            faint.setColor(Color.parseColor("#2E2E33")); faint.setTextSize(30f);
            faint.setTextAlign(Paint.Align.CENTER);
            dot.setColor(Ui.ACCENT);
            touch.setColor(Color.parseColor("#33D62828"));
            ring.setColor(Ui.ACCENT);
            ring.setStyle(Paint.Style.STROKE);
            ring.setStrokeWidth(3f);
        }

        @Override protected void onDraw(Canvas c) {
            float cx = getWidth() / 2f, cy = getHeight() / 2f;
            c.drawText("Trackpad", cx, cy - 60, dim);
            c.drawText("two fingers scroll", cx, cy + 10, faint);
            c.drawText("three fingers switch apps", cx, cy + 52, faint);
            c.drawCircle(cx, cy + 108, 8f, dot);

            // Show every finger the app can see — the honest proof that
            // multi-touch is actually working.
            for (int i = 0; i < fingers; i++) {
                c.drawCircle(fx[i], fy[i], 78f, touch);
                c.drawCircle(fx[i], fy[i], 78f, ring);
            }
            if (fingers > 1) {
                dim.setTextSize(120f);
                dim.setAlpha(28);
                c.drawText(String.valueOf(fingers), cx, cy - 190, dim);
                dim.setAlpha(255);
                dim.setTextSize(44f);
            }
        }

        private void trackFingers(MotionEvent e, int skip) {
            int n = 0;
            for (int i = 0; i < e.getPointerCount() && n < 10; i++) {
                if (i == skip) continue;
                fx[n] = e.getX(i); fy[n] = e.getY(i); n++;
            }
            fingers = n;
            invalidate();
        }

        private float[] centroid(MotionEvent e, int skip) {
            float x = 0, y = 0; int n = 0;
            for (int i = 0; i < e.getPointerCount(); i++) {
                if (i == skip) continue;
                x += e.getX(i); y += e.getY(i); n++;
            }
            return n == 0 ? new float[]{lastX, lastY} : new float[]{x / n, y / n};
        }

        @Override public boolean onTouchEvent(MotionEvent e) {
            int action = e.getActionMasked();
            int n = e.getPointerCount();
            int skip = action == MotionEvent.ACTION_POINTER_UP ? e.getActionIndex() : -1;
            float[] c = centroid(e, skip);
            trackFingers(e, action == MotionEvent.ACTION_UP ? 0 : skip);
            if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) {
                fingers = 0; invalidate();
            }

            switch (action) {
                case MotionEvent.ACTION_DOWN:
                    downAt = System.currentTimeMillis();
                    travelled = 0; fired = false; maxPointers = 1;
                    startX = c[0]; startY = c[1]; lastX = c[0]; lastY = c[1];
                    h.postDelayed(hold, HOLD_MS);
                    break;

                case MotionEvent.ACTION_POINTER_DOWN:
                    maxPointers = Math.max(maxPointers, n);
                    h.removeCallbacks(hold);
                    // Re-anchor: a new finger otherwise reads as a huge jump.
                    lastX = c[0]; lastY = c[1]; startX = c[0]; startY = c[1];
                    break;

                case MotionEvent.ACTION_MOVE: {
                    float dx = c[0] - lastX, dy = c[1] - lastY;
                    lastX = c[0]; lastY = c[1];
                    travelled += Math.abs(dx) + Math.abs(dy);

                    if (n == 1) {
                        send("M " + f(dx) + " " + f(dy));
                    } else if (n == 2) {
                        send("S " + f(-dy));
                    } else if (!fired) {
                        float tx = c[0] - startX, ty = c[1] - startY;
                        if (Math.abs(tx) > SWIPE && Math.abs(tx) > Math.abs(ty)) {
                            fired = true; tap(); send("G " + (tx < 0 ? "sr" : "sl"));
                        } else if (-ty > SWIPE) { fired = true; tap(); send("G mc"); }
                        else if (ty > SWIPE)    { fired = true; tap(); send("G ae"); }
                    }
                    break;
                }

                case MotionEvent.ACTION_POINTER_UP:
                    lastX = c[0]; lastY = c[1];
                    break;

                case MotionEvent.ACTION_UP:
                case MotionEvent.ACTION_CANCEL: {
                    h.removeCallbacks(hold);
                    long held = System.currentTimeMillis() - downAt;
                    if (dragging) {
                        dragging = false; send("D 0");
                    } else if (!fired && travelled < SLOP && held < TAP_MS) {
                        tap();
                        if (maxPointers >= 2) {
                            send("C r 1");
                        } else {
                            long now = System.currentTimeMillis();
                            boolean dbl = now - lastTapAt < DOUBLE_MS;
                            lastTapAt = dbl ? 0 : now;
                            send("C l " + (dbl ? 2 : 1));
                        }
                        clearMods();
                    }
                    break;
                }
            }
            return true;
        }

        private String f(float v) { return String.format(Locale.US, "%.2f", v); }
    }
}
