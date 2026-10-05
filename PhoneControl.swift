// Phone Control — menu bar companion for the Nothing Phone 3a.
//
// Lock/unlock, mirror, phone notifications on the Mac, battery, screenshots,
// screen recording, ring-to-find, and send-link-to-phone.

import Cocoa
import Carbon.HIToolbox
import Network
import UserNotifications

let configPath = NSHomeDirectory() + "/.config/phone-control/config"
let mirrorBundleID = "local.gaurav.nothingphone3a"
let mirrorApp = "/Applications/Nothing Phone 3a.app"

let adbPath: String = {
    for p in ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
    where FileManager.default.isExecutableFile(atPath: p) { return p }
    return "/opt/homebrew/bin/adb"
}()

// MARK: - Shell

@discardableResult
func sh(_ exe: String, _ args: [String], timeout: TimeInterval = 10,
        env extra: [String: String] = [:]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    if !extra.isEmpty {
        var e = ProcessInfo.processInfo.environment
        for (k, v) in extra { e[k] = v }
        p.environment = e
    }
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return "" }

    // Drain while waiting: a full pipe buffer would deadlock the child.
    var data = Data()
    let handle = out.fileHandleForReading
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline {
        data.append(handle.availableData)
    }
    if p.isRunning { p.terminate() }
    data.append(handle.readDataToEndOfFile())
    return String(data: data, encoding: .utf8) ?? ""
}

@discardableResult
func adb(_ args: [String], timeout: TimeInterval = 10) -> String {
    sh(adbPath, args, timeout: timeout)
}

func config(_ key: String) -> String? {
    guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else { return nil }
    for line in text.split(separator: "\n") where line.hasPrefix("\(key)=") {
        return line.dropFirst(key.count + 1).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
    return nil
}

/// A connected device: USB first, then the saved wireless address.
func target() -> String? {
    // Wireless debugging can add a second endpoint on its own TLS port, so
    // collect them all and prefer the address we actually configured.
    var wireless: [String] = []
    for line in adb(["devices"], timeout: 5).split(separator: "\n") {
        let parts = line.split(separator: "\t")
        guard parts.count == 2, parts[1].trimmingCharacters(in: .whitespaces) == "device" else { continue }
        let serial = String(parts[0])
        if serial.contains(":") { wireless.append(serial) } else { return serial }
    }
    if let saved = config("PHONE_ADDR"), wireless.contains(saved) { return saved }
    if let w = wireless.first { return w }

    // Nothing attached — try the address we learned last time. This is what
    // picks the phone back up when you return to the Wi-Fi.
    if let saved = config("PHONE_ADDR"), !saved.isEmpty {
        // A stale "offline" entry sticks around forever; clear it before redialling.
        if adb(["devices"], timeout: 5).contains("\(saved)\toffline") {
            adb(["disconnect", saved], timeout: 5)
        }
        adb(["connect", saved], timeout: 5)
        for line in adb(["devices"], timeout: 5).split(separator: "\n")
        where line.hasPrefix(saved) && line.hasSuffix("device") { return saved }
    }

    // Saved address missed — the router may have handed the phone a new IP.
    // mDNS finds it again, if Wireless debugging happens to be on.
    for line in adb(["mdns", "services"], timeout: 6).split(separator: "\n")
    where line.contains("_adb-tls-connect") {
        guard let addr = line.split(separator: "\t").last.map(String.init),
              addr.contains(":") else { continue }
        adb(["connect", addr], timeout: 5)
        for d in adb(["devices"], timeout: 5).split(separator: "\n")
        where d.hasPrefix(addr) && d.hasSuffix("device") {
            saveAddress(addr)
            return addr
        }
    }
    return nil
}

/// Persist a new address without disturbing the other keys the launcher writes.
func saveAddress(_ addr: String) {
    var w = config("SCREEN_W") ?? ""
    var h = config("SCREEN_H") ?? ""
    if w.isEmpty { w = "1080" }
    if h.isEmpty { h = "2392" }
    let text = "PHONE_ADDR=\"\(addr)\"\nSCREEN_W=\"\(w)\"\nSCREEN_H=\"\(h)\"\n"
    try? text.write(toFile: configPath, atomically: true, encoding: .utf8)
}

func isLocked(_ t: String) -> Bool {
    adb(["-s", t, "shell", "dumpsys window | grep -m1 mDreamingLockscreen"], timeout: 6)
        .contains("mDreamingLockscreen=true")
}

/// The touchscreen's raw input device — the one reporting multitouch positions.
func touchDevice(_ t: String) -> String {
    let out = adb(["-s", t, "shell", "getevent -pl"], timeout: 20)
    var current = ""
    for raw in out.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("add device"), let r = line.range(of: "/dev/input/") {
            current = String(line[r.lowerBound...]).trimmingCharacters(in: .whitespaces)
        } else if line.contains("ABS_MT_POSITION_X"), !current.isEmpty {
            return current
        }
    }
    return "/dev/input/event4"
}

func screenSize() -> (Int, Int) {
    (Int(config("SCREEN_W") ?? "") ?? 1080, Int(config("SCREEN_H") ?? "") ?? 2392)
}

// MARK: - Mac notifications

var useNativeNotifications = false

func setupNotifications(delegate: UNUserNotificationCenterDelegate) {
    guard Bundle.main.bundleIdentifier != nil else { return }
    let center = UNUserNotificationCenter.current()
    center.delegate = delegate
    // Android gives adb no way to send a notification reply, so the next best
    // thing is landing you in the app itself — in its own window, phone locked.
    let open = UNNotificationAction(identifier: "OPEN_APP", title: "Open in Window",
                                    options: [.foreground])
    center.setNotificationCategories([
        UNNotificationCategory(identifier: "PHONE_MSG", actions: [open],
                               intentIdentifiers: [], options: [])
    ])
    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
        useNativeNotifications = granted
    }
}

