#!/usr/bin/env python3
"""Turn an Android app into a real Mac app.

Builds ~/Applications/Phone Apps/<Label>.app — its own icon, its own Dock tile,
findable in Spotlight, switchable with Cmd+Tab. Launching it opens that Android
app on a fresh virtual display, so the phone itself stays locked and untouched.
"""
import os, re, subprocess, sys, tempfile, zipfile, plistlib, shutil

MIRROR = "/Applications/Nothing Phone 3a.app"
ADB = "/opt/homebrew/bin/adb"
OUT_DIR = os.path.expanduser("~/Applications/Phone Apps")


def adb(*args, timeout=120):
    return subprocess.run([ADB, *args], capture_output=True, text=True, timeout=timeout).stdout.strip()


def apk_path(pkg):
    for line in adb("shell", "pm", "path", pkg).splitlines():
        line = line.strip().replace("package:", "")
        if line.endswith("base.apk"):
            return line
    return None


def extract_icon(pkg, workdir):
    """Best-effort: pull the APK and take the largest launcher PNG inside it."""
    path = apk_path(pkg)
    if not path:
        return None
    local = os.path.join(workdir, "app.apk")
    subprocess.run([ADB, "pull", path, local], capture_output=True, timeout=300)
    if not os.path.exists(local):
        return None

    want = re.compile(r"res/(mipmap|drawable)[^/]*/.*(ic_launcher|launcher_icon|app_icon|ic_app)[^/]*\.png$", re.I)
    try:
        with zipfile.ZipFile(local) as z:
            names = [n for n in z.namelist() if want.search(n)]
            if not names:
                # Some apps name their icon something else entirely.
                names = [n for n in z.namelist()
                         if re.search(r"res/mipmap[^/]*/.*\.png$", n, re.I)]
            if not names:
                return None
            best = max(names, key=lambda n: z.getinfo(n).file_size)
            out = os.path.join(workdir, "icon.png")
            with z.open(best) as src, open(out, "wb") as dst:
                dst.write(src.read())
            return out
    except zipfile.BadZipFile:
        return None


def letter_icon(label, workdir):
    """Fallback when the APK yields nothing usable: a clean lettered tile."""
    from PIL import Image, ImageDraw, ImageFont
    S = 1024
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, S - 1, S - 1], radius=int(S * 0.225), fill=(32, 32, 35, 255))
    letter = (label.strip() or "?")[0].upper()
    size = int(S * 0.52)
    font = None
    for path in ("/System/Library/Fonts/Helvetica.ttc", "/System/Library/Fonts/SFNS.ttf"):
        try:
            font = ImageFont.truetype(path, size); break
        except Exception:
            pass
    if font is None:
        font = ImageFont.load_default()
    box = d.textbbox((0, 0), letter, font=font)
    d.text(((S - box[2] + box[0]) / 2 - box[0], (S - box[3] + box[1]) / 2 - box[1]),
           letter, font=font, fill=(245, 245, 247, 255))
    d.ellipse([S * 0.78, S * 0.10, S * 0.90, S * 0.22], fill=(214, 40, 40, 255))
    out = os.path.join(workdir, "icon.png")
    img.save(out)
    return out


def to_icns(png, dest, workdir):
    """Square it up, then build the .icns macOS wants."""
    from PIL import Image
    img = Image.open(png).convert("RGBA")
    side = max(img.size)
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.paste(img, ((side - img.width) // 2, (side - img.height) // 2), img)
    canvas = canvas.resize((1024, 1024), Image.LANCZOS)

    iconset = os.path.join(workdir, "icon.iconset")
    os.makedirs(iconset, exist_ok=True)
    for s in (16, 32, 128, 256, 512):
        canvas.resize((s, s), Image.LANCZOS).save(f"{iconset}/icon_{s}x{s}.png")
        canvas.resize((s * 2, s * 2), Image.LANCZOS).save(f"{iconset}/icon_{s}x{s}@2x.png")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", dest], check=True)


def build(pkg, label, w=1200, h=2000, dpi=280):
    os.makedirs(OUT_DIR, exist_ok=True)
    app = os.path.join(OUT_DIR, f"{label}.app")
    shutil.rmtree(app, ignore_errors=True)
    macos = os.path.join(app, "Contents/MacOS")
    res = os.path.join(app, "Contents/Resources")
    os.makedirs(macos); os.makedirs(res)

    with tempfile.TemporaryDirectory() as tmp:
        png = extract_icon(pkg, tmp) or letter_icon(label, tmp)
        try:
            to_icns(png, os.path.join(res, "icon.icns"), tmp)
        except Exception:
            to_icns(letter_icon(label, tmp), os.path.join(res, "icon.icns"), tmp)

    launcher = f"""#!/bin/bash
# Opens {label} on its own virtual display. The phone stays locked and free.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export ADB="{ADB}"
export SCRCPY_SERVER_PATH="{MIRROR}/Contents/Resources/scrcpy-server"

TARGET="$(adb devices | awk '$2=="device"{{print $1; exit}}')"
if [ -z "$TARGET" ]; then
  CFG="$HOME/.config/phone-control/config"
  [ -f "$CFG" ] && . "$CFG"
  [ -n "$PHONE_ADDR" ] && adb connect "$PHONE_ADDR" >/dev/null 2>&1 && sleep 2
  TARGET="$(adb devices | awk '$2=="device"{{print $1; exit}}')"
fi
if [ -z "$TARGET" ]; then
  osascript -e 'display dialog "Your phone isn'"'"'t reachable.\\n\\nRejoin the Wi-Fi, or plug in the USB cable once." with title "{label}" buttons {{"OK"}} default button "OK" with icon caution' >/dev/null 2>&1
  exit 1
fi

# Apps that refuse secondary displays otherwise get bounced straight back off.
adb -s "$TARGET" shell settings put global force_resizable_activities 1 >/dev/null 2>&1

exec "{MIRROR}/Contents/MacOS/scrcpy" -s "$TARGET" \\
  --new-display={w}x{h}/{dpi} --start-app={pkg} --window-title "{label}" \\
  --video-codec=h265 --max-fps 30 --video-bit-rate 6M \\
  --audio-buffer=180 --video-buffer=50 --keyboard=uhid
"""
    lp = os.path.join(macos, "launch")
    with open(lp, "w") as f:
        f.write(launcher)
    os.chmod(lp, 0o755)

    info = {
        "CFBundleName": label,
        "CFBundleDisplayName": label,
        "CFBundleExecutable": "launch",
        "CFBundleIconFile": "icon",
        "CFBundleIdentifier": "local.gaurav.phoneapp." + re.sub(r"[^A-Za-z0-9.]", "", pkg),
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1",
        "LSMinimumSystemVersion": "11.0",
        "NSHighResolutionCapable": True,
    }
    with open(os.path.join(app, "Contents/Info.plist"), "wb") as f:
        plistlib.dump(info, f)

    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", app],
                   capture_output=True)
    subprocess.run(["touch", app], capture_output=True)
    print(app)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit("usage: make-phone-app.py <package> <label> [w h dpi]")
    dims = [int(x) for x in sys.argv[3:6]] if len(sys.argv) >= 6 else [1200, 2000, 280]
    build(sys.argv[1], sys.argv[2], *dims)
