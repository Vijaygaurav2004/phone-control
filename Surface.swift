// The phone-side surface, and the little server behind it.
//
// The phone shows a black page served from here. It sends touches' worth of
// nothing (the Mac reads raw touch events separately) but it *does* carry the
// keyboard: when the Mac's focus lands in a text field, the page focuses a
// hidden input, Android pops its keyboard, and what you type is posted back
// here and injected into the Mac.

import Cocoa
import Network
import ApplicationServices

let surfacePort: UInt16 = 8787

// MARK: - Injecting into the Mac

func typeOnMac(_ text: String) {
    let chars = Array(text.utf16)
    guard !chars.isEmpty else { return }
    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
        e.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
        e.post(tap: .cghidEventTap)
    }
}

func pressKey(_ code: CGKeyCode, flags: CGEventFlags = []) {
    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { continue }
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }
}

/// Is the Mac's keyboard focus sitting in something you can type into?
func macFocusIsTextInput() -> Bool {
    let system = AXUIElementCreateSystemWide()
    var focused: AnyObject?
    guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
          let element = focused else { return false }

    var role: AnyObject?
    AXUIElementCopyAttributeValue(element as! AXUIElement, kAXRoleAttribute as CFString, &role)
    if let r = role as? String,
       [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"].contains(r) {
        return true
    }

    // Browsers and Electron apps report generic roles. Require BOTH a text
    // cursor and a settable value — checking only one was matching far too much,
    // which turned the lower half of the phone into a dead zone.
    var range: AnyObject?
    let hasCursor = AXUIElementCopyAttributeValue(element as! AXUIElement,
                                                  kAXSelectedTextRangeAttribute as CFString,
                                                  &range) == .success && range != nil
    var settable = DarwinBoolean(false)
    AXUIElementIsAttributeSettable(element as! AXUIElement,
                                   kAXValueAttribute as CFString, &settable)
    return hasCursor && settable.boolValue
}

// MARK: - Driving the cursor

private var dragging = false

func cursorPoint() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

func moveCursor(dx: CGFloat, dy: CGFloat) {
    var p = cursorPoint()
    p.x += dx; p.y += dy
    let union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
    if let primary = NSScreen.screens.first {
        let flipped = CGRect(x: union.minX, y: primary.frame.height - union.maxY,
                             width: union.width, height: union.height)
        p.x = min(max(p.x, flipped.minX), flipped.maxX - 1)
        p.y = min(max(p.y, flipped.minY), flipped.maxY - 1)
    }
    CGEvent(mouseEventSource: nil,
            mouseType: dragging ? .leftMouseDragged : .mouseMoved,
            mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
}

func clickMouse(right: Bool, clicks: Int) {
    let p = cursorPoint()
    let (down, up): (CGEventType, CGEventType) =
        right ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
    for type in [down, up] {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type,
                              mouseCursorPosition: p, mouseButton: right ? .right : .left)
        else { continue }
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        e.post(tap: .cghidEventTap)
    }
}

func setDragging(_ on: Bool) {
    dragging = on
    CGEvent(mouseEventSource: nil, mouseType: on ? .leftMouseDown : .leftMouseUp,
            mouseCursorPosition: cursorPoint(), mouseButton: .left)?.post(tap: .cghidEventTap)
}

func scrollBy(_ dy: CGFloat) {
    guard abs(dy) >= 1 else { return }
    CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
            wheel1: Int32(dy), wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
}

// MARK: - Server

final class SurfaceServer {
    static let shared = SurfaceServer()
    private var listener: NWListener?
    private(set) var running = false

    /// Set by the focus watcher; the page polls this to raise the keyboard.
    var wantsKeyboard = false