func notifyMac(title: String, body: String, sound: Bool = false, package: String? = nil) {
    if useNativeNotifications {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        if sound { c.sound = .default }
        // A package means we can offer to open that app in its own window.
        if let pkg = package {
            c.categoryIdentifier = "PHONE_MSG"
            c.userInfo = ["package": pkg]
        }
        let r = UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)
        UNUserNotificationCenter.current().add(r)
    } else {
        // Fallback for when notification permission was declined.
        let esc = { (s: String) in s.replacingOccurrences(of: "\"", with: "\\\"") }
        sh("/usr/bin/osascript",
           ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""],
           timeout: 5)
    }
}

/// launchd gives us a minimal PATH, so point scrcpy straight at adb and its
/// server rather than relying on lookup.
let scrcpyEnv: [String: String] = [
    "ADB": adbPath,
    "SCRCPY_SERVER_PATH": mirrorApp + "/Contents/Resources/scrcpy-server",
    "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
]

// MARK: - App windows
//
// scrcpy can spin up a *new virtual display* on the phone and launch an app
// onto it. The window is independent of the phone's own screen — the phone can
// sit locked in your pocket — because Android marks these displays
// FLAG_ALWAYS_UNLOCKED. Each app gets its own Mac window at a size you choose.

struct WindowPreset {
    let name: String, w: Int, h: Int, dpi: Int
}

let windowPresets = [
    WindowPreset(name: "Phone",  w: 1200, h: 2000, dpi: 280),
    WindowPreset(name: "Tall",   w: 1400, h: 2400, dpi: 300),
    WindowPreset(name: "Wide",   w: 1920, h: 1200, dpi: 260),
]

/// Each app remembers the size it was last opened at.
func presetFor(_ package: String) -> WindowPreset {
    let saved = UserDefaults.standard.string(forKey: "preset." + package)
        ?? UserDefaults.standard.string(forKey: "defaultPreset")
        ?? "Phone"
    return windowPresets.first { $0.name == saved } ?? windowPresets[0]
}

func rememberPreset(_ name: String, for package: String) {
    UserDefaults.standard.set(name, forKey: "preset." + package)
}

func launchAppWindow(package: String, label: String) {
    DispatchQueue.global().async {
        guard let t = target() else {
            DispatchQueue.main.async {
                alert("Phone not connected", info: "Plug in the cable or rejoin the Wi-Fi, then try again.")
            }
            return
        }
        // Apps that declare themselves non-resizable (WhatsApp among them) get
        // bounced straight back off a secondary display, leaving the window stuck
        // on a splash screen. This developer setting overrides that refusal.
        if adb(["-s", t, "shell", "settings get global force_resizable_activities"],
               timeout: 6).trimmingCharacters(in: .whitespacesAndNewlines) != "1" {
            adb(["-s", t, "shell", "settings put global force_resizable_activities 1"], timeout: 6)
        }

        let preset = presetFor(package)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: mirrorApp + "/Contents/MacOS/scrcpy")
        proc.arguments = [
            "-s", t,
            "--new-display=\(preset.w)x\(preset.h)/\(preset.dpi)",
            "--start-app=" + package,
            "--window-title", label,
            "--video-codec=h265", "--max-fps", "30", "--video-bit-rate", "6M",
            "--audio-buffer=180", "--video-buffer=50", "--keyboard=uhid",
        ]
        var env = ProcessInfo.processInfo.environment
        for (k, v) in scrcpyEnv { env[k] = v }
        proc.environment = env
        let errPipe = Pipe()
        proc.standardOutput = Pipe()
        proc.standardError = errPipe
        try? proc.run()   // detached: it lives until the window is closed

        // scrcpy announces "New display: 1200x2000/280 (id=20)" — grab that id so
        // keystrokes can be aimed at this window rather than the phone's screen.
        let pid = proc.processIdentifier
        DispatchQueue.global().async {
            var buf = ""
            let handle = errPipe.fileHandleForReading
            for _ in 0..<200 {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buf += String(data: chunk, encoding: .utf8) ?? ""
                if let marker = buf.range(of: "New display:"),
                   let idTag = buf.range(of: "(id=", range: marker.upperBound..<buf.endIndex) {
                    let digits = String(buf[idTag.upperBound...].prefix(while: { $0.isNumber }))
                    if let n = Int(digits) {
                        windowDisplaysLock.lock()
                        windowDisplays[pid] = n
                        windowDisplaysLock.unlock()
                        break
                    }
                }
            }
        }
    }
}

/// scrcpy pid -> the virtual display that window is showing. Input has to be
/// aimed at the right display, or it lands on the phone's own screen instead.
var windowDisplays: [pid_t: Int] = [:]
let windowDisplaysLock = NSLock()

/// The virtual display of the frontmost phone window, or nil for the mirror
/// (which shows display 0 and needs no targeting).
func frontmostDisplay() -> Int? {
    guard let front = NSWorkspace.shared.frontmostApplication,
          front.bundleIdentifier == mirrorBundleID else { return nil }
    windowDisplaysLock.lock()
    defer { windowDisplaysLock.unlock() }
    return windowDisplays[front.processIdentifier]
}

/// (label, package) for everything launchable, newest listing cached to disk
/// because asking the phone takes several seconds.
var cachedApps: [(String, String)] = []

