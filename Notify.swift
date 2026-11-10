import Cocoa
import UserNotifications

/// Phone notifications sent by the Touch Remote app — no adb, no developer
/// options. Each one becomes a Mac banner; chat messages get a Reply box whose
/// text goes back to the phone and is sent through the app's own reply action,
/// exactly as if you'd replied from the phone's notification shade.
final class PhoneNotifs {
    static let shared = PhoneNotifs()

    static let replyCategory = "PHONE_REPLY"
    static let plainCategory = "PHONE_NOTE"

    /// True while Touch Remote is forwarding notifications, so the old adb
    /// poller stands down instead of showing everything twice.
    var appActive = false {
        didSet { if appActive { everActive = true } }
    }
    /// Once the app has forwarded notifications, the adb poller stays off for
    /// good: if it took over on a brief disconnect it would re-show everything.
    private(set) var everActive = false

    /// Latest battery the phone reported, for the menu bar when adb is off.
    private(set) var battery: (level: Int, charging: Bool, at: Date)?
    var onBattery: ((Int, Bool) -> Void)?

    private var lastContent: [String: String] = [:]   // id → what we last showed
    private let q = DispatchQueue(label: "phone-notifs")

    static func categories() -> [UNNotificationCategory] {
        let reply = UNTextInputNotificationAction(identifier: "REPLY", title: "Reply", options: [],
                                                  textInputButtonTitle: "Send",
                                                  textInputPlaceholder: "Message")
        let read = UNNotificationAction(identifier: "MARKREAD", title: "Mark as Read", options: [])
        let open = UNNotificationAction(identifier: "OPENPHONE", title: "Open on Phone", options: [])
        return [
            UNNotificationCategory(identifier: replyCategory, actions: [reply, read, open],
                                   intentIdentifiers: [], options: [.customDismissAction]),
            UNNotificationCategory(identifier: plainCategory, actions: [open],
                                   intentIdentifiers: [], options: [.customDismissAction]),
        ]
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: "\n")
    }

    // MARK: phone → Mac

    /// "NOTIF id\tapp\ttitle\tbody\tcanReply\tpackage"
    func post(_ rest: String) {
        guard notificationsEnabled else { return }     // the menu's on/off switch
        let f = rest.components(separatedBy: "\t")
        guard f.count >= 5 else { return }
        let id = f[0], pkg = f.count >= 6 ? f[5] : ""
        let app = appNames[pkg] ?? f[1]
        let title = Self.unescape(f[2]), body = Self.unescape(f[3])
        let canReply = f[4] == "1"

        // Apps re-post the same notification constantly (progress, re-sorts,
        // reconnect catch-up). Only a real change deserves a banner.
        let signature = title + "\u{1}" + body
        var fresh = false
        q.sync {
            if lastContent[id] != signature { lastContent[id] = signature; fresh = true }
            if lastContent.count > 500 { lastContent.removeAll(); lastContent[id] = signature }
        }
        guard fresh else { return }

        guard useNativeNotifications else {
            notifyMac(title: title.isEmpty ? app : "\(app) — \(title)", body: body, sound: true)
            return
        }
        let c = UNMutableNotificationContent()
        c.title = title.isEmpty ? app : title
        if !title.isEmpty && title != app { c.subtitle = app }
        c.body = body
        c.sound = .default
        c.threadIdentifier = pkg.isEmpty ? app : pkg      // grouped per app in Notification Center
        c.categoryIdentifier = canReply ? Self.replyCategory : Self.plainCategory
        c.userInfo = ["phoneId": id, "package": pkg]
        // Same identifier = the banner is replaced, so one WhatsApp chat stays one entry.
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "phone-" + id, content: c, trigger: nil)) { [weak self] err in
            self?.log("posted \(id) err=\(String(describing: err))")
        }
    }

    func gone(_ id: String) {
        q.sync { _ = lastContent.removeValue(forKey: id) }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["phone-" + id])
    }

    func battery(_ rest: String) {
        let f = rest.split(separator: " ")
        guard let level = f.first.flatMap({ Int($0) }) else { return }
        let charging = f.count > 1 && f[1] == "1"
        let before = battery?.level ?? -1
        battery = (level, charging, Date())
        onBattery?(level, charging)
        if level <= 15 && !charging && (before > 15 || before < 0) {
            notifyMac(title: "Phone battery low", body: "\(level)% left on your Nothing Phone 3a.", sound: true)
        }
    }

    private let logURL = URL(fileURLWithPath: NSHomeDirectory() + "/.config/phone-control/notif.log")
    func log(_ msg: String) {
        q.async { [logURL] in
            let line = ISO8601DateFormatter().string(from: Date()) + " " + msg + "\n"
            if let h = try? FileHandle(forWritingTo: logURL) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? Data(line.utf8).write(to: logURL)
            }
        }
    }

    /// Lines from the phone this class owns. Returns false for anything else.
    func handle(line: String) -> Bool {
        if line.hasPrefix("NOTIF") || line.hasPrefix("BATT") {
            log("in: " + String(line.prefix(60)) + " native=\(useNativeNotifications) enabled=\(notificationsEnabled)")
        }
        if line.hasPrefix("NOTIF ") { post(String(line.dropFirst(6))); return true }
        if line.hasPrefix("NOTIFGONE ") { gone(String(line.dropFirst(10))); return true }
        if line.hasPrefix("NOTIFSENT ") {
            // Replied: the conversation is answered, so clear its banner.
            gone(String(line.dropFirst(10)))
            return true
        }
        if line.hasPrefix("NOTIFFAIL ") {
            let parts = line.dropFirst(10).components(separatedBy: "\t")
            notifyMac(title: "Reply not sent", body: parts.count > 1 ? parts[1] : "The phone couldn't send it.", sound: true)
            return true
        }
        if line.hasPrefix("NOTIFAPP ") { appActive = line.hasSuffix("on"); return true }
        if line.hasPrefix("BATT ") { battery(String(line.dropFirst(5))); return true }
        return false
    }

    // MARK: Mac → phone

    /// A click, a Reply, a dismiss on one of our banners. False if it isn't ours.
    func handle(response: UNNotificationResponse) -> Bool {
        guard let id = response.notification.request.content.userInfo["phoneId"] as? String else { return false }
        let server = CommandServer.shared
        // Clearing old banners while the phone is away is normal, not an error.
        if response.actionIdentifier == UNNotificationDismissActionIdentifier && !server.isConnected { return true }
        guard server.isConnected else {
            notifyMac(title: "Phone not connected",
                      body: "Open Touch Remote on the phone (same Wi-Fi or hotspot) and try again.")
            return true
        }
        switch response.actionIdentifier {
        case "REPLY":
            guard let r = response as? UNTextInputNotificationResponse else { break }
            let text = r.userText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { break }
            server.send("REPLY \(id)\t" + text.replacingOccurrences(of: "\r", with: "")
                                             .replacingOccurrences(of: "\n", with: "\\n"))
        case "MARKREAD":
            server.send("MARKREAD \(id)")
        case UNNotificationDismissActionIdentifier:
            server.send("NOTIFDISMISS \(id)")
        case "OPENPHONE", UNNotificationDefaultActionIdentifier:
            server.send("NOTIFOPEN \(id)")
        default:
            break
        }
        return true
    }
}