    func start() {
        guard !running else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: surfacePort),
              let l = try? NWListener(using: params, on: port) else { return }
        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .global(qos: .userInitiated))
            self?.read(conn)
        }
        l.start(queue: .global(qos: .userInitiated))
        listener = l
        running = true
    }

    func stop() {
        listener?.cancel()
        listener = nil
        running = false
        wantsKeyboard = false
    }

    private func read(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                conn.cancel(); return
            }
            let firstLine = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
            let path = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let response = self.respond(to: path)
            conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    private func http(_ body: String, type: String = "text/html; charset=utf-8") -> Data {
        let bytes = Array(body.utf8)
        let head = """
        HTTP/1.1 200 OK\r
        Content-Type: \(type)\r
        Content-Length: \(bytes.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r\n
        """
        return Data(head.utf8) + Data(bytes)
    }

    private func respond(to path: String) -> Data {
        let parts = path.split(separator: "?", maxSplits: 1)
        let route = String(parts.first ?? "/")
        let query = parts.count > 1 ? String(parts[1]) : ""

        switch route {
        case "/":
            return http(trackpadSurfaceHTML)

        case "/state":
            return http("{\"kb\":\(wantsKeyboard)}", type: "application/json")

        case "/m":
            if let x = Double(param("x", in: query) ?? ""),
               let y = Double(param("y", in: query) ?? "") {
                let k = 1.7   // cursor travel per unit of finger movement
                DispatchQueue.main.async { moveCursor(dx: CGFloat(x) * k, dy: CGFloat(y) * k) }
            }
            return http("", type: "text/plain")

        case "/c":
            let right = param("b", in: query) == "r"
            let clicks = Int(param("n", in: query) ?? "1") ?? 1
            DispatchQueue.main.async { clickMouse(right: right, clicks: clicks) }
            return http("", type: "text/plain")

        case "/d":
            let on = param("s", in: query) == "1"
            DispatchQueue.main.async { setDragging(on) }
            return http("", type: "text/plain")

        case "/s":
            if let y = Double(param("y", in: query) ?? "") {
                DispatchQueue.main.async { scrollBy(CGFloat(y) * 0.7) }
            }
            return http("", type: "text/plain")

        case "/g":
            if let g = param("n", in: query) {
                DispatchQueue.main.async {
                    switch g {
                    case "sl": pressKey(0x7B, flags: .maskControl)   // desktop left
                    case "sr": pressKey(0x7C, flags: .maskControl)   // desktop right
                    case "mc": pressKey(0x7E, flags: .maskControl)   // Mission Control
                    case "ae": pressKey(0x7D, flags: .maskControl)   // App Expose
                    default: break
                    }
                }
            }
            return http("", type: "text/plain")

        case "/k":
            if let text = param("c", in: query)?.removingPercentEncoding, !text.isEmpty {
                DispatchQueue.main.async { typeOnMac(text) }
            }
            return http("", type: "text/plain")

        case "/sp":
            if let key = param("k", in: query) {
                DispatchQueue.main.async {
                    switch key {
                    case "back":  pressKey(0x33)              // delete
                    case "enter": pressKey(0x24)              // return
                    case "tab":   pressKey(0x30)
                    case "esc":   pressKey(0x35)
                    default: break
                    }
                }
            }
            return http("", type: "text/plain")

        default:
            return http("", type: "text/plain")
        }
    }

    private func param(_ name: String, in query: String) -> String? {
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.first.map(String.init) == name {
                return kv.count > 1 ? String(kv[1]) : ""
            }
        }
        return nil
    }
}

// MARK: - Everything the phone can ask the Mac to do

/// Modifier keys latched on the phone, applied to the next click or keystroke.
var latchedFlags: CGEventFlags = []

/// Media and volume keys aren't ordinary keystrokes — they're system-defined
/// events, so they need NSEvent rather than CGEvent.
func systemKey(_ key: Int32) {
    for down in [true, false] {
        let flags: NSEvent.ModifierFlags = down ? .init(rawValue: 0xa00) : .init(rawValue: 0xb00)
        guard let e = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                         modifierFlags: flags, timestamp: 0,
                                         windowNumber: 0, context: nil, subtype: 8,
                                         data1: Int((key << 16) | ((down ? 0xa : 0xb) << 8)),
                                         data2: -1) else { continue }
        e.cgEvent?.post(tap: .cghidEventTap)
    }
}

let NX_PLAY: Int32 = 16, NX_NEXT: Int32 = 17, NX_PREV: Int32 = 18
let NX_SOUND_UP: Int32 = 0, NX_SOUND_DOWN: Int32 = 1, NX_MUTE: Int32 = 7
let NX_BRIGHT_UP: Int32 = 2, NX_BRIGHT_DOWN: Int32 = 3

