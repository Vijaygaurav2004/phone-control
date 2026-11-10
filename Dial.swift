// The CMF Buds Pro 2 Smart Dial, as a Mac input device.
//
// The dial has no special protocol — it sends ordinary Bluetooth AVRCP
// commands. Presses arrive as system-defined media key events, which an event
// tap can intercept before anything else sees them. Rotation is different:
// it changes the system output volume directly, so it is detected by watching
// that volume and undoing the change when the dial is driving something else.

import Cocoa
import CoreAudio
import AudioToolbox

final class Dial {
    static let shared = Dial()

    enum Mode: String, CaseIterable {
        case volume     = "Volume"
        case scroll     = "Scroll"
        case apps       = "Switch apps"
        case brightness = "Brightness"
        case media      = "Seek"

        var next: Mode {
            let all = Mode.allCases
            return all[(all.firstIndex(of: self)! + 1) % all.count]
        }
    }

    private(set) var running = false
    private(set) var mode: Mode = .volume

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var lastVolume: Float32 = -1
    private var holdVolume: Float32 = 0.5
    private var pressTimes: [Double] = []
    private var lastTick = 0.0
    private var lastKeyRotation = 0.0

    let logPath = NSHomeDirectory() + "/.config/phone-control/dial.log"

    private let logQueue = DispatchQueue(label: "dial.log")