func loadApps(force: Bool = false, done: @escaping () -> Void) {
    if !force, let saved = UserDefaults.standard.array(forKey: "appList") as? [[String]], !saved.isEmpty {
        cachedApps = saved.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
        done(); return
    }
    DispatchQueue.global().async {
        guard let t = target() else { done(); return }
        let out = sh(mirrorApp + "/Contents/MacOS/scrcpy", ["-s", t, "--list-apps"],
                     timeout: 90, env: scrcpyEnv)
        var apps: [(String, String)] = []
        for raw in out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- ") || line.hasPrefix("* ") else { continue }
            let rest = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            // "Name<spaces>com.package.name" — the package is the last field.
            guard let pkg = rest.split(separator: " ").last.map(String.init),
                  pkg.contains("."), !pkg.contains(" ") else { continue }
            let name = rest.dropLast(pkg.count).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { apps.append((name, pkg)) }
        }
        apps.sort { $0.0.lowercased() < $1.0.lowercased() }
        if !apps.isEmpty {
            cachedApps = apps
            UserDefaults.standard.set(apps.map { [$0.0, $0.1] }, forKey: "appList")
        }
        DispatchQueue.main.async { done() }
    }
}

// MARK: - Arrow keys → swipe gestures
//
// Reels and Shorts ignore D-pad events, which is all scrcpy can send for an
// arrow key, so we intercept Up/Down and fling a real swipe instead. Registered
// only while the mirror is frontmost, so arrows behave normally everywhere else.

var upHotKey: EventHotKeyRef?
var downHotKey: EventHotKeyRef?
var popHotKey: EventHotKeyRef?
var hotKeysActive = false
var arrowsEnabled = UserDefaults.standard.object(forKey: "arrowsEnabled") as? Bool ?? true

func reelSwipe(next: Bool, display: Int?) {
    DispatchQueue.global().async {
        guard let t = target() else { return }

        // A popped-out window has its own display and its own geometry; the
        // mirror shows the phone's real screen.
        var w = 0, h = 0
        if display != nil {
            let preset = windowPresets.first {
                $0.name == (UserDefaults.standard.string(forKey: "defaultPreset") ?? "Phone")
            } ?? windowPresets[0]
            (w, h) = (preset.w, preset.h)
        } else {
            (w, h) = screenSize()
        }

        let x = w / 2, near = h * 72 / 100, far = h * 28 / 100
        let (from, to) = next ? (near, far) : (far, near)
        // ~90ms reads as a fling rather than a drag, so the feed snaps one item.
        var args = ["-s", t, "shell", "input"]
        if let d = display { args += ["-d", "\(d)"] }
        args += ["swipe", "\(x)", "\(from)", "\(x)", "\(to)", "90"]
        adb(args, timeout: 5)
    }
}

// MARK: - Cmd+W: pop the app under the cursor into its own window

/// Where the mouse is, expressed in the phone's own pixel coordinates.
/// Returns nil if the mirror window can't be located.
func cursorOnPhone() -> (Int, Int)? {
    guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                kCGNullWindowID) as? [[String: Any]] else { return nil }
    // NSEvent gives bottom-left origin; CGWindow bounds are top-left.
    let mouse = NSEvent.mouseLocation
    guard let primary = NSScreen.screens.first else { return nil }
    let cg = CGPoint(x: mouse.x, y: primary.frame.height - mouse.y)

    // Match on owner name, not window title — titles need Screen Recording
    // permission, owner names don't. Picking the window under the cursor also
    // does the right thing when several phone windows are open at once.
    var frame: CGRect?
    for w in info {
        guard let owner = w[kCGWindowOwnerName as String] as? String,
              owner == "Nothing Phone 3a",
              let b = w[kCGWindowBounds as String] as? [String: Any],
              let d = CGRect(dictionaryRepresentation: b as CFDictionary),
              d.width > 1, d.height > 1, d.contains(cg) else { continue }
        frame = d
        break
    }
    guard let win = frame else { return nil }

    // Skip the title bar: the mirrored content starts below it.
    let titleBar: CGFloat = 28
    let content = CGRect(x: win.minX, y: win.minY + titleBar,
                         width: win.width, height: win.height - titleBar)
    guard content.contains(cg) else { return nil }

    let (pw, ph) = screenSize()
    let rx = (cg.x - content.minX) / content.width
    let ry = (cg.y - content.minY) / content.height
    return (Int(rx * CGFloat(pw)), Int(ry * CGFloat(ph)))
}

/// The app label drawn under the cursor on the phone's home screen, via the
/// accessibility tree. Icons carry their name in content-desc.
func appLabelAt(_ t: String, x: Int, y: Int) -> String? {
    var xml = ""
    for _ in 0..<2 {
        adb(["-s", t, "shell", "uiautomator dump /sdcard/ui.xml >/dev/null 2>&1"], timeout: 20)
        xml = adb(["-s", t, "shell", "cat /sdcard/ui.xml 2>/dev/null"], timeout: 20)
        if xml.contains("<node") { break }
    }
    guard xml.contains("<node") else { return nil }

    var best: (String, Int)?   // label, area — smallest wins
    for node in xml.components(separatedBy: "<node ") {
        guard let desc = attr(node, "content-desc"), !desc.isEmpty,
              let bounds = attr(node, "bounds") else { continue }
        let nums = bounds.split(whereSeparator: { !"0123456789".contains($0) }).compactMap { Int($0) }
        guard nums.count == 4 else { continue }
        let (x1, y1, x2, y2) = (nums[0], nums[1], nums[2], nums[3])
        guard x >= x1, x <= x2, y >= y1, y <= y2 else { continue }
        let area = (x2 - x1) * (y2 - y1)
        if best == nil || area < best!.1 { best = (desc, area) }
    }
    return best?.0
}

func attr(_ s: String, _ name: String) -> String? {
    guard let r = s.range(of: name + "=\"") else { return nil }
    let rest = s[r.upperBound...]
    guard let end = rest.firstIndex(of: "\"") else { return nil }
    return String(rest[..<end])
}

