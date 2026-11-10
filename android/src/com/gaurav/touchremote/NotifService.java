package com.gaurav.touchremote;

import android.app.ActivityOptions;
import android.app.Notification;
import android.app.PendingIntent;
import android.app.RemoteInput;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.SharedPreferences;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.os.BatteryManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.Parcelable;
import android.service.notification.NotificationListenerService;
import android.service.notification.StatusBarNotification;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Sends the phone's notifications to the Mac and carries replies back.
 *
 * The user turns this on once in Settings → Notifications → Device & app
 * notifications (notification access). After that Android keeps it bound in the
 * background, so this is also what keeps the Mac link alive when the Touch
 * Remote screen is closed — and it reports the battery level, since with
 * developer options off the Mac has no other way to read it.
 *
 * Wire format, one line each, fields separated by tabs:
 *   phone → Mac   NOTIF id app title body canReply package
 *                 NOTIFGONE id
 *                 BATT level charging(0|1)
 *   Mac → phone   REPLY id text
 *                 NOTIFOPEN id
 *                 NOTIFDISMISS id
 *                 MARKREAD id
 */
public class NotifService extends NotificationListenerService {

    private static final String ME = "com.gaurav.touchremote";
    /** On reconnect, re-send only what is fresh — the Mac de-dupes, but a Mac
     *  restart would otherwise replay the whole shade as new banners. */
    private static final long RESEND_WINDOW_MS = 5 * 60 * 1000;

    private static volatile NotifService instance;
    public static boolean running() { return instance != null; }

    private final Map<String, String> keys = new ConcurrentHashMap<>();   // id → sbn key
    private final Handler main = new Handler(Looper.getMainLooper());
    private int lastLevel = -1;
    private boolean lastCharging;
    private boolean batteryRegistered;

