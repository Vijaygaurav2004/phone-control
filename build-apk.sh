#!/bin/bash
# Builds Touch Remote.apk straight from the SDK tools — no Gradle needed.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SDK="$HOME/Library/Android/sdk"
BT="$SDK/build-tools/36.1.0"
JAR="$SDK/platforms/android-36/android.jar"
JAVA="/opt/homebrew/opt/openjdk/bin"
# d8, apksigner and zipalign are wrappers that shell out to `java`.
export JAVA_HOME="/opt/homebrew/opt/openjdk"
export PATH="$JAVA:$PATH"
SRC="$HERE/android"
OUT="$HERE/android/build"

rm -rf "$OUT"; mkdir -p "$OUT/classes" "$OUT/dex"

# 1. Manifest into an APK skeleton (no resources to compile — the UI is drawn in code).
"$BT/aapt2" link -I "$JAR" \
  --manifest "$SRC/AndroidManifest.xml" \
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