/// Cmd+W: pop out whatever you're pointing at, or whatever app is open.
func popOutApp() {
    DispatchQueue.global().async {
        guard let t = target() else { return }

        // Whatever app is open is the obvious thing to pop out. topResumedActivity
        // is the dependable signal here; mFocusedApp goes null whenever the
        // phone's own screen is off, which is most of the time for us.
        let focus = adb(["-s", t, "shell",
                         "dumpsys activity activities | grep -m1 topResumedActivity"], timeout: 8)
        var pkg: String?
        if let r = focus.range(of: "u0 ") {
            let rest = focus[r.upperBound...]
            let candidate = String(rest.prefix(while: { $0 != "/" }))
            if candidate.contains("."), !candidate.contains("launcher") { pkg = candidate }
        }

        // On the home screen, use the icon under the cursor instead.
        if pkg == nil, let (x, y) = DispatchQueue.main.sync(execute: { cursorOnPhone() }),
           let label = appLabelAt(t, x: x, y: y) {
            pkg = cachedApps.first { $0.0.caseInsensitiveCompare(label) == .orderedSame }?.1
        }

        guard let package = pkg else {
            DispatchQueue.main.async {
                notifyMac(title: "Nothing to pop out",
                          body: "You're on the home screen. Open the app in the mirror first, then press Cmd+W — or pick it from the menu bar.")
            }
            return
        }
        let label = cachedApps.first { $0.1 == package }?.0 ?? appNames[package] ?? package
        launchAppWindow(package: package, label: label)
    }
}

func registerArrowHotKeys() {
    guard arrowsEnabled, !hotKeysActive else { return }
    let sig = OSType(0x50484B59)  // 'PHKY'
    let up = EventHotKeyID(signature: sig, id: 1)
    let down = EventHotKeyID(signature: sig, id: 2)
    RegisterEventHotKey(UInt32(kVK_UpArrow), 0, up, GetApplicationEventTarget(), 0, &upHotKey)
    RegisterEventHotKey(UInt32(kVK_DownArrow), 0, down, GetApplicationEventTarget(), 0, &downHotKey)
    let pop = EventHotKeyID(signature: sig, id: 3)
    RegisterEventHotKey(UInt32(kVK_ANSI_W), UInt32(cmdKey), pop, GetApplicationEventTarget(), 0, &popHotKey)
    hotKeysActive = true
}

func unregisterArrowHotKeys() {
    if let r = upHotKey { UnregisterEventHotKey(r); upHotKey = nil }
    if let r = downHotKey { UnregisterEventHotKey(r); downHotKey = nil }
    if let r = popHotKey { UnregisterEventHotKey(r); popHotKey = nil }
    hotKeysActive = false
}

func installHotKeyHandler() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                             eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
        var id = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject),
                          EventParamType(typeEventHotKeyID), nil,
                          MemoryLayout<EventHotKeyID>.size, nil, &id)
        if id.id == 3 {
            popOutApp()
        } else {
            reelSwipe(next: id.id == 2, display: frontmostDisplay())
        }
        return noErr
    }, 1, &spec, nil, nil)
}

// MARK: - Phone notifications → Mac

var seenNotifications = Set<String>()
var notificationsSeeded = false
var notificationsEnabled = UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true

/// Friendly names for the apps worth surfacing; anything else shows its package.
let appNames: [String: String] = [
    "com.whatsapp": "WhatsApp",
    "com.instagram.android": "Instagram",
    "com.google.android.apps.messaging": "Messages",
    "com.google.android.gm": "Gmail",
    "com.facebook.katana": "Facebook",
    "com.facebook.orca": "Messenger",
    "org.telegram.messenger": "Telegram",
    "com.snapchat.android": "Snapchat",
    "com.linkedin.android": "LinkedIn",
    "com.twitter.android": "X",
    "com.microsoft.office.outlook": "Outlook",
    "com.slack": "Slack",
    "com.nothing.phone": "Phone",
]

/// Noisy system packages that would otherwise spam the Mac.
let ignoredPackages: Set<String> = [
    "android", "com.android.systemui", "com.google.android.gms",
    "com.google.android.apps.wellbeing", "com.android.providers.downloads",
    "com.nothing.systemui",
]

