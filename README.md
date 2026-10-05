# Nothing Phone 3a.app

Double-click the icon → your phone appears in a Mac window. Click, type, use it.

**Installed at:** `/Applications/Nothing Phone 3a.app` (also on your Desktop)

---

## Setup — once, and never again

On the phone:

1. Settings → About phone → tap **Build number** seven times
2. Settings → System → Developer options → **USB debugging** → ON
3. Plug the phone into the Mac → tap **Allow** on the popup
   *(tick "Always allow from this computer")*

Then double-click **Nothing Phone 3a**.

That's the whole setup. Developer options and USB debugging stay on permanently —
through reboots, updates, everything. You never touch them again.

There is no way to skip this step. Android requires developer mode for any
screen control, and the only alternative is installing a third-party app on the
phone.

---

## After that

**With the cable in** — open the app, phone's there. Always. Sharpest picture.

**Without the cable** — open the app, phone's there, as long as you've plugged in
at least once since the phone last restarted.

That second part is the trick: every time a cable is connected, the app quietly
learns the phone's Wi-Fi address and opens a network bridge to it. So plugging in
does double duty — it mirrors *and* it sets up the next cable-free session. You
never enable anything on the phone, and you never type an IP.

Phone restarts wipe that bridge (Android clears it on boot — unavoidable without
rooting). Plug in once and it's back.

---

## Using the window

| Key | Does |
|---|---|
| `Cmd+C` / `Cmd+V` | Copy & paste between Mac and phone |
| `Cmd+Shift+V` | Type your Mac clipboard into the phone |
| `Cmd+O` / `Cmd+Shift+O` | Phone's own screen off / on |
| `Cmd+F` | Fullscreen |
| `Cmd+N` | Pull down notifications |
| `Cmd+←` / `Cmd+→` | Rotate |
| drag a file in | Installs an APK, or drops it in `/sdcard/Download` |

Trackpad taps and swipes. Mac keyboard types.

---

## Phone Control — the menu bar app

`/Applications/Phone Control.app` puts a 📱 in your menu bar, with the phone's
battery next to it. Click it for:

| Item | What it does |
|---|---|
| **Open Mirror** | Same as double-clicking the main app |
| **Lock / Unlock / Wake** | Phone power control |
| **Screenshot to Desktop** | Saves a PNG and reveals it in Finder |
| **Start Screen Recording** | Records up to 3 min, pulls the MP4 to your Desktop |
| **Ring Phone** | Full-volume alarm, works even on silent |
| **Stop Ringing** | Silences it |
| **Send Link to Phone** | Opens the URL on your clipboard in the phone's browser |

### Apps in their own windows

**Open App in its Own Window** launches any installed app onto a *new virtual
display* on the phone, shown as its own Mac window.

This is not mirroring. The app runs on a display that doesn't exist physically,
so:

- The phone's own screen stays **off**, and can stay **locked** — Android marks
  these displays `FLAG_ALWAYS_UNLOCKED`, so the lock screen simply doesn't apply
- The phone is completely free — someone else can use it at the same time
- Each app gets its own window; open as many as you like
- You choose the resolution and density, instead of squinting at 20:9

**Window Size** picks the shape: Phone (1200×2000), Tall (1400×2400) or Wide
(1920×1200). Each app remembers the size it was last opened at.

The app list is fetched from the phone and cached, so the menu opens instantly.
**Refresh App List** re-reads it after you install something new.

**Cmd+W** pops the app you currently have open in the mirror into its own
window. It only fires while a phone window is frontmost, so Cmd+W still closes
tabs everywhere else on the Mac.

Some apps — WhatsApp among them — declare themselves non-resizable and get
bounced straight back off a secondary display, leaving the window stuck on a
splash screen. The app sets `force_resizable_activities=1` on the phone before
launching a window, which overrides that. To undo it:

```bash
adb shell settings put global force_resizable_activities 0
```

### Android apps as real Mac apps

**Turn an App into a Mac App** builds a standalone `.app` in
`~/Applications/Phone Apps/` — with the app's own icon, pulled straight out of
the APK on your phone.

From then on it behaves like any Mac app:

- Appears in **Spotlight** — ⌘Space, type "WhatsApp", Enter
- Sits in **Launchpad**, and can be dragged to the **Dock**
- Shows up in **⌘Tab** with its own icon
- Double-click and it opens on its own virtual display — phone stays locked

Each one is self-contained: it finds the phone, reconnects if needed, sets
`force_resizable_activities`, and opens the app. It doesn't need the menu bar
app running.

If the icon can't be read out of the APK (adaptive icons are vector XML, not
always extractable) it falls back to a clean lettered tile.

Built at the currently selected **Window Size**, so pick that first if you want
a wide window rather than a phone-shaped one.

### Phone notifications on the Mac

WhatsApp, Instagram, Messages and the rest pop up as native macOS
notifications, polled every 6 seconds. System spam (`com.android.systemui`,
Play Services, Wellbeing) is filtered out, and known apps get friendly names.

