// Receiving the phone's screen.
//
// The phone sends H.264 access units framed on the same socket as the text
// commands. Here they are turned into CMSampleBuffers and handed to an
// AVSampleBufferDisplayLayer, which does the decoding itself — no explicit
// VTDecompressionSession needed.

import Cocoa
import AVFoundation
import CoreMedia

final class Mirror {
    static let shared = Mirror()

    private var window: NSWindow?
    private var layer: AVSampleBufferDisplayLayer?
    private var format: CMFormatDescription?
    private var sps: Data?
    private var pps: Data?
    private var phoneSize = CGSize(width: 1080, height: 2392)
    private var pending = Data()          // accumulates chunks of one access unit
    private var waitingForKeyframe = true

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

        let view = NSView(frame: rect)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor

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

        win.contentView = view
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
            guard ok == noErr, let d = desc else { return }
            self.format = d
            self.waitingForKeyframe = true
            self.ensureWindow()
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

        if layer.status == .failed {
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
