#!/bin/bash
# Builds Touch Remote.apk straight from the SDK tools — no Gradle needed.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# The SDK now lives in the Homebrew prefix. Pick whatever build-tools and
# platform are actually installed rather than pinning a version that may vanish.
SDK="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
[ -d "$SDK/build-tools" ] || SDK="$HOME/Library/Android/sdk"
BT="$(/bin/ls -d "$SDK"/build-tools/* 2>/dev/null | /usr/bin/sort -V | /usr/bin/tail -1)"
JAR="$(/bin/ls "$SDK"/platforms/*/android.jar 2>/dev/null | /usr/bin/sort -V | /usr/bin/tail -1)"
if [ -z "$BT" ] || [ -z "$JAR" ]; then
  echo "Android SDK incomplete under $SDK — need build-tools and a platform." >&2
  exit 1
fi
JAVA="/opt/homebrew/opt/openjdk/bin"
# d8, apksigner and zipalign are wrappers that shell out to `java`.
export JAVA_HOME="/opt/homebrew/opt/openjdk"
export PATH="$JAVA:$PATH"
SRC="$HERE/android"
OUT="$HERE/android/build"

rm -rf "$OUT"; mkdir -p "$OUT/classes" "$OUT/dex"

# 1. Compile resources, then link them with the manifest. The accessibility
#    service config is referenced from the manifest, so linking without
#    resources now fails outright.
"$BT/aapt2" compile --dir "$SRC/res" -o "$OUT/res.zip"
"$BT/aapt2" link -I "$JAR" \
  --manifest "$SRC/AndroidManifest.xml" \
  -R "$OUT/res.zip" --auto-add-overlay \
  --min-sdk-version 26 --target-sdk-version 34 \
  -o "$OUT/base.apk"

# 2. Compile. Target 11 bytecode: d8 won't read what javac 27 emits by default.
"$JAVA/javac" --release 11 -nowarn -classpath "$JAR" \
  -d "$OUT/classes" $(/usr/bin/find "$SRC/src" -name '*.java')

# 3. Dex it.
"$BT/d8" --lib "$JAR" --min-api 26 --output "$OUT/dex" \
  $(/usr/bin/find "$OUT/classes" -name '*.class')

# 4. Drop the dex into the APK.
(cd "$OUT/dex" && /usr/bin/zip -q "$OUT/base.apk" classes.dex)

# 5. Align, then sign with a local debug key.
KS="$HERE/android/debug.keystore"
if [ ! -f "$KS" ]; then
  "$JAVA/keytool" -genkeypair -keystore "$KS" -storepass android -keypass android \
    -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=Touch Remote Debug, O=Local, C=US" >/dev/null 2>&1
fi
"$BT/zipalign" -f 4 "$OUT/base.apk" "$OUT/aligned.apk"
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android \
  --out "$HERE/TouchRemote.apk" "$OUT/aligned.apk"

echo "Built: $HERE/TouchRemote.apk"