    private final BroadcastReceiver battery = new BroadcastReceiver() {
        @Override public void onReceive(Context c, Intent i) {
            int level = i.getIntExtra(BatteryManager.EXTRA_LEVEL, -1);
            int scale = i.getIntExtra(BatteryManager.EXTRA_SCALE, 100);
            int plugged = i.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0);
            if (level < 0 || scale <= 0) return;
            int pct = Math.round(level * 100f / scale);
            boolean charging = plugged != 0;
            if (pct == lastLevel && charging == lastCharging) return;
            lastLevel = pct; lastCharging = charging;
            sendBattery();
        }
    };

    // ------------------------------------------------------------ lifecycle

    @Override public void onListenerConnected() {
        instance = this;
        Link link = Link.get();
        link.setSideListener(new Link.Listener() {
            public void onLine(String line) { fromMac(line); }
            public void onState(boolean up, String host) {
                if (up) main.postDelayed(NotifService.this::onMacConnected, 400);
            }
        });
        SharedPreferences prefs = getSharedPreferences("touchremote", MODE_PRIVATE);
        link.start(prefs.getString("host", null));

        if (!batteryRegistered) {
            registerReceiver(battery, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
            batteryRegistered = true;
        }
        if (link.isConnected()) onMacConnected();
    }

    @Override public void onListenerDisconnected() {
        instance = null;
        Link.get().setSideListener(null);
        if (batteryRegistered) {
            try { unregisterReceiver(battery); } catch (Exception ignored) {}
            batteryRegistered = false;
        }
    }

    @Override public void onDestroy() {
        onListenerDisconnected();
        super.onDestroy();
    }

    /** The Mac (re)connected: say notifications come from here now, then catch up. */
    private void onMacConnected() {
        if (instance == null) return;
        Link.get().sendLine("NOTIFAPP on");
        sendBattery();
        try {
            StatusBarNotification[] active = getActiveNotifications();
            if (active == null) return;
            long cutoff = System.currentTimeMillis() - RESEND_WINDOW_MS;
            for (StatusBarNotification sbn : active) {
                try {
                    if (sbn.getPostTime() >= cutoff) forward(sbn);
                    else remember(sbn);     // still repliable from the Mac later
                } catch (Exception ignored) {}
            }
        } catch (Exception ignored) {}
    }

    private void sendBattery() {
        if (lastLevel >= 0) Link.get().sendLine("BATT " + lastLevel + " " + (lastCharging ? 1 : 0));
    }

    // ------------------------------------------------------------ phone → Mac

    @Override public void onNotificationPosted(StatusBarNotification sbn) {
        // One app's odd notification must never take down the forwarder.
        try { forward(sbn); } catch (Exception e) { Link.get().sendLine("LOG notif forward: " + e); }
    }

    @Override public void onNotificationRemoved(StatusBarNotification sbn) {
        String id = idFor(sbn.getKey());
        if (keys.remove(id) != null) Link.get().sendLine("NOTIFGONE " + id);
    }

    private static String idFor(String key) {
        return Integer.toHexString(key.hashCode());
    }

    private String remember(StatusBarNotification sbn) {
        String id = idFor(sbn.getKey());
        keys.put(id, sbn.getKey());
        return id;
    }

    private void forward(StatusBarNotification sbn) {
        if (!worthSending(sbn)) return;
        Notification n = sbn.getNotification();
        Bundle x = n.extras;
        if (x == null) return;

        String title = str(x.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE));
        if (title.isEmpty()) title = str(x.getCharSequence(Notification.EXTRA_TITLE_BIG));
        if (title.isEmpty()) title = str(x.getCharSequence(Notification.EXTRA_TITLE));

        // After you reply (from the Mac or the phone) chat apps re-post the
        // conversation ending in your own message. That's not news.
        if (lastFromMe(x)) { remember(sbn); return; }

        String body = messages(x);
        if (body.isEmpty()) body = str(x.getCharSequence(Notification.EXTRA_BIG_TEXT));
        if (body.isEmpty()) {
            CharSequence[] lines = x.getCharSequenceArray(Notification.EXTRA_TEXT_LINES);
            if (lines != null && lines.length > 0) {
                StringBuilder b = new StringBuilder();
                for (CharSequence l : lines) { if (b.length() > 0) b.append('\n'); b.append(l); }
                body = b.toString();
            }
        }
        if (body.isEmpty()) body = str(x.getCharSequence(Notification.EXTRA_TEXT));
        if (title.isEmpty() && body.isEmpty()) return;

        String id = remember(sbn);
        boolean canReply = replyAction(n) != null;
        Link.get().sendLine("NOTIF " + id
                + "\t" + clean(appLabel(sbn))
                + "\t" + clean(title)
                + "\t" + clean(body)
                + "\t" + (canReply ? 1 : 0)
                + "\t" + sbn.getPackageName());
    }

    private boolean worthSending(StatusBarNotification sbn) {
        if (ME.equals(sbn.getPackageName())) return false;
        if (!sbn.isClearable()) return false;                         // ongoing: music, calls, timers
        int f = sbn.getNotification().flags;
        if ((f & Notification.FLAG_GROUP_SUMMARY) != 0) return false;  // "5 messages from 2 chats"
        if ((f & Notification.FLAG_FOREGROUND_SERVICE) != 0) return false;
        Bundle x = sbn.getNotification().extras;
        if (x != null && x.getInt(Notification.EXTRA_PROGRESS_MAX, 0) > 0) return false;  // downloads
        return true;
    }

    /**
     * Chat apps (WhatsApp, Messages, Telegram) put the real conversation here.
     * Newest first: a Mac banner shows only the first couple of lines, and the
     * message that just arrived is the one you need to read.
     */
    private static String messages(Bundle x) {
        Parcelable[] ms = x.getParcelableArray(Notification.EXTRA_MESSAGES);
        if (ms == null || ms.length == 0) return "";
        boolean group = x.getBoolean(Notification.EXTRA_IS_GROUP_CONVERSATION, false)
                || x.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE) != null;
        StringBuilder b = new StringBuilder();
        int shown = 0;
        for (int i = ms.length - 1; i >= 0 && shown < 6; i--) {
            if (!(ms[i] instanceof Bundle)) continue;
            Bundle m = (Bundle) ms[i];
            String text = str(m.getCharSequence("text"));
            if (text.isEmpty()) continue;
            String sender = str(m.getCharSequence("sender"));
            Object p = m.get("sender_person");
            if (sender.isEmpty() && p instanceof android.app.Person) sender = str(((android.app.Person) p).getName());
            boolean mine = m.getCharSequence("sender") == null && p == null;
            if (b.length() > 0) b.append('\n');
            if (mine) b.append("You: ");
            else if (group && !sender.isEmpty()) b.append(sender).append(": ");
            b.append(text);
            shown++;
        }
        return b.toString();
    }

    /** In MessagingStyle a message with no sender is one the user sent. */
    private static boolean lastFromMe(Bundle x) {
        Parcelable[] ms = x.getParcelableArray(Notification.EXTRA_MESSAGES);
        if (ms == null || ms.length == 0 || !(ms[ms.length - 1] instanceof Bundle)) return false;
        Bundle m = (Bundle) ms[ms.length - 1];
        return m.getCharSequence("sender") == null && m.get("sender_person") == null;
    }

    private String appLabel(StatusBarNotification sbn) {
        PackageManager pm = getPackageManager();
        try {
            Bundle x = sbn.getNotification().extras;
            Object ai = x == null ? null : x.get("android.appInfo");   // Notification.EXTRA_BUILDER_APPLICATION_INFO
            if (ai instanceof ApplicationInfo) return pm.getApplicationLabel((ApplicationInfo) ai).toString();
        } catch (Exception ignored) {}
        try {
            return pm.getApplicationLabel(pm.getApplicationInfo(sbn.getPackageName(), 0)).toString();
        } catch (Exception e) {
            return sbn.getPackageName();
        }
    }

    // ------------------------------------------------------------ Mac → phone

    private void fromMac(String line) {
        try {
            if (line.startsWith("REPLY ")) {
                String rest = line.substring(6);
                int tab = rest.indexOf('\t');
                if (tab <= 0) return;
                String text = rest.substring(tab + 1).replace("\\n", "\n");
                reply(rest.substring(0, tab), text);
            } else if (line.startsWith("NOTIFOPEN ")) {
                open(line.substring(10).trim());
            } else if (line.startsWith("NOTIFDISMISS ")) {
                String key = keys.get(line.substring(13).trim());
                if (key != null) cancelNotification(key);
            } else if (line.startsWith("MARKREAD ")) {
                markRead(line.substring(9).trim());
            }
        } catch (Exception e) {
            Link.get().sendLine("LOG notif: " + e);
        }
    }

    private StatusBarNotification find(String id) {
        String key = keys.get(id);
        if (key == null) return null;
        try {
            StatusBarNotification[] a = getActiveNotifications(new String[]{key});
            return a != null && a.length > 0 ? a[0] : null;
        } catch (Exception e) {
            return null;
        }
    }

    private static Notification.Action replyAction(Notification n) {
        if (n.actions == null) return null;
        Notification.Action fallback = null;
        for (Notification.Action a : n.actions) {
            RemoteInput[] ri = a.getRemoteInputs();
            if (ri == null || ri.length == 0) continue;
            boolean freeText = false;
            for (RemoteInput r : ri) if (r.getAllowFreeFormInput()) freeText = true;
            if (!freeText) continue;
            if (Build.VERSION.SDK_INT >= 28 && a.getSemanticAction() == Notification.Action.SEMANTIC_ACTION_REPLY)
                return a;
            if (fallback == null) fallback = a;
        }
        return fallback;
    }

    private void reply(String id, String text) throws Exception {
        StatusBarNotification sbn = find(id);
        Notification.Action a = sbn == null ? null : replyAction(sbn.getNotification());
        if (a == null || a.actionIntent == null) {
            Link.get().sendLine("NOTIFFAIL " + id + "\tThat notification is gone or can't be replied to.");
            return;
        }
        Intent fill = new Intent();
        Bundle results = new Bundle();
        for (RemoteInput r : a.getRemoteInputs()) results.putCharSequence(r.getResultKey(), text);
        RemoteInput.addResultsToIntent(a.getRemoteInputs(), fill, results);
        a.actionIntent.send(this, 0, fill);
        Link.get().sendLine("NOTIFSENT " + id);
    }

    private void markRead(String id) throws Exception {
        StatusBarNotification sbn = find(id);
        if (sbn == null || sbn.getNotification().actions == null || Build.VERSION.SDK_INT < 28) return;
        for (Notification.Action a : sbn.getNotification().actions) {
            if (a.getSemanticAction() == Notification.Action.SEMANTIC_ACTION_MARK_AS_READ && a.actionIntent != null) {
                a.actionIntent.send();
                return;
            }
        }
        cancelNotification(sbn.getKey());   // no read action: at least clear it
    }

    private void open(String id) throws Exception {
        StatusBarNotification sbn = find(id);
        if (sbn == null) return;
        PendingIntent pi = sbn.getNotification().contentIntent;
        if (pi == null) return;
        if (Build.VERSION.SDK_INT >= 34) {
            ActivityOptions o = ActivityOptions.makeBasic();
            o.setPendingIntentBackgroundActivityStartMode(ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED);
            pi.send(this, 0, null, null, null, null, o.toBundle());
        } else {
            pi.send();
        }
        if ((sbn.getNotification().flags & Notification.FLAG_AUTO_CANCEL) != 0) cancelNotification(sbn.getKey());
    }

    // ------------------------------------------------------------ helpers

    private static String str(CharSequence c) { return c == null ? "" : c.toString().trim(); }

    /** Tabs separate fields and newlines end lines, so neither may appear raw. */
    private static String clean(String s) {
        String t = s.replace('\t', ' ').replace("\r", "").replace("\n", "\\n");
        return t.length() > 1500 ? t.substring(0, 1500) + "…" : t;
    }
}