/// Named shortcuts the phone's key pad can fire.
func runShortcut(_ name: String) {
    switch name {
    case "copy":       pressKey(0x08, flags: .maskCommand)
    case "paste":      pressKey(0x09, flags: .maskCommand)
    case "cut":        pressKey(0x07, flags: .maskCommand)
    case "undo":       pressKey(0x06, flags: .maskCommand)
    case "redo":       pressKey(0x06, flags: [.maskCommand, .maskShift])
    case "save":       pressKey(0x01, flags: .maskCommand)
    case "selectall":  pressKey(0x00, flags: .maskCommand)
    case "find":       pressKey(0x03, flags: .maskCommand)
    case "close":      pressKey(0x0D, flags: .maskCommand)
    case "quit":       pressKey(0x0C, flags: .maskCommand)
    case "spotlight":  pressKey(0x31, flags: .maskCommand)
    case "switcher":   pressKey(0x30, flags: .maskCommand)
    case "screenshot": pressKey(0x15, flags: [.maskCommand, .maskShift])     // Cmd+Shift+4
    case "fullscreen": pressKey(0x03, flags: [.maskCommand, .maskControl])
    case "mission":    pressKey(0x7E, flags: .maskControl)
    case "expose":     pressKey(0x7D, flags: .maskControl)
    case "launchpad":  pressKey(0x76)
    case "prevApp":    cycleApp(next: false)
    case "nextApp":    cycleApp(next: true)
    case "desktopL":   pressKey(0x7B, flags: .maskControl)
    case "desktopR":   pressKey(0x7C, flags: .maskControl)
    case "lock":       pressKey(0x0C, flags: [.maskCommand, .maskControl])   // Cmd+Ctrl+Q
    case "left":       pressKey(0x7B, flags: latchedFlags)
    case "right":      pressKey(0x7C, flags: latchedFlags)
    case "up":         pressKey(0x7E, flags: latchedFlags)
    case "down":       pressKey(0x7D, flags: latchedFlags)
    case "esc":        pressKey(0x35)
    case "tab":        pressKey(0x30, flags: latchedFlags)
    case "enter":      pressKey(0x24)
    case "back":       pressKey(0x33)
    case "space":      pressKey(0x31, flags: latchedFlags)
    default: break
    }
}

/// Apps the user could actually switch to — no background daemons.
func macApps() -> [String] {
    NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular }
        .compactMap { $0.localizedName }
        .sorted { $0.lowercased() < $1.lowercased() }
}

/// Bring the next/previous app to the front. Ctrl+Arrow only moves between
/// Spaces — useless if you keep everything on one desktop — whereas this always
/// does something visible.
func cycleApp(next: Bool) {
    let apps = NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular }
        .sorted { ($0.localizedName ?? "") .lowercased() < ($1.localizedName ?? "").lowercased() }
    guard apps.count > 1 else { return }
    let frontName = NSWorkspace.shared.frontmostApplication?.localizedName
    let current = apps.firstIndex { $0.localizedName == frontName } ?? 0
    let n = apps.count
    let target = next ? (current + 1) % n : (current - 1 + n) % n
    if let name = apps[target].localizedName { bringToFront(name) }
}

/// `open -a` rather than NSRunningApplication.activate: recent macOS ignores a
/// background app trying to pull another app forward, but honours this.
func bringToFront(_ name: String) {
    sh("/usr/bin/open", ["-a", name], timeout: 6)
}

func activateApp(named name: String) {
    bringToFront(name)
}

func macClipboard() -> String {
    NSPasteboard.general.string(forType: .string) ?? ""
}

func setMacClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

// MARK: - Command server for the Android app
//
// One long-lived TCP connection carrying newline-delimited commands. Far
// cheaper than an HTTP request per cursor movement, and the app reconnects
// by itself if the link drops.

final class CommandServer {
    static let shared = CommandServer()
    private var listener: NWListener?
    private var client: NWConnection?
    private(set) var running = false

    /// Push a line back to the phone (app lists, clipboard, status).
    func send(_ line: String) {
        client?.send(content: Data((line + "\n").utf8), completion: .idempotent)
    }

