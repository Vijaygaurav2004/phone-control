// Receiving the phone's screen.
//
// The phone sends H.264 access units framed on the same socket as the text
// commands. Here they are turned into CMSampleBuffers and handed to an
// AVSampleBufferDisplayLayer, which does the decoding itself — no explicit
// VTDecompressionSession needed.

import Cocoa
import AVFoundation
import CoreMedia

/// The mirror's content view. Clicks and drags here become taps and swipes on
/// the phone; keystrokes become typed text.
final class MirrorView: NSView {
    var phoneSize = CGSize(width: 1080, height: 2392)
    var onCommand: ((String) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The video is letterboxed inside the view, so a click has to be mapped
    /// through the actual picture rectangle rather than the whole view.
    private var videoRect: CGRect {
        let b = bounds
        guard phoneSize.width > 0, phoneSize.height > 0, b.width > 0, b.height > 0 else { return b }
        let scale = min(b.width / phoneSize.width, b.height / phoneSize.height)
        let w = phoneSize.width * scale, h = phoneSize.height * scale
        return CGRect(x: b.midX - w / 2, y: b.midY - h / 2, width: w, height: h)
    }

    /// nil when the click landed on the letterbox rather than the picture.
    private func phonePoint(_ event: NSEvent) -> CGPoint? {
        let p = convert(event.locationInWindow, from: nil)
        let r = videoRect
        guard r.contains(p) else { return nil }
        let fx = (p.x - r.minX) / r.width
        // AppKit's origin is bottom-left; the phone's is top-left.
        let fy = 1 - (p.y - r.minY) / r.height
        return CGPoint(x: fx * phoneSize.width, y: fy * phoneSize.height)
    }

    private func send(_ s: String) { onCommand?(s) }
    private func fmt(_ p: CGPoint) -> String {
        String(format: "%.0f %.0f", p.x, p.y)
    }

    override func mouseDown(with event: NSEvent) {
        guard let p = phonePoint(event) else { return }
        window?.makeFirstResponder(self)
        send((event.clickCount >= 2 ? "LONG " : "DOWN ") + fmt(p))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let p = phonePoint(event) else { return }
        send("MOVE " + fmt(p))
    }

    override func mouseUp(with event: NSEvent) {
        guard let p = phonePoint(event) else { return }
        send("UP " + fmt(p))
    }

    override func rightMouseDown(with event: NSEvent) {
        send("NAV back")
    }

    /// Two-finger scroll becomes a swipe — this is how Reels and feeds move.
    private var scrollAccum: CGFloat = 0
    private var lastScrollAt = Date.distantPast

    override func scrollWheel(with event: NSEvent) {
        guard let p = phonePoint(event) else { return }
        scrollAccum += event.scrollingDeltaY
        let now = Date()
        guard abs(scrollAccum) > 28, now.timeIntervalSince(lastScrollAt) > 0.18 else { return }
        lastScrollAt = now
        let distance = min(abs(scrollAccum) * 6, phoneSize.height * 0.45)
        let up = scrollAccum < 0        // natural scrolling: content follows fingers
        let from = p.y + (up ? distance / 2 : -distance / 2)
        let to   = p.y + (up ? -distance / 2 : distance / 2)
        scrollAccum = 0
        send(String(format: "SWIPE %.0f %.0f %.0f %.0f 110",
                    p.x, max(0, min(phoneSize.height - 1, from)),
                    p.x, max(0, min(phoneSize.height - 1, to))))
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51:  send("BKSP")                 // delete
        case 53:  send("NAV back")             // esc
        case 36:  send("TYPE \n")              // return
        case 126: send("NAV home")             // up arrow
        default:
            if let chars = event.characters, !chars.isEmpty,
               event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                send("TYPE " + chars)
            }
        }
    }
}

final class Mirror {
    static let shared = Mirror()

    /// Kept above other windows, so it stays visible while you work.
    static var alwaysOnTop = UserDefaults.standard.object(forKey: "mirrorOnTop") as? Bool ?? true

