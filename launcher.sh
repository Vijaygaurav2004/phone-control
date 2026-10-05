#!/bin/bash
# Nothing Phone 3a.app — double-click, see your phone.
#
# USB if a cable is in, otherwise Wi-Fi using the address learned last time
# a cable was in. Everything polls instead of sleeping, so it opens as soon
# as the phone answers rather than on a fixed timer.

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RES="$(cd "$HERE/../Resources" 2>/dev/null && pwd)"
CONFIG_DIR="$HOME/.config/phone-control"
CONFIG="$CONFIG_DIR/config"
mkdir -p "$CONFIG_DIR"
exec 2>"$CONFIG_DIR/last-run.log"
set -x   # timings land in last-run.log

[ -n "$RES" ] && [ -f "$RES/icon.png" ] && export SCRCPY_ICON_PATH="$RES/icon.png"
TITLE="Nothing Phone 3a"

notify() { osascript -e "display notification \"$1\" with title \"$TITLE\"" >/dev/null 2>&1 & }

fail() {
  osascript >/dev/null 2>&1 <<OSA
activate
display dialog "$1" with title "$TITLE" buttons {"OK"} default button "OK" with icon caution
OSA
  exit 1
}

PHONE_ADDR=""; SCREEN_W=""; SCREEN_H=""
[ -f "$CONFIG" ] && . "$CONFIG"
PHONE_ADDR="${PHONE_ADDR:-}"; SCREEN_W="${SCREEN_W:-}"; SCREEN_H="${SCREEN_H:-}"
write_config() {
  printf 'PHONE_ADDR="%s"\nSCREEN_W="%s"\nSCREEN_H="%s"\n' "$PHONE_ADDR" "$SCREEN_W" "$SCREEN_H" > "$CONFIG"
}
save_addr() { PHONE_ADDR="$1"; write_config; }

devices()     { adb devices 2>/dev/null; }
connected()   { devices | grep -q "^$1[[:space:]]*device$"; }
usb_serial()  { devices | awk '$2=="device" && $1 !~ /:/ {print $1; exit}'; }
unauthorized(){ devices | grep -q 'unauthorized'; }
# Grep on the phone, not here — dumpsys window is a big dump and shipping the
# whole thing over the wire costs ~3x as long as filtering at the source.
locked() { adb -s "$1" shell "dumpsys window | grep -m1 mDreamingLockscreen" 2>/dev/null | grep -q 'mDreamingLockscreen=true'; }

# Poll until $1 is connected, giving up after $2 tenths of a second.
wait_connected() {
  local t="$1" n="${2:-25}" i=0
  while [ "$i" -lt "$n" ]; do
    connected "$t" && return 0
    sleep 0.2; i=$((i+1))
  done
  return 1
}

# Instant feedback — the app has no Dock icon, so without this the first couple
# of seconds look like nothing happened.
notify "Opening…"

adb start-server >/dev/null 2>&1

TARGET=""; MODE=""

# ------------------------------------------------------------ USB
if unauthorized; then
  fail "Your phone is asking permission.

Look at the phone — there's an  Allow USB debugging?  popup.
Tick  Always allow from this computer, then tap  Allow.

Then open this app again."
fi

serial="$(usb_serial)"
if [ -n "$serial" ]; then
  TARGET="$serial"; MODE="usb"

  # Learn the Wi-Fi address so cable-free launches work later. Only restart the
  # phone's debug bridge if wireless isn't already listening — that restart is
  # slow and makes Android re-ask permission.
  ip="$(adb -s "$serial" shell ip -o -4 addr show wlan0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | tr -d '\r')"
  if [ -n "$ip" ]; then
    if [ "$PHONE_ADDR" = "$ip:5555" ] && connected "$ip:5555"; then
      :                                        # already armed, nothing to do
    else
      adb connect "$ip:5555" >/dev/null 2>&1
      if wait_connected "$ip:5555" 8; then
        save_addr "$ip:5555"
      elif adb -s "$serial" tcpip 5555 >/dev/null 2>&1; then
        save_addr "$ip:5555"
        wait_connected "$serial" 60 || { TARGET=""; MODE=""; }
      fi
    fi
  fi
fi

# ------------------------------------------------------------ Wi-Fi
if [ -z "$TARGET" ] && [ -n "$PHONE_ADDR" ]; then
  connected "$PHONE_ADDR" || adb connect "$PHONE_ADDR" >/dev/null 2>&1
  wait_connected "$PHONE_ADDR" 20 && { TARGET="$PHONE_ADDR"; MODE="wifi"; }
fi