func pollPhoneNotifications() {
    guard notificationsEnabled, let t = target() else { return }

    let dump = adb(["-s", t, "shell",
                    "dumpsys notification --noredact | grep -E 'NotificationRecord\\(|android\\.title=String|android\\.text=String|android\\.bigText=String|android\\.conversationTitle=String|android\\.textLines=CharSequence|^ +\\[[0-9]+\\] '"],
                   timeout: 15)
    guard !dump.isEmpty else { return }

    var pkg = ""
    var title = ""
    var body = ""
    var bigText = ""      // full message when the app supplies an expanded view
    var lines = ""        // MessagingStyle / InboxStyle: several messages at once
    var convo = ""        // group chat name
    var collecting = false   // inside a textLines block
    var found: [(String, String, String)] = []

    func flush() {
        // Prefer the richest text the notification carries: the expanded body,
        // then stacked message lines, then the one-line summary.
        var full = !bigText.isEmpty ? bigText : (!lines.isEmpty ? lines : body)
        // Apps post a summary alongside the real thing ("8 new messages").
        // Skip it — the detailed notification carries the actual text.
        if lines.isEmpty, bigText.isEmpty,
           full.range(of: "^[0-9]+ new messages?$", options: .regularExpression) != nil {
            full = ""
        }
        let heading = convo.isEmpty ? title : "\(convo) · \(title)"
        if !pkg.isEmpty, !ignoredPackages.contains(pkg), !(heading.isEmpty && full.isEmpty) {
            found.append((pkg, heading, full))
        }
        title = ""; body = ""; bigText = ""; lines = ""; convo = ""
    }

    /// `android.title=String (Some text)` → `Some text`
    func value(_ line: Substring) -> String {
        guard let open = line.firstIndex(of: "("), let close = line.lastIndex(of: ")"), open < close
        else { return "" }
        return String(line[line.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
    }

    for raw in dump.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        // "[0] Alice: hey" rows directly under a textLines header are the real
        // messages; everything else ends the block.
        if collecting {
            if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                let msg = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
                if !msg.isEmpty { lines += (lines.isEmpty ? "" : "\n") + msg }
                continue
            }
            collecting = false
        }

        if line.contains("NotificationRecord(") {
            flush()
            collecting = false
            pkg = ""
            if let r = line.range(of: "pkg=") {
                pkg = String(line[r.upperBound...].prefix(while: { !$0.isWhitespace }))
            }
        } else if line.hasPrefix("android.title=String") {
            title = value(Substring(line))
        } else if line.hasPrefix("android.text=String") {
            body = value(Substring(line))
        } else if line.hasPrefix("android.bigText=String") {
            bigText = value(Substring(line))
        } else if line.hasPrefix("android.textLines=CharSequence") {
            lines = ""
            collecting = true
        } else if line.hasPrefix("android.conversationTitle=String") {
            convo = value(Substring(line))
        }
    }
    flush()

    // First pass just records what's already on the phone — otherwise every
    // old notification would fire the moment this app starts.
    if !notificationsSeeded {
        for n in found { seenNotifications.insert("\(n.0)|\(n.1)|\(n.2)") }
        notificationsSeeded = true
        return
    }

    for (p, ttl, txt) in found {
        let key = "\(p)|\(ttl)|\(txt)"
        guard !seenNotifications.contains(key) else { continue }
        seenNotifications.insert(key)
        let app = appNames[p] ?? p
        let heading = ttl.isEmpty ? app : "\(app) · \(ttl)"
        notifyMac(title: heading, body: txt, sound: true, package: p)
    }

    if seenNotifications.count > 400 { seenNotifications.removeAll(); notificationsSeeded = false }
}

// MARK: - Controller