Full message text, not just the one-line summary: it reads `android.bigText`,
`android.textLines` and `android.conversationTitle` as well as `android.text`,
so long WhatsApp messages and stacked group chats come through whole.

On first run it records what's already on the phone without notifying —
otherwise every old notification would fire at once on launch.

Every notification carries an **Open in Window** button that launches that app
in its own window — WhatsApp on your Mac, with the phone still locked in your
pocket, ready to type into.

**Replying from inside the Mac notification isn't possible.** `cmd notification`
has no reply subcommand, so adb cannot trigger an Android notification's
RemoteInput. Opening the app in a window is the reliable equivalent.

Toggle it with **Phone Notifications on Mac**.

### Battery

Shown next to the menu bar icon, refreshed **every 30 seconds** and again the
instant you open the menu, so the number is never stale. A one-time warning
fires at 15% when not charging.

This runs whether or not the mirror is open — the menu bar app is its own
process and talks to the phone over Wi-Fi independently.

When the phone is out of range it shows **—**, never a stale percentage.

### Coming back to Wi-Fi

Every 30-second battery check also re-attaches the phone if it isn't connected,
so walking out and back in picks up on its own within half a minute. It tries
the saved address first, then falls back to mDNS in case the router handed the
phone a different IP — and saves the new one when it does.

The exception is a phone **reboot**, which clears Android's network debug
bridge entirely. That needs one USB plug-in to re-arm.

### Open at Login

Installs a LaunchAgent at
`~/Library/LaunchAgents/local.gaurav.phonecontrol.plist` so the menu bar app
comes back after a restart. Toggling it off unloads and deletes the agent.

### Arrow keys in Reels / Shorts

**↓ next video, ↑ previous** — works in Instagram Reels, YouTube Shorts, TikTok,
anything with a vertical feed.

Those apps ignore D-pad events, which is all scrcpy can send for an arrow key.
So the menu bar app intercepts ↑/↓ itself and fires a real 90ms swipe instead —
short enough to read as a fling, so the feed snaps exactly one item.

The keys are only intercepted while the mirror window is frontmost; everywhere
else on your Mac the arrows behave normally. Turn it off with **Arrow Keys
Scroll Reels** in the menu.

The top line shows live status — whether the phone is on USB or Wi-Fi, and
whether it's locked. It's checked in the background, so the menu never hangs
waiting on the phone.

**Unlock Phone** gets you all the way in only when no PIN is required (Extend
Unlock active). Otherwise it says so — Android refuses a PIN sent from the Mac.

Rebuild it with `./build-menubar.sh`.

## Terminal version

```bash
phone            # mirror
phone --lite     # weak wifi
phone --hq       # max quality
phone --dark     # force the phone's screen off
phone --lit      # force it to stay lit
phone lock       # lock the phone
phone unlock     # wake and unlock it
phone status     # what's connected
phone shell      # a shell on the phone
```

`phone unlock` gets you past the lock screen only when no PIN is required —
i.e. with Extend Unlock active. Otherwise it says so plainly; Android won't
accept a PIN from the Mac by design.

## The phone's own screen

It goes **dark automatically** while you mirror — but only when the phone is
already unlocked when the app opens.

That condition isn't fussiness. Android refuses to render the PIN pad into any
screen capture (measured: 0.1% non-black pixels), so if the display is off while
the phone is locked, you get a black window with no way to type your password.
The app checks the lock state first and only blanks the screen once it's safe.

To get it unlocked automatically, set up **Extend Unlock** on the phone
(Settings → Security & privacy → More security & privacy → Extend Unlock) with
either a trusted place or this Mac as a trusted Bluetooth device. Then the app
wakes the phone, swipes the lock screen away, and blanks the display — you land
on the home screen with the phone dark.

Manual override any time: `Cmd+O` blanks it, `Cmd+Shift+O` brings it back.
Force it with `phone --dark`, prevent it with `phone --lit`.

Closing the window puts the phone to sleep. With the cable in it charges while
you mirror.

---

## One limitation

Works on your local Wi-Fi and over USB. Using it from a *different* network —
you out somewhere, phone on mobile data — needs something bridging the two
networks (a VPN). That's a third-party service, so it's left out. Ask if you
ever want it; the app is built to take it.

---

## Files

- `Nothing Phone 3a.app` — source of truth, copied to `/Applications`.
  A copy of the `scrcpy` binary lives inside it so macOS labels the menu bar and
  Dock "Nothing Phone 3a". `build-app.sh` refreshes that copy, so re-run it after
  a `brew upgrade scrcpy`.
- `launcher.sh` — what runs on double-click
- `make-icon.py` / `build-app.sh` — regenerate icon, rebuild app
- `Phone Control.app` — menu bar app; source in `PhoneControl.swift`,
  built by `build-menubar.sh`
- `phone` — terminal version, symlinked into `~/.local/bin`
- `~/.config/phone-control/last-run.log` — if anything misbehaves, it's in here

Rebuild after editing `launcher.sh`:

```bash
~/phone-control/build-app.sh && rm -rf "/Applications/Nothing Phone 3a.app" && cp -R ~/phone-control/"Nothing Phone 3a.app" /Applications/
```