# Last resort: the phone advertising itself via Wireless debugging
if [ -z "$TARGET" ]; then
  notify "Looking for your phone…"
  found=""
  for _ in 1 2 3 4; do
    found="$(adb mdns services 2>/dev/null | awk -F'\t' '/_adb-tls-connect/ {print $3; exit}')"
    [ -n "$found" ] && break
    sleep 0.5
  done
  if [ -n "$found" ]; then
    adb connect "$found" >/dev/null 2>&1
    wait_connected "$found" 20 && { TARGET="$found"; MODE="wifi"; save_addr "$found"; }
  fi
fi

# ------------------------------------------------------------ nothing found
if [ -z "$TARGET" ]; then
  if unauthorized; then
    fail "Your phone is asking permission.

Tap  Allow  on the phone's  Allow USB debugging?  popup,
ticking  Always allow from this computer  first.

Then open this app again."
  elif [ -f "$CONFIG_DIR/setup-done" ]; then
    fail "Can't reach your phone right now.

Mirroring needs USB debugging, so check the phone has:
  Settings → System → Developer options → USB debugging

If that's already on, plug in the USB cable and open this app again — that always works, and it re-arms the wireless connection at the same time.

(The Touch Remote app does NOT need any of this.)"
  else
    fail "Let's get this set up — you only do this once.

On the phone:
  1.  Settings → About phone
      tap  Build number  seven times
  2.  Settings → System → Developer options
      turn on  USB debugging
  3.  Plug the phone into this Mac with a cable
      tap  Allow  on the popup

Then open this app again."
  fi
fi

touch "$CONFIG_DIR/setup-done"

# ------------------------------------------------------------ wake & unlock
adb -s "$TARGET" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1

if locked "$TARGET"; then
  # Screen size never changes — look it up once, then read it from the config.
  if [ -z "$SCREEN_W" ] || [ -z "$SCREEN_H" ]; then
    size="$(adb -s "$TARGET" shell wm size 2>/dev/null | tr -d '\r' | awk -F'[ x]' '/Physical/{print $(NF-1), $NF}')"
    SCREEN_W="${size% *}"; SCREEN_H="${size#* }"
    [ -n "$SCREEN_W" ] && [ -n "$SCREEN_H" ] && write_config
  fi
  if [ -n "$SCREEN_W" ] && [ -n "$SCREEN_H" ]; then
    adb -s "$TARGET" shell input swipe \
      "$((SCREEN_W/2))" "$((SCREEN_H*85/100))" "$((SCREEN_W/2))" "$((SCREEN_H*25/100))" >/dev/null 2>&1
  fi
fi

# Android won't render the PIN pad into a capture, so the phone has to be
# unlocked in your hand regardless. Wait for that here rather than opening a
# window we'd then have to leave lit — once unlocked, the display can go dark.
# Never block on the lock screen — opening the mirror always wins. If the phone
# is locked we simply skip blanking its display, because Android won't render
# the PIN pad into a capture and you'd get a black window with no way in.
if locked "$TARGET"; then
  SCREEN_OFF=""
  notify "Unlock the phone to blank its screen"
else
  SCREEN_OFF="--turn-screen-off"
fi

# ------------------------------------------------------------ mirror
# No --power-off-on-close: sleeping the phone on exit re-locks it, which would
# force a manual unlock before every single session.
args=(
  -s "$TARGET"
  --window-title "$TITLE"
  --stay-awake
  --keyboard=uhid
)
[ -n "$SCREEN_OFF" ] && args+=("$SCREEN_OFF")

# h265 on the phone's hardware encoder: same picture for noticeably less data
# than h264, which keeps high-motion video (Reels, Shorts) from breaking up.
# The buffers absorb wireless jitter — 50ms of audio isn't enough over Wi-Fi and
# is what makes voices crackle and drop.
args+=(--video-codec=h265)

# 30fps on battery: Reels, Shorts and Android's UI are 30fps sources anyway, so
# the picture is unchanged while the Mac does roughly half the decoding and
# compositing. On USB the Mac is charging, so spend the frames there.
if [ "$MODE" = "usb" ]; then
  args+=(--video-bit-rate 16M --max-fps 60 --max-size 1200 --audio-buffer=100)
else
  args+=(--video-bit-rate 6M --max-fps 30 --max-size 1080 --audio-buffer=180 --video-buffer=50)
fi

# Prefer the copy inside the bundle — running it from here is what makes macOS
# call the app "Nothing Phone 3a" rather than "scrcpy".
if [ -x "$HERE/scrcpy" ] && [ -f "$RES/scrcpy-server" ]; then
  export SCRCPY_SERVER_PATH="$RES/scrcpy-server"
  exec "$HERE/scrcpy" "${args[@]}"
fi
exec scrcpy "${args[@]}"
