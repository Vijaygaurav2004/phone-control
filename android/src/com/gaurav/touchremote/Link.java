package com.gaurav.touchremote;

import java.io.BufferedReader;
import java.io.DataOutputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.util.ArrayDeque;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * The single connection to the Mac, shared by the UI and the capture service.
 *
 * Two kinds of traffic share it: the original newline-delimited commands, and
 * binary frames carrying video. Magic byte 0xAB is a UTF-8 continuation byte,
 * so it can never begin a legacy text line — the receiver tells them apart by
 * looking at one byte, and nothing already built had to change.
 *
 * Control jumps the queue ahead of video between chunks, so a cursor movement
 * never waits behind a keyframe.
 */
public final class Link {

    public static final int PORT = 8788;
    public static final int DISCOVERY_PORT = 8789;

    public static final byte MAGIC = (byte) 0xAB;
    public static final byte T_TXT = 0x01, T_VID = 0x02, T_VCFG = 0x03;
    public static final int F_KEY = 0x01, F_CONT = 0x02, F_LAST = 0x04, F_DISCONT = 0x08;

    private static final int CHUNK = 8 * 1024;       // bounds how far control sits behind video
    private static final int MAX_VIDEO_BACKLOG = 24; // chunks; beyond this we drop whole frames

    public interface Listener {
        void onLine(String line);
        void onState(boolean connected, String host);
    }

    private static final Link INSTANCE = new Link();
    public static Link get() { return INSTANCE; }
    private Link() {}

    private final ArrayDeque<byte[]> control = new ArrayDeque<>();
    private final ArrayDeque<byte[]> video = new ArrayDeque<>();
    private final Object lock = new Object();
    private final AtomicBoolean started = new AtomicBoolean(false);

    private volatile String host;
    private volatile boolean connected;
    private volatile Listener listener;
    private volatile int droppedFrames;

    public boolean isConnected() { return connected; }
    public String host() { return host; }
    public void setHost(String h) { host = h; }
    public void setListener(Listener l) { listener = l; }

    public void start(String initialHost) {
        host = initialHost;
        if (started.compareAndSet(false, true)) new Thread(this::pump, "link").start();
    }

    // ---------------------------------------------------------------- sending

    /** A legacy command line. Always jumps ahead of queued video. */
    public void sendLine(String line) {
        byte[] body = line.getBytes();
        byte[] frame = header(T_TXT, 0, body.length);
        byte[] out = new byte[frame.length + body.length];
        System.arraycopy(frame, 0, out, 0, frame.length);
        System.arraycopy(body, 0, out, frame.length, body.length);
        synchronized (lock) { control.add(out); lock.notifyAll(); }
    }

    /** Codec config (SPS/PPS) plus geometry — must reach the Mac before any video. */
    public void sendConfig(byte[] csd, int width, int height) {
        byte[] payload = new byte[8 + csd.length];
        putInt(payload, 0, width);
        putInt(payload, 4, height);
        System.arraycopy(csd, 0, payload, 8, csd.length);
        byte[] h = header(T_VCFG, 0, payload.length);
        byte[] out = new byte[h.length + payload.length];
        System.arraycopy(h, 0, out, 0, h.length);
        System.arraycopy(payload, 0, out, h.length, payload.length);
        synchronized (lock) { control.add(out); lock.notifyAll(); }
    }

    /**
     * One encoded access unit, split into chunks so control traffic can
     * interleave. Drops the whole unit if the link is already behind.
     */
    public void sendVideo(byte[] au, int len, boolean keyframe) {
        synchronized (lock) {
            if (video.size() > MAX_VIDEO_BACKLOG) {
                video.clear();              // whole units only — never half an AU
                droppedFrames++;
                if (!keyframe) return;      // wait for the next IDR to resync
            }
            int sent = 0;
            boolean first = true;
            while (sent < len) {
                int n = Math.min(CHUNK, len - sent);
                boolean last = (sent + n) >= len;
                int flags = (keyframe ? F_KEY : 0) | (first ? 0 : F_CONT) | (last ? F_LAST : 0);
                if (droppedFrames > 0 && first && keyframe) flags |= F_DISCONT;
                byte[] h = header(T_VID, flags, n);
                byte[] out = new byte[h.length + n];
                System.arraycopy(h, 0, out, 0, h.length);
                System.arraycopy(au, sent, out, h.length, n);
                video.add(out);
                sent += n;
                first = false;
            }
            if (keyframe) droppedFrames = 0;
            lock.notifyAll();
        }
    }

