package com.gaurav.touchremote;

import android.accessibilityservice.AccessibilityService;
import android.accessibilityservice.AccessibilityServiceInfo;
import android.accessibilityservice.GestureDescription;
import android.accessibilityservice.GestureDescription.StrokeDescription;
import android.content.Context;
import android.content.Intent;
import android.graphics.Path;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.DisplayMetrics;
import android.view.WindowManager;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityNodeInfo;

import java.util.ArrayDeque;

/**
 * Touch injection without adb, root or developer options.
 *
 * INJECT_EVENTS is signature-level and unavailable to normal apps, so the only
 * user-grantable route is an AccessibilityService. The user enables it once in
 * Settings → Accessibility; that is a permission, not a developer setting.
 *
 * Two framework facts shape this class:
 *
 *  1. dispatchGesture() CANCELS whatever gesture is in flight — including the
 *     user's own finger. Gestures therefore have to be strictly serialised:
 *     dispatch one, wait for its callback, then dispatch the next.
 *  2. A stroke built with willContinue=true leaves its pointer DOWN afterwards.
 *     The continuation must come from that exact StrokeDescription via
 *     continueStroke(), and only after the previous segment completed. That is
 *     what makes click-and-drag from the Mac possible at all.
 */
public class TouchService extends AccessibilityService {

    private static volatile TouchService instance;
    public static TouchService get() { return instance; }
    public static boolean isLive() { return instance != null; }

    private final Handler main = new Handler(Looper.getMainLooper());
    private final ArrayDeque<Job> queue = new ArrayDeque<>();

    private boolean busy;
    private StrokeDescription held;     // non-null while a pointer is down
    private int screenW = 1080, screenH = 2400;

    private interface Job { GestureDescription build(); }

    // ---------------------------------------------------------------- lifecycle

    @Override protected void onServiceConnected() {
        super.onServiceConnected();
        AccessibilityServiceInfo info = getServiceInfo();
        if (info != null) {
            info.flags |= AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
                        | AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS;
            setServiceInfo(info);
        }
        measureScreen();
        instance = this;
        Link.get().sendLine("LOG touch injector live " + screenW + "x" + screenH);
        Link.get().sendLine("TOUCH ready");
    }

    @Override public boolean onUnbind(Intent intent) {
        instance = null;
        main.removeCallbacksAndMessages(null);
        queue.clear();
        busy = false;
        held = null;
        return super.onUnbind(intent);
    }

    @Override public void onDestroy() { instance = null; super.onDestroy(); }

    @Override public void onAccessibilityEvent(AccessibilityEvent e) { }
    @Override public void onInterrupt() { }

    private void measureScreen() {
        WindowManager wm = (WindowManager) getSystemService(Context.WINDOW_SERVICE);
        if (wm == null) return;
        DisplayMetrics dm = new DisplayMetrics();
        wm.getDefaultDisplay().getRealMetrics(dm);
        screenW = dm.widthPixels;
        screenH = dm.heightPixels;
    }

    public int width()  { return screenW; }
    public int height() { return screenH; }

    // ---------------------------------------------------------------- the queue

    private final GestureResultCallback callback = new GestureResultCallback() {
        @Override public void onCompleted(GestureDescription g) { busy = false; drain(); }
        @Override public void onCancelled(GestureDescription g) { busy = false; held = null; drain(); }
    };

    private void post(final Job job) {
        main.post(() -> {
            // A stalled link must not let the queue grow without bound.
            if (queue.size() > 48) queue.poll();
            queue.add(job);
            drain();
        });
    }

    private void drain() {
        while (!busy && !queue.isEmpty()) {
            Job job = queue.poll();
            GestureDescription g;
            try {
                g = job.build();
            } catch (RuntimeException e) {
                // Out-of-bounds coordinates, zero duration, continueStroke() on a
                // stroke that was not willContinue — all throw rather than fail soft.
                Link.get().sendLine("LOG gesture rejected: " + e);
                held = null;
                continue;
            }
            if (g == null) continue;
            busy = true;
            if (!dispatchGesture(g, callback, main)) {
                // False means not connected, or canPerformGestures was never
                // granted. No callback will arrive, so don't wait for one.
                busy = false;
                held = null;
                Link.get().sendLine("LOG dispatchGesture refused");
            }
        }
    }