    func start(port: UInt16 = 8788) {
        guard !running else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if let opts = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            opts.noDelay = true
        }
        guard let p = NWEndpoint.Port(rawValue: port),
              let l = try? NWListener(using: params, on: p) else { return }
        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .global(qos: .userInteractive))
            self?.client?.cancel()      // drop the previous socket, replies follow the live one
            self?.client = conn
            self?.read(conn, buffer: [])
        }
        l.start(queue: .global(qos: .userInteractive))
        listener = l
        running = true
    }

    func stop() {
        listener?.cancel(); listener = nil
        running = false
    }

    private func read(_ conn: NWConnection, buffer: [UInt8]) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, _ in
            guard let self else { return }
            var buf = buffer
            if let data, !data.isEmpty { buf.append(contentsOf: data) }
            let leftover = self.consume(buf)
            if done { conn.cancel() } else { self.read(conn, buffer: leftover) }
        }
    }

    /// The stream carries two things at once: the original newline-delimited
    /// commands, and binary frames for video. 0xAB is a UTF-8 continuation
    /// byte, so it can never start a text line — one byte tells them apart.
    private func consume(_ input: [UInt8]) -> [UInt8] {
        var i = 0
        let n = input.count

        while i < n {
            if input[i] == 0xAB {
                guard n - i >= 8 else { break }
                let h = Array(input[i..<(i + 8)])
                let check = h[0] ^ h[1] ^ h[2] ^ h[4] ^ h[5] ^ h[6] ^ h[7]
                guard check == h[3] else { i += 1; continue }   // false magic — resync
                let len = (Int(h[4]) << 24) | (Int(h[5]) << 16) | (Int(h[6]) << 8) | Int(h[7])
                guard len >= 0, len <= 1_048_576 else { i += 1; continue }
                guard n - i - 8 >= len else { break }           // wait for the rest
                let payload = Array(input[(i + 8)..<(i + 8 + len)])
                handle(type: h[1], flags: h[2], payload: payload)
                i += 8 + len
            } else {
                guard let nl = input[i..<n].firstIndex(of: 0x0A) else { break }
                if nl > i, let line = String(bytes: input[i..<nl], encoding: .utf8) {
                    run(command: line)
                }
                i = nl + 1
            }
        }
        return i == 0 ? input : Array(input[i..<n])
    }

    private func handle(type: UInt8, flags: UInt8, payload: [UInt8]) {
        switch type {
        case 0x01:   // a command line, just framed
            if let line = String(bytes: payload, encoding: .utf8) { run(command: line) }

        case 0x03:   // codec config: width, height, then SPS/PPS
            guard payload.count > 8 else { return }
            let w = (Int(payload[0]) << 24) | (Int(payload[1]) << 16) | (Int(payload[2]) << 8) | Int(payload[3])
            let h = (Int(payload[4]) << 24) | (Int(payload[5]) << 16) | (Int(payload[6]) << 8) | Int(payload[7])
            Mirror.shared.configure(csd: Data(payload[8...]), width: w, height: h)

        case 0x02:   // one chunk of an access unit
            Mirror.shared.append(chunk: Data(payload),
                                 keyframe: flags & 0x01 != 0,
                                 continuation: flags & 0x02 != 0,
                                 last: flags & 0x04 != 0)

        default:
            break    // unknown types are skipped, not treated as desync
        }
    }

    private var warnedUntrusted = false

    private func run(command line: String) {
        let f = line.split(separator: " ", maxSplits: 3).map(String.init)
        guard let verb = f.first else { return }

        // Commands arrive fine over the socket, but posting cursor and key
        // events needs Accessibility. Say so rather than silently doing nothing.
        if !AXIsProcessTrusted() {
            guard !warnedUntrusted else { return }
            warnedUntrusted = true
            DispatchQueue.main.async {
                let a = NSAlert()
                a.messageText = "Accessibility permission needed"
                a.informativeText = "Your phone is connected, but macOS won't let Phone Control move the cursor until you allow it.\n\nSystem Settings \u{2192} Privacy & Security \u{2192} Accessibility \u{2192} turn on Phone Control."
                a.addButton(withTitle: "Open Settings")
                a.addButton(withTitle: "Later")
                NSApp.activate(ignoringOtherApps: true)
                if a.runModal() == .alertFirstButtonReturn,
                   let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 60) { self.warnedUntrusted = false }
            }
            return
        }

        DispatchQueue.main.async {
            switch verb {
            case "M":   // move: dx dy, in phone pixels
                guard f.count >= 3, let dx = Double(f[1]), let dy = Double(f[2]) else { return }
                let k = 1.7
                moveCursor(dx: CGFloat(dx) * k, dy: CGFloat(dy) * k)

            case "S":   // scroll
                guard f.count >= 2, let dy = Double(f[1]) else { return }
                scrollBy(CGFloat(dy) * 0.7)

            case "C":   // click: l|r clicks
                guard f.count >= 3, let n = Int(f[2]) else { return }
                clickMouse(right: f[1] == "r", clicks: n)
                latchedFlags = []   // a latch is one-shot

            case "D":   // drag on/off
                setDragging(f.count >= 2 && f[1] == "1")

            case "G":   // desktop gestures
                guard f.count >= 2 else { return }
                switch f[1] {
                case "sl": cycleApp(next: false)
                case "sr": cycleApp(next: true)
                case "mc": pressKey(0x7E, flags: .maskControl)
                case "ae": pressKey(0x7D, flags: .maskControl)
                default: break
                }

            case "X":   // named shortcut from the key pad
                if f.count >= 2 { runShortcut(f[1]) }

            case "MOD": // latch modifiers for the next click or key
                var flags: CGEventFlags = []
                if f.count >= 2 {
                    for part in f[1].split(separator: ",") {
                        switch part {
                        case "cmd":   flags.insert(.maskCommand)
                        case "opt":   flags.insert(.maskAlternate)
                        case "ctrl":  flags.insert(.maskControl)
                        case "shift": flags.insert(.maskShift)
                        default: break
                        }
                    }
                }
                latchedFlags = flags

            case "V":   // volume
                guard f.count >= 2 else { return }
                systemKey(f[1] == "up" ? NX_SOUND_UP : f[1] == "down" ? NX_SOUND_DOWN : NX_MUTE)

            case "B":   // display brightness
                guard f.count >= 2 else { return }
                systemKey(f[1] == "up" ? NX_BRIGHT_UP : NX_BRIGHT_DOWN)

            case "MED": // transport controls
                guard f.count >= 2 else { return }
                systemKey(f[1] == "next" ? NX_NEXT : f[1] == "prev" ? NX_PREV : NX_PLAY)

            case "APPS":
                CommandServer.shared.send("APPS " + macApps().joined(separator: "|"))

            case "ACT":
                if f.count >= 2 {
                    activateApp(named: String(line.dropFirst(4)))
                }

            case "CLIPGET":
                CommandServer.shared.send("CLIP " + macClipboard()
                    .replacingOccurrences(of: "\n", with: "\\n"))

            case "CLIPSET":
                if line.count > 8 {
                    setMacClipboard(String(line.dropFirst(8))
                        .replacingOccurrences(of: "\\n", with: "\n"))
                }

            case "K":   // typed text — everything after "K " verbatim, spaces included
                if line.count > 2 {
                    let text = String(line.dropFirst(2))
                        .replacingOccurrences(of: "\\n", with: "\n")
                    typeOnMac(text)
                }

            case "P":   // special keys
                guard f.count >= 2 else { return }
                switch f[1] {
                case "back":  pressKey(0x33)
                case "enter": pressKey(0x24)
                case "tab":   pressKey(0x30)
                case "esc":   pressKey(0x35)
                default: break
                }

            case "PING":
                break       // keeps the socket honest; nothing to do

            case "LOG":
                NSLog("[phone] %@", String(line.dropFirst(4)))

            default: break
            }
        }
    }
}

