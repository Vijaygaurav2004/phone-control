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

    /** Binary frames from the Mac — its screen, when the phone is viewing it. */
    public interface FrameListener {
        void onFrame(int type, int flags, byte[] payload);
        void onText(String line);
    }

    private volatile FrameListener frameListener;
    public void setFrameListener(FrameListener l) { frameListener = l; }

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
    /** A new listener hears the current state at once. Android rebuilds the
     *  screen on config changes (locale, dark mode, fonts); without this the
     *  rebuilt screen says "looking for your Mac" over a live link until the
     *  next reconnect. */
    public void setListener(Listener l) {
        listener = l;
        if (l != null && host != null) l.onState(connected, host);
    }

    /** A second listener for background parts (the notification forwarder),
     *  so they keep working whether or not the main screen is open. */
    private volatile Listener side;
    public void setSideListener(Listener l) {
        side = l;
        if (l != null && host != null) l.onState(connected, host);
    }

    public void start(String initialHost) {
        // Several parts start the link; a caller without a saved host must not
        // wipe out the one another part already found.
        if (initialHost != null || host == null) host = initialHost;
        if (started.compareAndSet(false, true)) new Thread(this::pump, "link").start();
    }

    // ---------------------------------------------------------------- sending

    /** A legacy command line. Always jumps ahead of queued video. */
    public void sendLine(String line) {
        byte[] body = line.getBytes(java.nio.charset.StandardCharsets.UTF_8);
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

    /**
     * Ask the local network where the Mac is.
     *
     * Android frequently refuses to send a limited broadcast (255.255.255.255)
     * out of the Wi-Fi interface, so the subnet's own broadcast address is sent
     * to as well — that's the one that actually reaches the Mac. Without it a
     * stale saved address from an old network could never be replaced.
     */
    private String discover() {
        java.util.List<InetAddress> targets = new java.util.ArrayList<>();
        try {
            java.util.Enumeration<java.net.NetworkInterface> ifs =
                    java.net.NetworkInterface.getNetworkInterfaces();
            while (ifs != null && ifs.hasMoreElements()) {
                java.net.NetworkInterface ni = ifs.nextElement();
                if (!ni.isUp() || ni.isLoopback()) continue;
                for (java.net.InterfaceAddress ia : ni.getInterfaceAddresses()) {
                    InetAddress b = ia.getBroadcast();
                    if (b != null) targets.add(b);
                }
            }
        } catch (Exception ignored) {}
        try { targets.add(InetAddress.getByName("255.255.255.255")); } catch (Exception ignored) {}

        try (DatagramSocket s = new DatagramSocket()) {
            s.setBroadcast(true);
            s.setSoTimeout(1200);
            byte[] msg = "WHO".getBytes();
            for (InetAddress t : targets) {
                try { s.send(new DatagramPacket(msg, msg.length, t, DISCOVERY_PORT)); }
                catch (Exception ignored) {}
            }
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
                if (found != null) {
                    host = found;
                    misses = 0;
                    Listener l = listener;
                    if (l != null) l.onState(false, found);   // lets the UI save it
                }
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
                // The Mac pings every 4 s, so 20 s of silence means the link is
                // dead even if no FIN ever arrived (Mac asleep, Wi-Fi roam).
                s.setSoTimeout(20000);
                s.setKeepAlive(true);
                final Socket sock = s;
                final AtomicBoolean readerAlive = new AtomicBoolean(true);
                DataOutputStream out = new DataOutputStream(s.getOutputStream());
                java.io.InputStream in = new java.io.BufferedInputStream(s.getInputStream(), 64 * 1024);

                connected = true; misses = 0;
                notifyState(true);
                synchronized (lock) { control.clear(); video.clear(); }

                new Thread(() -> {
                    try {
                        readLoop(in);
                    } catch (Exception ignored) {
                    } finally {
                        readerAlive.set(false);
                        try { sock.close(); } catch (Exception ignored2) {}
                        synchronized (lock) { lock.notifyAll(); }
                    }
                }, "link-reader").start();

                writeLoop(out, readerAlive);
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

    /**
     * The Mac now sends binary frames as well as text lines, so this reads
     * bytes rather than lines. A frame can only begin at a line boundary, and
     * its first byte 0xAB can never start a UTF-8 line — the same rule the Mac
     * uses in the other direction.
     */
    private void readLoop(java.io.InputStream in) throws java.io.IOException {
        java.io.ByteArrayOutputStream line = new java.io.ByteArrayOutputStream(256);
        byte[] h = new byte[8];
        while (true) {
            int b = in.read();
            if (b < 0) return;
            if (b == 0xAB && line.size() == 0) {
                h[0] = (byte) b;
                readFully(in, h, 1, 7);
                int check = (h[0] ^ h[1] ^ h[2] ^ h[4] ^ h[5] ^ h[6] ^ h[7]) & 0xFF;
                if (check != (h[3] & 0xFF)) continue;   // not really a frame
                int len = ((h[4] & 0xFF) << 24) | ((h[5] & 0xFF) << 16)
                        | ((h[6] & 0xFF) << 8) | (h[7] & 0xFF);
                if (len < 0 || len > 4 * 1024 * 1024) continue;
                byte[] payload = new byte[len];
                readFully(in, payload, 0, len);
                FrameListener fl = frameListener;
                if (fl != null) fl.onFrame(h[1] & 0xFF, h[2] & 0xFF, payload);
            } else if (b == '\n') {
                String text = line.toString("UTF-8");
                line.reset();
                if (text.isEmpty()) continue;
                Listener l = listener;
                if (l != null) l.onLine(text);
                Listener sl = side;
                if (sl != null) sl.onLine(text);
                FrameListener fl = frameListener;
                if (fl != null && text.startsWith("CAST")) fl.onText(text);
            } else {
                line.write(b);
            }
        }
    }

    private static void readFully(java.io.InputStream in, byte[] buf, int off, int len)
            throws java.io.IOException {
        while (len > 0) {
            int n = in.read(buf, off, len);
            if (n < 0) throw new java.io.EOFException();
            off += n; len -= n;
        }
    }

    /** Strict priority: every queued control frame goes before the next video chunk. */
    /**
     * Ends (by throwing) when the reader sees the socket die, and pings the Mac
     * whenever nothing else has been sent for a few seconds. Without both, a
     * link with no UI open (just the notification forwarder) would never notice
     * the Mac restarting or the Wi-Fi dropping, and stay "connected" to nothing.
     */
    private void writeLoop(OutputStream out, AtomicBoolean readerAlive) throws Exception {
        long lastSent = System.currentTimeMillis();
        while (true) {
            byte[] next;
            synchronized (lock) {
                while (control.isEmpty() && video.isEmpty()) {
                    if (!readerAlive.get()) throw new java.io.EOFException("reader closed");
                    if (System.currentTimeMillis() - lastSent > 3000) break;
                    lock.wait(500);
                }
                next = !control.isEmpty() ? control.poll() : video.poll();
            }
            if (!readerAlive.get()) throw new java.io.EOFException("reader closed");
            if (next == null) next = pingFrame();
            lastSent = System.currentTimeMillis();
            out.write(next);
            synchronized (lock) {
                if (control.isEmpty() && video.isEmpty()) out.flush();
            }
        }
    }

    private static byte[] pingFrame() {
        byte[] body = "PING".getBytes(java.nio.charset.StandardCharsets.UTF_8);
        byte[] h = header(T_TXT, 0, body.length);
        byte[] out = new byte[h.length + body.length];
        System.arraycopy(h, 0, out, 0, h.length);
        System.arraycopy(body, 0, out, h.length, body.length);
        return out;
    }

    private void notifyState(boolean up) {
        Listener l = listener;
        if (l != null) l.onState(up, host);
        Listener sl = side;
        if (sl != null) sl.onState(up, host);
    }

    private static void sleep(long ms) {
        try { Thread.sleep(ms); } catch (InterruptedException ignored) {}
    }
}