final class Controller: NSObject, NSMenuDelegate, UNUserNotificationCenterDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let statusLine = NSMenuItem(title: "Checking…", action: nil, keyEquivalent: "")
    let appsMenu = NSMenu()
    let macAppMenu = NSMenu()
    let sizeMenu = NSMenu()
    var arrowToggle = NSMenuItem()
    var trackpadToggle = NSMenuItem()
    var notifToggle = NSMenuItem()
    var loginToggle = NSMenuItem()
    var recordItem = NSMenuItem()
    var recording = false
    var lastBattery = -1
    var pathMonitor: NWPathMonitor?

    override init() {
        super.init()
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "iphone", accessibilityDescription: "Nothing Phone 3a")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
        }

        let menu = NSMenu()
        menu.delegate = self
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        menu.addItem(entry("Open Mirror", "m", #selector(mirror)))

        let appsItem = NSMenuItem(title: "Open App in its Own Window", action: nil, keyEquivalent: "")
        appsItem.submenu = appsMenu
        menu.addItem(appsItem)

        let macAppItem = NSMenuItem(title: "Turn an App into a Mac App", action: nil, keyEquivalent: "")
        macAppItem.submenu = macAppMenu
        menu.addItem(macAppItem)

        let sizeItem = NSMenuItem(title: "Window Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)
        menu.addItem(.separator())

        menu.addItem(entry("Lock Phone", "l", #selector(lock)))
        menu.addItem(entry("Unlock Phone", "u", #selector(unlock)))
        menu.addItem(entry("Wake Screen", "w", #selector(wake)))
        menu.addItem(.separator())

        menu.addItem(entry("Screenshot to Desktop", "s", #selector(screenshot)))
        recordItem = entry("Start Screen Recording", "r", #selector(toggleRecording))
        menu.addItem(recordItem)
        menu.addItem(.separator())

        menu.addItem(entry("Ring Phone", "", #selector(ring)))
        menu.addItem(entry("Stop Ringing", "", #selector(stopRinging)))
        menu.addItem(entry("Send Link to Phone", "", #selector(sendLink)))
        menu.addItem(.separator())

        trackpadToggle = entry("Use Phone as Trackpad", "", #selector(toggleTrackpad))
        menu.addItem(trackpadToggle)

        arrowToggle = entry("Arrow Keys Scroll Reels", "", #selector(toggleArrows))
        arrowToggle.state = arrowsEnabled ? .on : .off
        menu.addItem(arrowToggle)

        notifToggle = entry("Phone Notifications on Mac", "", #selector(toggleNotifications))
        notifToggle.state = notificationsEnabled ? .on : .off
        menu.addItem(notifToggle)

        loginToggle = entry("Open at Login", "", #selector(toggleLogin))
        loginToggle.state = loginEnabled() ? .on : .off
        menu.addItem(loginToggle)
        menu.addItem(.separator())

        menu.addItem(entry("Quit", "q", #selector(quit)))
        item.menu = menu

        rebuildSizeMenu()
        rebuildAppsMenu()
        loadApps { self.rebuildAppsMenu() }

        // Always listen for the Android app, so opening Touch Remote just works
        // without having to arm anything from the menu first.
        CommandServer.shared.start()
        Discovery.shared.start()

        installHotKeyHandler()
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                       object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.bundleIdentifier == mirrorBundleID { registerArrowHotKeys() }
            else { unregisterArrowHotKeys() }
        }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == mirrorBundleID {
            registerArrowHotKeys()
        }

        // When nothing is attached, hunt for the phone every 10s rather than
        // waiting for the 30s battery tick — that gap is why changing Wi-Fi
        // felt like it needed a USB round-trip.
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            DispatchQueue.global().async {
                guard adb(["devices"], timeout: 4)
                        .split(separator: "\n")
                        .filter({ $0.hasSuffix("device") }).isEmpty else { return }
                if target() != nil { DispatchQueue.main.async { self.refreshBattery() } }
            }
        }

        // The moment this Mac's own network changes, go looking immediately
        // instead of waiting for the next tick.
        let monitor = NWPathMonitor()
        var lastPath: String = ""
        monitor.pathUpdateHandler = { path in
            let key = path.availableInterfaces.map(\.name).joined() + "\(path.status)"
            guard key != lastPath else { return }
            lastPath = key
            guard path.status == .satisfied else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                _ = target()
                DispatchQueue.main.async { self.refreshBattery() }
            }
        }
        monitor.start(queue: .global(qos: .utility))
        self.pathMonitor = monitor

        // Battery every 30s. target() reconnects on its own when nothing is
        // attached, so this doubles as the thing that picks the phone back up
        // when you walk back onto the Wi-Fi.
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            DispatchQueue.global().async { self.refreshBattery() }
        }
        DispatchQueue.global().async { self.refreshBattery() }

        // Phone notifications, polled often enough to feel live — but backed off
        // hard while the mirror is open. dumpsys is expensive on the phone and
        // shares the adb channel with the video stream; polling it every 6s was
        // enough to make Reels audio break up.
        var tick = 0
        Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { _ in
            tick += 1
            let mirroring = NSWorkspace.shared.runningApplications
                .contains { $0.bundleIdentifier == mirrorBundleID }
            guard !mirroring || tick % 10 == 0 else { return }   // 6s idle, 60s while mirroring
            DispatchQueue.global().async { pollPhoneNotifications() }
        }
    }

    func rebuildAppsMenu() {
        appsMenu.removeAllItems()
        if cachedApps.isEmpty {
            let loading = NSMenuItem(title: "Loading apps…", action: nil, keyEquivalent: "")
            loading.isEnabled = false
            appsMenu.addItem(loading)
        } else {
            for (name, pkg) in cachedApps {
                let i = NSMenuItem(title: name, action: #selector(openApp(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = [name, pkg]
                appsMenu.addItem(i)
            }
        }
        appsMenu.addItem(.separator())
        let r = NSMenuItem(title: "Refresh App List", action: #selector(refreshApps), keyEquivalent: "")
        r.target = self
        appsMenu.addItem(r)

        // Same list again, but building a standalone .app instead of a window.
        macAppMenu.removeAllItems()
        if cachedApps.isEmpty {
            let loading = NSMenuItem(title: "Loading apps…", action: nil, keyEquivalent: "")
            loading.isEnabled = false
            macAppMenu.addItem(loading)
        } else {
            for (name, pkg) in cachedApps {
                let i = NSMenuItem(title: name, action: #selector(makeMacApp(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = [name, pkg]
                macAppMenu.addItem(i)
            }
        }
        macAppMenu.addItem(.separator())
        let reveal = NSMenuItem(title: "Show Phone Apps Folder", action: #selector(revealMacApps), keyEquivalent: "")
        reveal.target = self
        macAppMenu.addItem(reveal)
    }

    /// Builds ~/Applications/Phone Apps/<Name>.app — real icon, Dock tile,
    /// Spotlight entry, Cmd+Tab. Pulling the APK for its icon takes a moment.
    @objc func makeMacApp(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        let (label, pkg) = (pair[0], pair[1])
        let preset = presetFor(pkg)
        notifyMac(title: "Building \(label)…", body: "Fetching its icon from the phone.")

        DispatchQueue.global().async {
            let script = NSHomeDirectory() + "/phone-control/make-phone-app.py"
            let out = sh("/usr/bin/python3",
                         [script, pkg, label, "\(preset.w)", "\(preset.h)", "\(preset.dpi)"],
                         timeout: 400, env: scrcpyEnv)
            let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                if FileManager.default.fileExists(atPath: path) {
                    notifyMac(title: "\(label) is now a Mac app",
                              body: "In Spotlight, Launchpad and Cmd+Tab. Drag it to the Dock to keep it.")
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                } else {
                    alert("Couldn't build \(label)",
                          info: "The phone needs to be connected — its icon is pulled from the installed app.")
                }
            }
        }
    }

    @objc func revealMacApps() {
        let dir = NSHomeDirectory() + "/Applications/Phone Apps"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir)
    }

    func rebuildSizeMenu() {
        sizeMenu.removeAllItems()
        let current = UserDefaults.standard.string(forKey: "defaultPreset") ?? "Phone"
        for preset in windowPresets {
            let i = NSMenuItem(title: "\(preset.name)   \(preset.w)×\(preset.h)",
                               action: #selector(setPreset(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = preset.name
            i.state = preset.name == current ? .on : .off
            sizeMenu.addItem(i)
        }
    }

    @objc func openApp(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        // Opening an app pins it to whatever size is selected now.
        rememberPreset(UserDefaults.standard.string(forKey: "defaultPreset") ?? "Phone", for: pair[1])
        launchAppWindow(package: pair[1], label: pair[0])
    }

    @objc func refreshApps() {
        cachedApps = []
        rebuildAppsMenu()
        loadApps(force: true) { self.rebuildAppsMenu() }
    }

    @objc func setPreset(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        UserDefaults.standard.set(name, forKey: "defaultPreset")
        rebuildSizeMenu()
    }

    // Tapping "Open in Window" on a phone notification.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                               didReceive response: UNNotificationResponse,
                               withCompletionHandler completionHandler: @escaping () -> Void) {
        if let pkg = response.notification.request.content.userInfo["package"] as? String {
            let label = appNames[pkg] ?? pkg
            launchAppWindow(package: pkg, label: label)
        }
        completionHandler()
    }

    // Show phone notifications even while this app is active.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                               willPresent notification: UNNotification,
                               withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    private func entry(_ title: String, _ key: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    /// Items that only work over adb. With developer options off they can't
    /// do anything, so they shouldn't look available.
    private let adbOnlyTitles: Set<String> = [
        "Open Mirror", "Lock Phone", "Unlock Phone", "Wake Screen",
        "Screenshot to Desktop", "Start Screen Recording", "Stop Screen Recording",
        "Ring Phone", "Stop Ringing", "Send Link to Phone",
        "Open App in its Own Window", "Turn an App into a Mac App", "Window Size",
    ]

    private func setAdbItems(enabled: Bool) {
        guard let menu = item.menu else { return }
        for i in menu.items where adbOnlyTitles.contains(i.title) {
            i.isEnabled = enabled
            i.action = enabled ? i.action : nil
            i.submenu?.items.forEach { $0.isEnabled = enabled }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        statusLine.title = "Checking…"
        DispatchQueue.global().async {
            let text: String
            if let t = target() {
                let how = t.contains(":") ? "Wi-Fi" : "USB"
                text = "Connected over \(how) · " + (isLocked(t) ? "locked" : "unlocked")
            } else {
                text = "Phone not connected · needs USB debugging"
            }
            let haveAdb = target() != nil
            DispatchQueue.main.async {
                self.statusLine.title = text
                self.setAdbItems(enabled: haveAdb)
            }
            self.refreshBattery()   // opening the menu should never show a stale number
        }
    }

    // MARK: Battery

    func refreshBattery() {
        guard let t = target() else {
            // A dash rather than a blank, so "out of range" never reads as a
            // stale percentage you might trust.
            DispatchQueue.main.async { self.item.button?.title = " —"; self.lastBattery = -1 }
            return
        }
        let dump = adb(["-s", t, "shell", "dumpsys battery | grep -E '^  level|^  status'"], timeout: 8)
        var level = -1
        var charging = false
        for line in dump.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("level:") { level = Int(l.dropFirst(6).trimmingCharacters(in: .whitespaces)) ?? -1 }
            if l.hasPrefix("status:") { charging = l.contains("2") }
        }
        guard level >= 0 else { return }

        if cachedApps.isEmpty {
            loadApps(force: true) { DispatchQueue.main.async { self.rebuildAppsMenu() } }
        }

        DispatchQueue.main.async {
            self.item.button?.title = " \(level)%"
            // Warn once per crossing, not on every poll.
            if level <= 15 && !charging && (self.lastBattery > 15 || self.lastBattery < 0) {
                notifyMac(title: "Phone battery low", body: "\(level)% left on your Nothing Phone 3a.", sound: true)
            }
            self.lastBattery = level
        }
    }

    // MARK: Actions

    private func withPhone(_ body: @escaping (String) -> Void) {
        DispatchQueue.global().async {
            guard let t = target() else {
                DispatchQueue.main.async {
                    alert("Phone not connected",
                          info: "Plug in the USB cable and open Nothing Phone 3a once — that re-arms the wireless connection.")
                }
                return
            }
            body(t)
        }
    }

    @objc func lock() { withPhone { adb(["-s", $0, "shell", "input", "keyevent", "KEYCODE_SLEEP"]) } }
    @objc func wake() { withPhone { adb(["-s", $0, "shell", "input", "keyevent", "KEYCODE_WAKEUP"]) } }

    @objc func unlock() {
        withPhone { t in
            adb(["-s", t, "shell", "input", "keyevent", "KEYCODE_WAKEUP"])
            Thread.sleep(forTimeInterval: 0.8)
            if isLocked(t) {
                let (w, h) = screenSize()
                adb(["-s", t, "shell", "input", "swipe",
                     "\(w / 2)", "\(h * 85 / 100)", "\(w / 2)", "\(h * 25 / 100)"])
                Thread.sleep(forTimeInterval: 0.8)
            }
            if isLocked(t) {
                DispatchQueue.main.async {
                    alert("Still locked",
                          info: "Your PIN is needed, and Android won't accept one from the Mac — that's deliberate on its part.\n\nType it on the phone, or set up Extend Unlock so this works from here.")
                }
            }
        }
    }

    @objc func mirror() { sh("/usr/bin/open", [mirrorApp], timeout: 5) }

    // MARK: Capture

    private func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f.string(from: Date())
    }

    @objc func screenshot() {
        withPhone { t in
            let path = NSHomeDirectory() + "/Desktop/Phone \(self.stamp()).png"
            // Shell redirection keeps the PNG bytes intact.
            sh("/bin/sh", ["-c", "\(adbPath) -s \(t) exec-out screencap -p > '\(path)'"], timeout: 25)
            let ok = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            DispatchQueue.main.async {
                if (ok ?? 0) > 1000 {
                    notifyMac(title: "Screenshot saved", body: "On your Desktop.")
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                } else {
                    alert("Screenshot failed", info: "The phone returned no image.")
                }
            }
        }
    }

    @objc func toggleRecording() {
        if recording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        withPhone { t in
            adb(["-s", t, "shell", "rm", "-f", "/sdcard/phone-rec.mp4"], timeout: 8)
            // Detached: screenrecord runs until we interrupt it (3 min ceiling).
            let p = Process()
            p.executableURL = URL(fileURLWithPath: adbPath)
            p.arguments = ["-s", t, "shell", "screenrecord", "--time-limit", "180", "/sdcard/phone-rec.mp4"]
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try? p.run()
            DispatchQueue.main.async {
                self.recording = true
                self.recordItem.title = "Stop Screen Recording"
                notifyMac(title: "Recording your phone", body: "Stops automatically after 3 minutes.")
            }
        }
    }

    private func stopRecording() {
        recording = false
        recordItem.title = "Start Screen Recording"
        withPhone { t in
            adb(["-s", t, "shell", "pkill", "-SIGINT", "screenrecord"], timeout: 8)
            Thread.sleep(forTimeInterval: 2.5)   // let the file finalise
            let path = NSHomeDirectory() + "/Desktop/Phone \(self.stamp()).mp4"
            adb(["-s", t, "pull", "/sdcard/phone-rec.mp4", path], timeout: 90)
            adb(["-s", t, "shell", "rm", "-f", "/sdcard/phone-rec.mp4"], timeout: 8)
            DispatchQueue.main.async {
                if FileManager.default.fileExists(atPath: path) {
                    notifyMac(title: "Recording saved", body: "On your Desktop.")
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                } else {
                    alert("Recording failed", info: "Nothing came back from the phone.")
                }
            }
        }
    }

    // MARK: Ring & links

    @objc func ring() {
        withPhone { t in
            // A timer, not a notification: alarms play at full volume even on silent.
            adb(["-s", t, "shell",
                 "am start -a android.intent.action.SET_TIMER --ei android.intent.extra.alarm.LENGTH 1 --ez android.intent.extra.alarm.SKIP_UI true --es android.intent.extra.alarm.MESSAGE 'Find my phone'"],
                timeout: 10)
            DispatchQueue.main.async {
                notifyMac(title: "Ringing your phone", body: "Use Stop Ringing when you've found it.")
            }
        }
    }

    @objc func stopRinging() {
        withPhone { t in adb(["-s", t, "shell", "am", "force-stop", "com.google.android.deskclock"], timeout: 8) }
    }

    @objc func sendLink() {
        let clip = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard clip.hasPrefix("http://") || clip.hasPrefix("https://") else {
            alert("No link on the clipboard",
                  info: clip.isEmpty ? "Copy a URL first, then try again."
                                     : "That doesn't look like a URL:\n\n\(clip.prefix(90))")
            return
        }
        withPhone { t in
            adb(["-s", t, "shell", "am", "start", "-a", "android.intent.action.VIEW", "-d", clip], timeout: 10)
            DispatchQueue.main.async { notifyMac(title: "Sent to your phone", body: clip) }
        }
    }

    // MARK: Toggles

    /// Streams the phone's raw touch events and drives the Mac cursor with them.
    @objc func toggleTrackpad() {
        if Trackpad.shared.running {
            Trackpad.shared.stop()
            trackpadToggle.state = .off
            notifyMac(title: "Trackpad off", body: "Your phone is a phone again.")
            return
        }
        DispatchQueue.global().async {
            let t = target()
            DispatchQueue.main.async {
                // Touch Remote finds the Mac on its own, so this works with
                // developer options switched off — adb is only used to open the
                // app for you when it happens to be available.
                Trackpad.shared.startServers(target: t)
                self.trackpadToggle.state = Trackpad.shared.running ? .on : .off
                if t == nil {
                    notifyMac(title: "Ready for Touch Remote",
                              body: "Open Touch Remote on your phone — it will find this Mac by itself.")
                }
            }
        }
    }

    @objc func toggleArrows() {
        arrowsEnabled.toggle()
        UserDefaults.standard.set(arrowsEnabled, forKey: "arrowsEnabled")
        arrowToggle.state = arrowsEnabled ? .on : .off
        if arrowsEnabled {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == mirrorBundleID {
                registerArrowHotKeys()
            }
        } else { unregisterArrowHotKeys() }
    }

    @objc func toggleNotifications() {
        notificationsEnabled.toggle()
        UserDefaults.standard.set(notificationsEnabled, forKey: "notificationsEnabled")
        notifToggle.state = notificationsEnabled ? .on : .off
        if notificationsEnabled { notificationsSeeded = false }
    }

    // Login item via a LaunchAgent — works for a locally built, ad-hoc signed app.
    private var agentPath: String { NSHomeDirectory() + "/Library/LaunchAgents/local.gaurav.phonecontrol.plist" }

    func loginEnabled() -> Bool { FileManager.default.fileExists(atPath: agentPath) }

    @objc func toggleLogin() {
        let fm = FileManager.default
        if loginEnabled() {
            sh("/bin/launchctl", ["unload", agentPath], timeout: 5)
            try? fm.removeItem(atPath: agentPath)
            loginToggle.state = .off
        } else {
            let exe = "/Applications/Phone Control.app/Contents/MacOS/PhoneControl"
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
              <key>Label</key><string>local.gaurav.phonecontrol</string>
              <key>ProgramArguments</key><array><string>\(exe)</string></array>
              <key>RunAtLoad</key><true/>
              <key>KeepAlive</key><true/>
            </dict>
            </plist>
            """
            try? fm.createDirectory(atPath: NSHomeDirectory() + "/Library/LaunchAgents",
                                    withIntermediateDirectories: true)
            try? plist.write(toFile: agentPath, atomically: true, encoding: .utf8)
            sh("/bin/launchctl", ["load", agentPath], timeout: 5)
            loginToggle.state = .on
        }
    }

    @objc func quit() { NSApp.terminate(nil) }
}

func alert(_ message: String, info: String = "") {
    let a = NSAlert()
    a.messageText = message
    a.informativeText = info
    a.alertStyle = .informational
    NSApp.activate(ignoringOtherApps: true)
    a.runModal()
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()
setupNotifications(delegate: controller)
app.run()