// MARK: - Discovery
//
// The phone shouts on the local network and this answers with the Mac's
// address, so the app finds its way home after any Wi-Fi change without
// anyone typing an IP.

final class Discovery {
    static let shared = Discovery()
    private var fd: Int32 = -1

    /// A plain IPv4 socket, not NWListener: Network framework bound this to
    /// IPv6 only, so the phone's broadcast to 255.255.255.255 never arrived.
    func start(port: UInt16 = 8789) {
        guard fd < 0 else { return }
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { return }
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { close(s); return }
        fd = s

        DispatchQueue.global(qos: .utility).async { [weak self] in
            var buf = [UInt8](repeating: 0, count: 256)
            while let self, self.fd >= 0 {
                var from = sockaddr_in()
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(self.fd, &buf, buf.count, 0, $0, &len)
                    }
                }
                guard n > 0 else { continue }
                guard String(bytes: buf[0..<n], encoding: .utf8)?.hasPrefix("WHO") == true
                else { continue }

                let sender = String(cString: inet_ntoa(from.sin_addr))
                let reply = "MAC " + (Discovery.bestAddress(facing: sender) ?? "")
                _ = reply.withCString { body in
                    withUnsafePointer(to: &from) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(self.fd, body, strlen(body), 0, $0, len)
                        }
                    }
                }
            }
        }
    }

    static func localAddresses() -> [String] {
        var found: [String] = []
        for line in sh("/sbin/ifconfig", [], timeout: 6).split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("inet "), !l.contains("127.0.0.1") else { continue }
            let addr = String(l.dropFirst(5).prefix(while: { $0 != " " }))
            if addr.hasPrefix("192.168.") || addr.hasPrefix("10.") || addr.hasPrefix("172.") {
                found.append(addr)
            }
        }
        return found
    }

    /// Prefer the address sharing a subnet with whoever is asking.
    static func bestAddress(facing sender: String?) -> String? {
        let mine = localAddresses()
        if let sender, let prefix = sender.split(separator: ".").prefix(3).joined(separator: ".") as String?,
           let match = mine.first(where: { $0.hasPrefix(prefix + ".") }) {
            return match
        }
        return mine.first
    }

    static func localAddress() -> String? { bestAddress(facing: nil) }
}