    func applyOnTop() {
        DispatchQueue.main.async {
            self.window?.level = Mirror.alwaysOnTop ? .floating : .normal
            self.window?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
    }

    private var window: NSWindow?
    private var contentView: MirrorView?
    private var layer: AVSampleBufferDisplayLayer?
    private var format: CMFormatDescription?
    private var sps: Data?
    private var pps: Data?
    private var phoneSize = CGSize(width: 1080, height: 2392)
    private var pending = Data()          // accumulates chunks of one access unit
    private var waitingForKeyframe = true
    private var frameCount = 0

    // MARK: - Window

    private func ensureWindow() {
        guard window == nil else { return }
        let aspect = phoneSize.height / max(phoneSize.width, 1)
        let w: CGFloat = 420
        let rect = NSRect(x: 120, y: 120, width: w, height: w * aspect)

        let win = NSWindow(contentRect: rect,
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "Nothing Phone 3a"
        win.isReleasedWhenClosed = false
        win.backgroundColor = .black
        win.contentAspectRatio = NSSize(width: phoneSize.width, height: phoneSize.height)

        let view = MirrorView(frame: rect)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.phoneSize = phoneSize
        view.onCommand = { CommandServer.shared.send($0) }
        self.contentView = view

        let display = AVSampleBufferDisplayLayer()
        display.videoGravity = .resizeAspect
        display.frame = view.bounds
        display.backgroundColor = NSColor.black.cgColor
        // Without a timebase the layer waits for a clock that never starts and
        // nothing is ever drawn.
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                                        sourceClock: CMClockGetHostTimeClock(),
                                        timebaseOut: &timebase)
        if let tb = timebase {
            CMTimebaseSetTime(tb, time: .zero)
            CMTimebaseSetRate(tb, rate: 1.0)
            display.controlTimebase = tb
        }
        view.layer?.addSublayer(display)
        view.layerContentsRedrawPolicy = .onSetNeedsDisplay

        // Show on every desktop, and over full-screen apps — otherwise the
        // window is stranded on whichever Space it happened to open in.
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if Mirror.alwaysOnTop { win.level = .floating }

        win.contentView = view
        win.makeFirstResponder(view)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Keep the layer filling the window as it resizes.
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                                               object: win, queue: .main) { _ in
            if let v = win.contentView { display.frame = v.bounds }
        }

        window = win
        layer = display
    }

    func close() {
        DispatchQueue.main.async {
            self.window?.orderOut(nil)
            self.window = nil
            self.contentView = nil
            self.layer = nil
            self.format = nil
            self.sps = nil; self.pps = nil
            self.pending.removeAll()
            self.waitingForKeyframe = true
        }
    }

    // MARK: - Stream