    private float clampX(float x) { return Math.max(0, Math.min(screenW - 1, x)); }
    private float clampY(float y) { return Math.max(0, Math.min(screenH - 1, y)); }

    private static Path pathOf(float x1, float y1, float x2, float y2) {
        Path p = new Path();
        p.moveTo(x1, y1);
        if (x1 != x2 || y1 != y2) p.lineTo(x2, y2); else p.lineTo(x1 + 0.5f, y1);
        return p;
    }

    // ---------------------------------------------------------------- gestures

    public void tap(final float x, final float y) {
        post(() -> {
            Path p = pathOf(clampX(x), clampY(y), clampX(x), clampY(y));
            return new GestureDescription.Builder()
                    .addStroke(new StrokeDescription(p, 0, 60)).build();
        });
    }

    public void longPress(final float x, final float y) {
        post(() -> {
            Path p = pathOf(clampX(x), clampY(y), clampX(x), clampY(y));
            return new GestureDescription.Builder()
                    .addStroke(new StrokeDescription(p, 0, 650)).build();
        });
    }

    public void swipe(final float x1, final float y1, final float x2, final float y2, final int ms) {
        post(() -> {
            Path p = pathOf(clampX(x1), clampY(y1), clampX(x2), clampY(y2));
            int dur = Math.max(20, Math.min(30_000, ms));
            return new GestureDescription.Builder()
                    .addStroke(new StrokeDescription(p, 0, dur)).build();
        });
    }

    /** Press and hold — the start of a drag from the Mac. */
    public void down(final float x, final float y) {
        post(() -> {
            Path p = pathOf(clampX(x), clampY(y), clampX(x), clampY(y));
            held = new StrokeDescription(p, 0, 80, true);   // willContinue
            return new GestureDescription.Builder().addStroke(held).build();
        });
    }

    /** Continue the held stroke. Must come from the previous StrokeDescription. */
    public void moveTo(final float x, final float y) {
        post(() -> {
            if (held == null) return null;
            Path p = pathOf(clampX(x), clampY(y), clampX(x), clampY(y));
            held = held.continueStroke(p, 0, 40, true);
            return new GestureDescription.Builder().addStroke(held).build();
        });
    }

    /** Release — the final segment has willContinue = false. */
    public void up(final float x, final float y) {
        post(() -> {
            if (held == null) return null;
            Path p = pathOf(clampX(x), clampY(y), clampX(x), clampY(y));
            StrokeDescription last = held.continueStroke(p, 0, 40, false);
            held = null;
            return new GestureDescription.Builder().addStroke(last).build();
        });
    }

    // ---------------------------------------------------------------- keys & text

    public void back()    { performGlobalAction(GLOBAL_ACTION_BACK); }
    public void home()    { performGlobalAction(GLOBAL_ACTION_HOME); }
    public void recents() { performGlobalAction(GLOBAL_ACTION_RECENTS); }

    public void notifications() { performGlobalAction(GLOBAL_ACTION_NOTIFICATIONS); }

    /**
     * Type into whatever is focused. ACTION_SET_TEXT replaces the whole field,
     * so the existing text is read first and the new text appended — otherwise
     * every keystroke would wipe what came before it.
     */
    public void type(final String text) {
        main.post(() -> {
            AccessibilityNodeInfo node = findFocus(AccessibilityNodeInfo.FOCUS_INPUT);
            if (node == null) {
                Link.get().sendLine("LOG no focused text field");
                return;
            }
            CharSequence existing = node.getText();
            String combined = (existing == null ? "" : existing.toString()) + text;
            Bundle args = new Bundle();
            args.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, combined);
            boolean ok = node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args);
            if (!ok) Link.get().sendLine("LOG SET_TEXT refused");
            node.recycle();
        });
    }

    /** Backspace: rewrite the focused field one character shorter. */
    public void backspace() {
        main.post(() -> {
            AccessibilityNodeInfo node = findFocus(AccessibilityNodeInfo.FOCUS_INPUT);
            if (node == null) return;
            CharSequence existing = node.getText();
            if (existing == null || existing.length() == 0) { node.recycle(); return; }
            Bundle args = new Bundle();
            args.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                    existing.subSequence(0, existing.length() - 1));
            node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args);
            node.recycle();
        });
    }

    /** Deep-link the user to the Accessibility settings page. */
    public static void openSettings(Context ctx) {
        Intent i = new Intent(android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS);
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        ctx.startActivity(i);
    }
}
