package com.gaurav.touchremote;

import android.app.Activity;
import android.content.Context;
import android.graphics.Color;
import android.media.MediaCodec;
import android.media.MediaFormat;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.Editable;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.Surface;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.view.WindowManager;
import android.view.inputmethod.InputMethodManager;
import android.widget.FrameLayout;
import android.widget.TextView;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.util.Arrays;
import java.util.Locale;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.TimeUnit;

/**
 * Your Mac's screen, on the phone.
 *
 * The Mac encodes its display to H.264 and streams it down the shared socket;
 * this decodes it straight onto a SurfaceView with MediaCodec. Touches come
 * back as fractions of the picture, so they land in the right place whatever
 * the two screens' resolutions are.
 *
 *   tap               click there
 *   press, then move  drag (select text, move windows)
 *   long press        right click
 *   two fingers       scroll
 */
public class CastActivity extends Activity implements SurfaceHolder.Callback, Link.FrameListener {

    private static final float SLOP = 18f;
    private static final long LONG_PRESS_MS = 520;

    private FrameLayout root;
    private SurfaceView view;
    private TextView status;
    private RemoteKeyboard keyboard;
    private Surface surface;

    private final Object lock = new Object();
    private MediaCodec decoder;
    private byte[] sps, pps;
    private int videoW, videoH;
    private boolean waitingForKey = true;

    private final ByteArrayOutputStream pending = new ByteArrayOutputStream(256 * 1024);
    private boolean pendingKey;
    private final ArrayBlockingQueue<byte[]> units = new ArrayBlockingQueue<>(12);
    private volatile boolean running;
    private long pts;

