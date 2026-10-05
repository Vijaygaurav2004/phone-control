package com.gaurav.touchremote;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.media.projection.MediaProjection;
import android.media.projection.MediaProjectionManager;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.util.DisplayMetrics;
import android.view.Surface;
import android.view.WindowManager;

import java.nio.ByteBuffer;

/**
 * Captures the screen and streams H.264 to the Mac — with no adb and no
 * developer options. The user grants this once through the system's own
 * consent dialog.
 *
 * The call order below is not stylistic. On API 34+ each step is enforced:
 * the foreground service must exist, and be foregrounded with the
 * mediaProjection type, BEFORE getMediaProjection() is legal; and a callback
 * must be registered before createVirtualDisplay() or it throws.
 */
public class ScreenCaptureService extends Service {

    public static final String EXTRA_CODE = "code";
    public static final String EXTRA_DATA = "data";
    public static final String ACTION_STOP = "stop";

    private static final String CHANNEL = "mirror";
    private static final int NOTIF_ID = 42;
    private static final int TARGET_WIDTH = 800;     // scaled down; the Mac window is small
    private static final int BITRATE = 6_000_000;
    private static final int FPS = 30;

    private MediaProjection projection;
    private VirtualDisplay display;
    private MediaCodec codec;
    private Surface inputSurface;
    private volatile boolean running;

    public static volatile boolean active;

    @Override public IBinder onBind(Intent i) { return null; }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && ACTION_STOP.equals(intent.getAction())) {
            stopSelf();
            return START_NOT_STICKY;
        }
        if (intent == null) { stopSelf(); return START_NOT_STICKY; }

        // Step 1: be a foreground service of the right type FIRST. Calling
        // getMediaProjection() before this throws SecurityException on API 34+.
        startForegroundCompat();

        int code = intent.getIntExtra(EXTRA_CODE, 0);
        Intent data = intent.getParcelableExtra(EXTRA_DATA);
        if (data == null) { stopSelf(); return START_NOT_STICKY; }

        try {
            MediaProjectionManager mpm =
                    (MediaProjectionManager) getSystemService(Context.MEDIA_PROJECTION_SERVICE);
            projection = mpm.getMediaProjection(code, data);
            if (projection == null) { stopSelf(); return START_NOT_STICKY; }

            // Step 2: register the callback BEFORE creating a virtual display.
            // Required from API 34 — otherwise createVirtualDisplay() throws.
            projection.registerCallback(new MediaProjection.Callback() {
                @Override public void onStop() { teardown(); stopSelf(); }
            }, new Handler(Looper.getMainLooper()));

            startEncoder();
            active = true;
        } catch (Exception e) {
            Link.get().sendLine("LOG capture failed: " + e);
            teardown();
            stopSelf();
        }
        return START_NOT_STICKY;
    }

    private void startForegroundCompat() {
        NotificationManager nm = getSystemService(NotificationManager.class);
        if (Build.VERSION.SDK_INT >= 26 && nm != null
                && nm.getNotificationChannel(CHANNEL) == null) {
            NotificationChannel ch = new NotificationChannel(
                    CHANNEL, "Screen mirroring", NotificationManager.IMPORTANCE_LOW);
            ch.setShowBadge(false);
            nm.createNotificationChannel(ch);
        }
        Notification n = new Notification.Builder(this, CHANNEL)
                .setContentTitle("Mirroring to your Mac")
                .setContentText("Tap Stop in the app to end")
                .setSmallIcon(android.R.drawable.ic_menu_view)
                .setOngoing(true)
                .build();

        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION);
        } else {
            startForeground(NOTIF_ID, n);
        }
    }

    private void startEncoder() throws Exception {
        WindowManager wm = (WindowManager) getSystemService(Context.WINDOW_SERVICE);
        DisplayMetrics dm = new DisplayMetrics();
        wm.getDefaultDisplay().getRealMetrics(dm);

        // Encoders want even dimensions; odd ones fail to configure on some chips.
        int w = TARGET_WIDTH & ~1;
        int h = (int) (((long) dm.heightPixels * w) / dm.widthPixels) & ~1;

        MediaFormat fmt = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, w, h);
        fmt.setInteger(MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface);
        fmt.setInteger(MediaFormat.KEY_BIT_RATE, BITRATE);
        fmt.setInteger(MediaFormat.KEY_FRAME_RATE, FPS);
        fmt.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2);
        if (Build.VERSION.SDK_INT >= 29) {
            fmt.setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0);   // B-frames add latency
        }

        codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC);
        codec.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
        inputSurface = codec.createInputSurface();
        codec.start();

        display = projection.createVirtualDisplay(
                "mirror", w, h, dm.densityDpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                inputSurface, null, null);

        Link.get().sendLine("LOG mirror " + w + "x" + h);
        running = true;
        new Thread(() -> drain(w, h), "encoder").start();
    }

    /** Pull encoded units off the codec and hand them to the link. */
    private void drain(int w, int h) {
        MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
        while (running) {
            int index;
            try {
                index = codec.dequeueOutputBuffer(info, 50_000);
            } catch (IllegalStateException e) {
                break;   // codec went away underneath us
            }
            if (index < 0) continue;

            ByteBuffer buf = codec.getOutputBuffer(index);
            if (buf != null && info.size > 0) {
                buf.position(info.offset);
                buf.limit(info.offset + info.size);
                byte[] bytes = new byte[info.size];
                buf.get(bytes);

                boolean isConfig = (info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0;
                boolean isKey = (info.flags & MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0;
                if (isConfig) {
                    // SPS/PPS — the Mac cannot decode a single frame without these.
                    Link.get().sendConfig(bytes, w, h);
                } else {
                    Link.get().sendVideo(bytes, bytes.length, isKey);
                }
            }
            try { codec.releaseOutputBuffer(index, false); } catch (Exception ignored) {}
            if ((info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) break;
        }
    }

    /** Ask the encoder for an IDR — used when the Mac says it lost sync. */
    public static void requestKeyframe() {
        ScreenCaptureService s = instance;
        if (s == null || s.codec == null) return;
        try {
            android.os.Bundle b = new android.os.Bundle();
            b.putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0);
            s.codec.setParameters(b);
        } catch (Exception ignored) {}
    }

    private static volatile ScreenCaptureService instance;

    @Override public void onCreate() { super.onCreate(); instance = this; }

    @Override public void onDestroy() {
        teardown();
        instance = null;
        active = false;
        super.onDestroy();
    }

    private void teardown() {
        running = false;
        try { if (display != null) display.release(); } catch (Exception ignored) {}
        try { if (codec != null) { codec.stop(); codec.release(); } } catch (Exception ignored) {}
        try { if (inputSurface != null) inputSurface.release(); } catch (Exception ignored) {}
        try { if (projection != null) projection.stop(); } catch (Exception ignored) {}
        display = null; codec = null; inputSurface = null; projection = null;
        Link.get().sendLine("LOG mirror stopped");
    }
}