    /// Codec config: SPS/PPS in Annex-B, plus the encoder's geometry.
    func configure(csd: Data, width: Int, height: Int) {
        var foundSPS: Data?, foundPPS: Data?
        for nal in Mirror.splitAnnexB(csd) {
            guard let first = nal.first else { continue }
            switch first & 0x1F {
            case 7: foundSPS = nal
            case 8: foundPPS = nal
            default: break
            }
        }
        NSLog("[mirror] config %d bytes, %dx%d, sps=%@ pps=%@", csd.count, width, height,
              foundSPS == nil ? "no" : "yes", foundPPS == nil ? "no" : "yes")
        guard let s = foundSPS, let p = foundPPS else { return }

        DispatchQueue.main.async {
            self.sps = s; self.pps = p
            self.phoneSize = CGSize(width: max(width, 1), height: max(height, 1))

            var desc: CMFormatDescription?
            let ok: OSStatus = s.withUnsafeBytes { sBuf in
                p.withUnsafeBytes { pBuf in
                    let params = [sBuf.bindMemory(to: UInt8.self).baseAddress!,
                                  pBuf.bindMemory(to: UInt8.self).baseAddress!]
                    let sizes = [s.count, p.count]
                    return params.withUnsafeBufferPointer { pp in
                        sizes.withUnsafeBufferPointer { ss in
                            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                                allocator: kCFAllocatorDefault,
                                parameterSetCount: 2,
                                parameterSetPointers: pp.baseAddress!,
                                parameterSetSizes: ss.baseAddress!,
                                nalUnitHeaderLength: 4,
                                formatDescriptionOut: &desc)
                        }
                    }
                }
            }
            guard ok == noErr, let d = desc else {
                NSLog("[mirror] format description FAILED: %d", ok); return
            }
            NSLog("[mirror] format description ok — opening window")
            self.format = d
            self.waitingForKeyframe = true
            self.ensureWindow()
            self.contentView?.phoneSize = self.phoneSize
            self.window?.contentAspectRatio = NSSize(width: self.phoneSize.width,
                                                     height: self.phoneSize.height)
        }
    }

    /// One chunk of an access unit. `last` completes it.
    func append(chunk: Data, keyframe: Bool, continuation: Bool, last: Bool) {
        if !continuation { pending.removeAll(keepingCapacity: true) }
        pending.append(chunk)
        guard last else { return }
        let au = pending
        pending.removeAll(keepingCapacity: true)
        DispatchQueue.main.async { self.decode(au: au, keyframe: keyframe) }
    }

    private func decode(au: Data, keyframe: Bool) {
        guard let format else { return }
        // After a gap, anything before the next IDR would decode to garbage.
        if waitingForKeyframe {
            guard keyframe else { return }
            waitingForKeyframe = false
        }
        ensureWindow()
        guard let layer else { return }

        // Annex-B start codes become 4-byte big-endian lengths (AVCC).
        var avcc = Data()
        for nal in Mirror.splitAnnexB(au) {
            var len = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &len) { avcc.append(contentsOf: $0) }
            avcc.append(nal)
        }
        guard !avcc.isEmpty else { return }

        var block: CMBlockBuffer?
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: avcc.count, alignment: 1)
        avcc.copyBytes(to: bytes.assumingMemoryBound(to: UInt8.self), count: avcc.count)
        guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: bytes,
                blockLength: avcc.count, blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil, offsetToData: 0, dataLength: avcc.count,
                flags: 0, blockBufferOut: &block) == noErr, let block else {
            bytes.deallocate(); return
        }

        var sample: CMSampleBuffer?
        var sizes = [avcc.count]
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: .invalid,
                                        decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault, dataBuffer: block,
                formatDescription: format, sampleCount: 1,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 1, sampleSizeArray: &sizes,
                sampleBufferOut: &sample) == noErr, let sample else { return }

        // Show it as soon as it decodes rather than scheduling against a clock.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0),
                                     to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        frameCount += 1
        if frameCount == 1 || frameCount % 300 == 0 {
            NSLog("[mirror] decoded frame %d, layer status %d", frameCount, layer.status.rawValue)
        }
        if layer.status == .failed {
            NSLog("[mirror] layer FAILED: %@", String(describing: layer.error))
            layer.flush()
            waitingForKeyframe = true
            CommandServer.shared.send("KEYFRAME")   // ask the phone for a fresh IDR
            return
        }
        layer.enqueue(sample)
    }

    /// Split an Annex-B buffer into NAL units, dropping the start codes.
    static func splitAnnexB(_ data: Data) -> [Data] {
        var out: [Data] = []
        let bytes = [UInt8](data)
        var starts: [Int] = []
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                starts.append(i + 3); i += 3
            } else if i + 3 < bytes.count,
                      bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                starts.append(i + 4); i += 4
            } else {
                i += 1
            }
        }
        for (n, s) in starts.enumerated() {
            let end = n + 1 < starts.count ? starts[n + 1] - 3 : bytes.count
            var e = end
            // Trim the trailing zeros that belong to the next start code.
            while e > s, e - 1 < bytes.count, bytes[e - 1] == 0 { e -= 1 }
            if e > s { out.append(Data(bytes[s..<e])) }
        }
        return out
    }
}