    private final Handler main = new Handler(Looper.getMainLooper());

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);

        view = new SurfaceView(this);
        view.getHolder().addCallback(this);
        root.addView(view, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT,
                Gravity.CENTER));

        status = new TextView(this);
        status.setText("Asking your Mac for its screen…");
        status.setTextColor(Color.parseColor("#9A9AA0"));
        status.setTextSize(15f);
        status.setGravity(Gravity.CENTER);
        root.addView(status, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));

        TextView kb = new TextView(this);
        kb.setText("⌨");
        kb.setTextSize(22f);
        kb.setTextColor(Color.WHITE);
        kb.setAlpha(0.55f);
        kb.setPadding(28, 18, 28, 18);
        kb.setOnClickListener(v -> showKeyboard());
        FrameLayout.LayoutParams kp = new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.BOTTOM | Gravity.END);
        root.addView(kb, kp);

        // Owns its InputConnection so autocorrect/predictions/backspace behave.
        keyboard = new RemoteKeyboard(this, RemoteKeyboard.toMac());
        root.addView(keyboard, new FrameLayout.LayoutParams(1, 1));

        view.setOnTouchListener((v, e) -> { onTouch(e); return true; });
        setContentView(root);
        immersive();
    }

    @Override protected void onResume() {
        super.onResume();
        immersive();
        running = true;
        new Thread(this::decodeLoop, "cast-decoder").start();
        Link.get().setFrameListener(this);
        Link.get().sendLine("CAST start");
    }

    @Override protected void onPause() {
        Link.get().sendLine("CAST stop");
        Link.get().setFrameListener(null);
        running = false;
        releaseDecoder();
        super.onPause();
    }

    private void immersive() {
        getWindow().getDecorView().setSystemUiVisibility(
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY | View.SYSTEM_UI_FLAG_FULLSCREEN
              | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION | View.SYSTEM_UI_FLAG_LAYOUT_STABLE
              | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION);
    }

    private void showKeyboard() {
        keyboard.show();
    }

    // ---------------------------------------------------------------- surface

    @Override public void surfaceCreated(SurfaceHolder h) {
        synchronized (lock) {
            surface = h.getSurface();
            if (sps != null) startDecoder();
        }
    }

    @Override public void surfaceChanged(SurfaceHolder h, int f, int w, int hh) { }

    @Override public void surfaceDestroyed(SurfaceHolder h) {
        releaseDecoder();
        synchronized (lock) { surface = null; }
    }

    // ---------------------------------------------------------------- frames in

    @Override public void onText(String line) {
        if (line.startsWith("CASTERR ")) {
            final String msg = line.substring(8);
            main.post(() -> { status.setVisibility(View.VISIBLE); status.setText(msg); });
        }
    }

    @Override public void onFrame(int type, int flags, byte[] payload) {
        if (type == 0x03) {                         // config: width, height, SPS, PPS
            if (payload.length <= 8) return;
            int w = ((payload[0] & 0xFF) << 24) | ((payload[1] & 0xFF) << 16)
                  | ((payload[2] & 0xFF) << 8) | (payload[3] & 0xFF);
            int h = ((payload[4] & 0xFF) << 24) | ((payload[5] & 0xFF) << 16)
                  | ((payload[6] & 0xFF) << 8) | (payload[7] & 0xFF);
            byte[] csd = Arrays.copyOfRange(payload, 8, payload.length);
            configure(csd, w, h);
        } else if (type == 0x02) {                  // one chunk of an access unit
            boolean key = (flags & 0x01) != 0, cont = (flags & 0x02) != 0, last = (flags & 0x04) != 0;
            if (!cont) { pending.reset(); pendingKey = key; }
            pending.write(payload, 0, payload.length);
            if (!last) return;
            byte[] au = pending.toByteArray();
            pending.reset();
            boolean isKey = pendingKey;
            synchronized (lock) {
                if (waitingForKey) {
                    if (!isKey) return;     // nothing decodes until an IDR after a (re)config
                    waitingForKey = false;
                }
            }
            if (!units.offer(au)) {
                // The decoder fell behind. Dropping a frame breaks the reference
                // chain, so throw the rest away and ask for a fresh keyframe.
                units.clear();
                synchronized (lock) { waitingForKey = true; }
                Link.get().sendLine("CASTKEY");
            }
        }
    }

    /** Split Annex-B csd into SPS and PPS, each keeping its start code. */
    private void configure(byte[] csd, int w, int h) {
        byte[] newSps = null, newPps = null;
        int[] starts = startCodes(csd);
        for (int i = 0; i < starts.length; i++) {
            int s = starts[i];
            int e = (i + 1 < starts.length) ? startOffset(csd, starts[i + 1]) : csd.length;
            if (s >= e) continue;
            int type = csd[s] & 0x1F;
            byte[] nal = new byte[4 + (e - s)];
            nal[3] = 1;
            System.arraycopy(csd, s, nal, 4, e - s);
            if (type == 7) newSps = nal; else if (type == 8) newPps = nal;
        }
        if (newSps == null || newPps == null) return;

        synchronized (lock) {
            // The Mac resends this with every keyframe; only rebuild if it changed.
            if (Arrays.equals(newSps, sps) && Arrays.equals(newPps, pps) && w == videoW && h == videoH
                    && decoder != null) return;
            sps = newSps; pps = newPps; videoW = w; videoH = h;
            if (surface != null) startDecoder();
        }
        main.post(this::fitView);
    }

    /** Letterbox the picture to its true aspect ratio, so taps map exactly. */
    private void fitView() {
        if (videoW <= 0 || videoH <= 0) return;
        int rw = root.getWidth(), rh = root.getHeight();
        if (rw == 0 || rh == 0) { root.post(this::fitView); return; }
        float scale = Math.min(rw / (float) videoW, rh / (float) videoH);
        FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(
                Math.round(videoW * scale), Math.round(videoH * scale), Gravity.CENTER);
        view.setLayoutParams(lp);
        status.setVisibility(View.GONE);
    }

    private static int[] startCodes(byte[] d) {
        int[] tmp = new int[16]; int n = 0;
        for (int i = 0; i + 3 <= d.length && n < 16; i++) {
            if (d[i] == 0 && d[i + 1] == 0) {
                if (d[i + 2] == 1) { tmp[n++] = i + 3; i += 2; }
                else if (i + 4 <= d.length && d[i + 2] == 0 && d[i + 3] == 1) { tmp[n++] = i + 4; i += 3; }
            }
        }
        return Arrays.copyOf(tmp, n);
    }

    /** Where the start code that precedes payload offset `p` begins. */
    private static int startOffset(byte[] d, int p) {
        int q = p - 3;
        if (q > 0 && d[q - 1] == 0) q--;
        return Math.max(0, q);
    }

    // ---------------------------------------------------------------- decoder

    /** Call with `lock` held. */
    private void startDecoder() {
        releaseDecoderLocked();
        try {
            MediaFormat fmt = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, videoW, videoH);
            fmt.setByteBuffer("csd-0", ByteBuffer.wrap(sps));
            fmt.setByteBuffer("csd-1", ByteBuffer.wrap(pps));
            if (Build.VERSION.SDK_INT >= 30) fmt.setInteger(MediaFormat.KEY_LOW_LATENCY, 1);
            MediaCodec c = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC);
            c.configure(fmt, surface, null, 0);
            c.start();
            decoder = c;
            waitingForKey = true;
            units.clear();
            pts = 0;
            Link.get().sendLine("CASTKEY");
        } catch (Exception e) {
            decoder = null;
            Link.get().sendLine("LOG cast decoder failed: " + e);
        }
    }

    private void releaseDecoder() { synchronized (lock) { releaseDecoderLocked(); } }

    private void releaseDecoderLocked() {
        if (decoder == null) return;
        try { decoder.stop(); } catch (Exception ignored) {}
        try { decoder.release(); } catch (Exception ignored) {}
        decoder = null;
    }

    private void decodeLoop() {
        MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
        while (running) {
            byte[] au;
            try { au = units.poll(15, TimeUnit.MILLISECONDS); }
            catch (InterruptedException e) { return; }
            synchronized (lock) {
                MediaCodec c = decoder;
                if (c == null) continue;
                try {
                    if (au != null) {
                        int in = c.dequeueInputBuffer(8_000);
                        if (in >= 0) {
                            ByteBuffer buf = c.getInputBuffer(in);
                            if (buf != null && buf.capacity() >= au.length) {
                                buf.clear();
                                buf.put(au);
                                c.queueInputBuffer(in, 0, au.length, pts, 0);
                                pts += 33_333;
                            } else {
                                c.queueInputBuffer(in, 0, 0, pts, 0);
                            }
                        }
                    }
                    // Render whatever is ready, immediately — no presentation clock.
                    while (true) {
                        int out = c.dequeueOutputBuffer(info, 0);
                        if (out >= 0) c.releaseOutputBuffer(out, true);
                        else if (out == MediaCodec.INFO_TRY_AGAIN_LATER) break;
                    }
                } catch (Exception e) {
                    // A codec error mid-stream: rebuild and wait for the next IDR.
                    Link.get().sendLine("LOG cast decode error: " + e);
                    if (sps != null && surface != null) startDecoder();
                }
            }
        }
    }

    // ---------------------------------------------------------------- touch

    private float downX, downY, lastY, travelled;
    private boolean dragging, longPressed, multi;
    private final Runnable longPress = () -> {
        if (travelled < SLOP && !multi) {
            longPressed = true;
            send("AR", downX, downY);
        }
    };

    private void send(String verb, float x, float y) {
        float fx = x / Math.max(1, view.getWidth());
        float fy = y / Math.max(1, view.getHeight());
        Link.get().sendLine(String.format(Locale.US, "%s %.4f %.4f", verb, fx, fy));
    }

    private void onTouch(MotionEvent e) {
        switch (e.getActionMasked()) {
            case MotionEvent.ACTION_DOWN:
                downX = e.getX(); downY = e.getY(); lastY = downY;
                travelled = 0; dragging = false; longPressed = false; multi = false;
                main.postDelayed(longPress, LONG_PRESS_MS);
                break;

            case MotionEvent.ACTION_POINTER_DOWN:
                multi = true;
                main.removeCallbacks(longPress);
                lastY = avgY(e);
                break;

            case MotionEvent.ACTION_MOVE:
                if (multi && e.getPointerCount() >= 2) {
                    float y = avgY(e);
                    float dy = y - lastY;
                    lastY = y;
                    if (Math.abs(dy) >= 1) Link.get().sendLine(String.format(Locale.US, "S %.1f", dy * 1.4f));
                    break;
                }
                travelled = Math.max(travelled, Math.abs(e.getX() - downX) + Math.abs(e.getY() - downY));
                if (longPressed) break;
                if (!dragging && travelled > SLOP) {
                    main.removeCallbacks(longPress);
                    dragging = true;
                    send("AD", downX, downY);
                }
                if (dragging) send("AM", e.getX(), e.getY());
                break;

            case MotionEvent.ACTION_UP:
                main.removeCallbacks(longPress);
                if (dragging) send("AU", e.getX(), e.getY());
                else if (!longPressed && !multi) send("AT", e.getX(), e.getY());
                dragging = false;
                break;

            case MotionEvent.ACTION_CANCEL:
                main.removeCallbacks(longPress);
                if (dragging) send("AU", e.getX(), e.getY());
                dragging = false;
                break;
        }
    }

    private static float avgY(MotionEvent e) {
        float s = 0;
        for (int i = 0; i < e.getPointerCount(); i++) s += e.getY(i);
        return s / e.getPointerCount();
    }
}