    private static byte[] header(byte type, int flags, int length) {
        byte[] h = new byte[8];
        h[0] = MAGIC;
        h[1] = type;
        h[2] = (byte) flags;
        h[3] = 0;
        putInt(h, 4, length);
        h[3] = (byte) (h[0] ^ h[1] ^ h[2] ^ h[4] ^ h[5] ^ h[6] ^ h[7]);
        return h;
    }

    private static void putInt(byte[] b, int off, int v) {
        b[off]     = (byte) (v >>> 24);
        b[off + 1] = (byte) (v >>> 16);
        b[off + 2] = (byte) (v >>> 8);
        b[off + 3] = (byte) v;
    }

    // ---------------------------------------------------------------- the link

    private String discover() {
        try (DatagramSocket s = new DatagramSocket()) {
            s.setBroadcast(true);
            s.setSoTimeout(1500);
            byte[] msg = "WHO".getBytes();
            s.send(new DatagramPacket(msg, msg.length,
                    InetAddress.getByName("255.255.255.255"), DISCOVERY_PORT));
            byte[] buf = new byte[128];
            DatagramPacket reply = new DatagramPacket(buf, buf.length);
            s.receive(reply);
            String body = new String(reply.getData(), 0, reply.getLength()).trim();
            if (body.startsWith("MAC ") && body.length() > 4) return body.substring(4).trim();
            return reply.getAddress().getHostAddress();
        } catch (Exception e) {
            return null;
        }
    }

    private void pump() {
        int misses = 0;
        while (true) {
            if (host == null || misses >= 2) {
                notifyState(false);
                String found = discover();
                if (found != null) { host = found; misses = 0; }
            }
            if (host == null) { sleep(1200); continue; }

            Socket s = null;
            try {
                s = new Socket();
                s.connect(new InetSocketAddress(host, PORT), 3000);
                s.setTcpNoDelay(true);
                // A small send buffer is deliberate: it caps how many video
                // bytes the kernel can hold ahead of a cursor update.
                s.setSendBufferSize(64 * 1024);
                final Socket sock = s;
                DataOutputStream out = new DataOutputStream(s.getOutputStream());
                BufferedReader in = new BufferedReader(new InputStreamReader(s.getInputStream()));

                connected = true; misses = 0;
                notifyState(true);
                synchronized (lock) { control.clear(); video.clear(); }

                new Thread(() -> {
                    try {
                        String line;
                        while ((line = in.readLine()) != null) {
                            Listener l = listener;
                            if (l != null) l.onLine(line);
                        }
                    } catch (Exception ignored) {
                    } finally {
                        try { sock.close(); } catch (Exception ignored2) {}
                    }
                }, "link-reader").start();

                writeLoop(out);
            } catch (Exception e) {
                misses++;
            } finally {
                connected = false;
                notifyState(false);
                if (s != null) try { s.close(); } catch (Exception ignored) {}
                sleep(900);
            }
        }
    }

    /** Strict priority: every queued control frame goes before the next video chunk. */
    private void writeLoop(OutputStream out) throws Exception {
        while (true) {
            byte[] next;
            synchronized (lock) {
                while (control.isEmpty() && video.isEmpty()) lock.wait(500);
                next = !control.isEmpty() ? control.poll() : video.poll();
            }
            if (next == null) continue;
            out.write(next);
            synchronized (lock) {
                if (control.isEmpty() && video.isEmpty()) out.flush();
            }
        }
    }

    private void notifyState(boolean up) {
        Listener l = listener;
        if (l != null) l.onState(up, host);
    }

    private static void sleep(long ms) {
        try { Thread.sleep(ms); } catch (InterruptedException ignored) {}
    }
}