    func log(_ s: String) {
        let line = s + "\n"
        logQueue.async { [logPath] in
            if let h = FileHandle(forWritingAtPath: logPath) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? line.write(toFile: logPath, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: - Lifecycle

    func toggle() { running ? stop() : start() }

    func start() {
        guard !running else { return }
        guard AXIsProcessTrusted() else {
            let a = NSAlert()
            a.messageText = "Accessibility permission needed"
            a.informativeText = "Phone Control needs Accessibility to intercept the dial's media keys."
            a.runModal()
            return
        }
        try? "".write(toFile: logPath, atomically: true, encoding: .utf8)
        log("START mode=\(mode.rawValue)")

        // System-defined events (type 14) carry the media keys the dial sends.
        let mask = CGEventMask(1 << 14)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                        place: .headInsertEventTap,
                                        options: .defaultTap,
                                        eventsOfInterest: mask,
                                        callback: { _, type, event, _ in
                                            if type == .tapDisabledByTimeout
                                                || type == .tapDisabledByUserInput {
                                                Dial.shared.reenable()
                                                return Unmanaged.passUnretained(event)
                                            }
                                            return Dial.shared.handle(event)
                                        },
                                        userInfo: nil) else {
            log("FAILED to create event tap")
            return
        }
        tap = t
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)

        watchVolume()
        running = true
    }

    func stop() {
        running = false
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil; source = nil
        unwatchVolume()
        log("STOP")
    }

    /// A tap that has been disabled by the system must be explicitly revived.
    func reenable() {
        guard let t = tap else { return }
        CGEvent.tapEnable(tap: t, enable: true)
        log("tap re-enabled after being disabled by the system")
    }

    // MARK: - Presses

    /// Returning nil swallows the event; returning it passes it through.
    private func handle(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        let data = ns.data1
        let keyCode = Int32((data & 0xFFFF_0000) >> 16)
        let keyState = ((data & 0x0000_FF00) >> 8)
        let isDown = keyState == 0x0A
        guard isDown else { return Unmanaged.passUnretained(event) }

        let name: String
        switch keyCode {
        case 16: name = "PLAY"
        case 17: name = "NEXT"
        case 18: name = "PREV"
        case 19: name = "FAST"
        case 20: name = "REWIND"
        case 0:  name = "SOUND_UP"
        case 1:  name = "SOUND_DOWN"
        case 2:  name = "BRIGHT_UP"
        case 3:  name = "BRIGHT_DOWN"
        case 7:  name = "MUTE"
        default: name = "key\(keyCode)"
        }
        log("KEY \(name) (code \(keyCode))")

        switch keyCode {
        case 16:   // a press — three in quick succession cycles the dial's mode
            let now = ProcessInfo.processInfo.systemUptime
            pressTimes = pressTimes.filter { now - $0 < 0.9 }
            pressTimes.append(now)
            if pressTimes.count >= 3 {
                pressTimes.removeAll()
                cycleMode()
                return nil          // don't also play/pause
            }
            return Unmanaged.passUnretained(event)

        case 20, 19:   // REWIND / FAST — distinct events, good for mode switching
            cycleMode()
            return nil

        case 0, 1:  // one per detent of the dial
            lastKeyRotation = ProcessInfo.processInfo.systemUptime
            if mode != .volume {
                rotate(up: keyCode == 0)
                return nil          // swallowed: the volume never moves
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    var modeName: String { mode.rawValue }

    func setMode(_ m: Mode) {
        mode = m
        log("MODE -> \(mode.rawValue)")
        if mode != .volume { holdVolume = currentVolume() }
        notifyMac(title: "Dial: \(mode.rawValue)", body: "Turn the dial to use it.")
    }

    private func cycleMode() {
        mode = mode.next
        log("MODE -> \(mode.rawValue)")
        if mode != .volume { holdVolume = currentVolume() }
        notifyMac(title: "Dial: \(mode.rawValue)",
                  body: "Triple-press to switch mode.")
    }

    // MARK: - Rotation

    /// One detent of the dial, once we know which direction it went.
    private func rotate(up: Bool) {
        log("ROTATE \(up ? "up" : "down") mode=\(mode.rawValue)")
        switch mode {
        case .volume:
            break                                   // the system already did it
        case .scroll:
            scrollBy(up ? 60 : -60)
        case .apps:
            cycleApp(next: up)
        case .brightness:
            systemKey(up ? NX_BRIGHT_UP : NX_BRIGHT_DOWN)
        case .media:
            pressKey(up ? 0x7C : 0x7B)              // → / ← : seek in most players
        }
    }

    // MARK: - Volume watching
    //
    // Rotating the dial moves the system volume. In any mode other than
    // Volume we read the direction from that movement, then put the volume
    // back so the music doesn't change while the dial drives something else.

    private func defaultOutputDevice() -> AudioObjectID {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                   &addr, 0, nil, &size, &id)
        return id
    }

    private var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    func currentVolume() -> Float32 {
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        AudioObjectGetPropertyData(deviceID, &volumeAddress, 0, nil, &size, &v)
        return v
    }

    private func setVolume(_ v: Float32) {
        var value = max(0, min(1, v))
        let size = UInt32(MemoryLayout<Float32>.size)
        AudioObjectSetPropertyData(deviceID, &volumeAddress, 0, nil, size, &value)
    }

    private func watchVolume() {
        deviceID = defaultOutputDevice()
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else {
            log("no default output device")
            return
        }
        lastVolume = currentVolume()
        holdVolume = lastVolume
        log("watching device \(deviceID), volume \(lastVolume)")

        AudioObjectAddPropertyListenerBlock(deviceID, &volumeAddress, DispatchQueue.main) { _, _ in
            Dial.shared.volumeChanged()
        }

        // Re-attach if the output device changes (buds reconnecting, for example).
        var defaultAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                            &defaultAddr, DispatchQueue.main) { _, _ in
            let fresh = Dial.shared.defaultOutputDeviceID()
            if fresh != Dial.shared.deviceID {
                Dial.shared.log("output device changed \(Dial.shared.deviceID) -> \(fresh)")
                Dial.shared.rebindVolume()
            }
        }
    }

    func defaultOutputDeviceID() -> AudioObjectID { defaultOutputDevice() }

    func rebindVolume() {
        unwatchVolume()
        watchVolume()
    }

    private func unwatchVolume() {
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else { return }
        AudioObjectRemovePropertyListenerBlock(deviceID, &volumeAddress, DispatchQueue.main) { _, _ in }
    }

    private var lastDelta: Float32 = 0
    private var lastDeltaAt = 0.0
    private var restoreWork: DispatchWorkItem?

    private func volumeChanged() {
        let now = currentVolume()
        let delta = now - lastVolume
        let was = lastVolume
        lastVolume = now
        guard abs(delta) > 0.001 else { return }

        let t = ProcessInfo.processInfo.systemUptime

        // The buds sync their own volume back, so every real turn is followed
        // by an equal and opposite change. Treat that echo as noise, not as a
        // turn in the other direction.
        if abs(delta + lastDelta) < 0.01, t - lastDeltaAt < 0.8 {
            log(String(format: "VOLUME echo ignored (%+.3f)", delta))
            lastDelta = 0
            return
        }
        lastDelta = delta
        lastDeltaAt = t

        log(String(format: "VOLUME %.3f -> %.3f (delta %+.3f) mode=%@",
                   was, now, delta, mode.rawValue))

        guard mode != .volume else { return }

        // If the dial is sending proper key events, they already handled this
        // turn — acting on the volume change too would double every step.
        if t - lastKeyRotation < 3.0 {
            log("  (handled by key events; ignoring volume path)")
            return
        }

        if t - lastTick > 0.05 {
            lastTick = t
            rotate(up: delta > 0)
        }

        // Put the volume back, but after the echo has landed — setting it
        // immediately just starts another round of syncing.
        restoreWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.mode != .volume else { return }
            if abs(self.currentVolume() - self.holdVolume) > 0.01 {
                self.setVolume(self.holdVolume)
                self.lastVolume = self.holdVolume
            }
        }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }
}
