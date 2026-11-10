// Sending this Mac's screen to the phone.
//
// ScreenCaptureKit captures the display, VideoToolbox encodes it to H.264 on
// the M1's hardware encoder, and the result goes down the same socket in the
// same 0xAB-framed envelope the phone uses to send its own screen — the
// protocol was direction-agnostic from the start, so nothing about it changed.
//
// Taps on the phone come back as fractions of the picture (0…1), which map
// onto this display's coordinates regardless of how either screen is scaled.

import Cocoa
import ScreenCaptureKit
import VideoToolbox
import CoreMedia

final class Cast: NSObject, SCStreamOutput, SCStreamDelegate {
    static let shared = Cast()

    private(set) var running = false
    private var stream: SCStream?
    private var session: VTCompressionSession?
    private let captureQueue = DispatchQueue(label: "cast.capture", qos: .userInteractive)

    private var displayID: CGDirectDisplayID = CGMainDisplayID()
    private var width = 0, height = 0
    private var forceKey = true
    private var frameIndex: Int64 = 0

    // Backpressure: Wi-Fi can't always keep up with a full-motion desktop.
    private let inFlightLock = NSLock()
    private var inFlight = 0
    /// Whole frames, not chunks: ~100 ms of video waiting is the most we allow
    /// before skipping, which is what keeps latency from creeping up.
    private let maxInFlight = 3

    // MARK: - Lifecycle

    func start() {
        guard !running else { return }
        running = true
        forceKey = true
        frameIndex = 0
        inFlightLock.lock(); inFlight = 0; inFlightLock.unlock()

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self else { return }
            guard let content else {
                self.running = false
                NSLog("[cast] no shareable content: %@", String(describing: error))
                CommandServer.shared.send("CASTERR Screen Recording permission is needed on the Mac")
                DispatchQueue.main.async { self.askForPermission() }
                return
            }
            // The display the cursor is on is the one you're looking at.
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            let wanted = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                ?? CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == wanted })
                    ?? content.displays.first else {
                self.running = false
                return
            }
            self.displayID = display.displayID
            self.begin(display: display)
        }
    }

    func stop() {
        guard running else { return }
        running = false
        stream?.stopCapture { _ in }
        stream = nil
        if let s = session {
            VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(s)
        }
        session = nil
        NSLog("[cast] stopped")
    }

    private func begin(display: SCDisplay) {
        // Scale to something Wi-Fi and a phone decoder handle comfortably,
        // keeping the aspect ratio. Encoders want even dimensions.
        let srcW = CGFloat(display.width), srcH = CGFloat(display.height)
        let scale = min(1.0, 1600 / max(srcW, srcH)) * 2   // points → ~retina detail
        width  = Int(min(srcW * scale, 1680)) & ~1
        height = Int(CGFloat(width) * srcH / srcW) & ~1

        let cfg = SCStreamConfiguration()
        cfg.width = width
        cfg.height = height
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.showsCursor = true
        cfg.queueDepth = 3

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        do {
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        } catch {
            NSLog("[cast] addStreamOutput failed: %@", String(describing: error))
            running = false
            return
        }
        guard makeEncoder() else { running = false; return }

        stream = s
        s.startCapture { [weak self] error in
            if let error {
                NSLog("[cast] startCapture failed: %@", String(describing: error))
                self?.running = false
                CommandServer.shared.send("CASTERR " + error.localizedDescription)
                DispatchQueue.main.async { self?.askForPermission() }
            } else {
                NSLog("[cast] capturing %dx%d", self?.width ?? 0, self?.height ?? 0)
                CommandServer.shared.send("LOG cast capturing \(self?.width ?? 0)x\(self?.height ?? 0)")
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("[cast] stream stopped: %@", String(describing: error))
        running = false
    }

    private func askForPermission() {
        let a = NSAlert()
        a.messageText = "Screen Recording permission needed"
        a.informativeText = "To show your Mac's screen on your phone, allow Phone Control under System Settings → Privacy & Security → Screen & System Audio Recording, then try again from the phone."
        a.addButton(withTitle: "Open Settings")
        a.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Encoder

    private func makeEncoder() -> Bool {
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard status == noErr, let s else {
            NSLog("[cast] encoder create failed: %d", status)
            return false
        }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_Main_AutoLevel)
        // B-frames reorder output, which adds latency and complicates the phone side.
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        // Keyframes are big; fewer of them means fewer bursts that stall Wi-Fi.
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 240 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: 8_000_000 as CFNumber)
        // Emit each frame the moment it is encoded, never hold one back.
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 30 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s
        return true
    }

    // MARK: - Frames in

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, running, let session, sb.isValid else { return }

        // ScreenCaptureKit also sends "nothing changed" frames; only real ones
        // carry new pixels.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: raw), status != .complete {
            return
        }
        guard let pixels = CMSampleBufferGetImageBuffer(sb) else { return }

        inFlightLock.lock()
        let backlog = inFlight
        inFlightLock.unlock()
        if backlog > maxInFlight {
            forceKey = true      // we're about to skip; the next sent frame must be self-contained
            return
        }

        var props: CFDictionary?
        if forceKey {
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            forceKey = false
        }
        frameIndex += 1
        let pts = CMTime(value: frameIndex, timescale: 30)
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixels,
                                        presentationTimeStamp: pts, duration: .invalid,
                                        frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, out in
            guard status == noErr, let out, let self else { return }
            self.send(encoded: out)
        }
    }

    // MARK: - Frames out

    private func send(encoded sb: CMSampleBuffer) {
        var isKey = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
           let notSync = attachments.first?[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKey = !notSync
        }

        // Every keyframe carries fresh SPS/PPS, so the phone can always rejoin.
        if isKey, let desc = CMSampleBufferGetFormatDescription(sb) {
            var csd = Data()
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                desc, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    desc, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil) == noErr, let ptr {
                    csd.append(contentsOf: [0, 0, 0, 1])
                    csd.append(ptr, count: size)
                }
            }
            var header = Data()
            var w = UInt32(width).bigEndian, h = UInt32(height).bigEndian
            withUnsafeBytes(of: &w) { header.append(contentsOf: $0) }
            withUnsafeBytes(of: &h) { header.append(contentsOf: $0) }
            CommandServer.shared.sendFrame(type: 0x03, flags: 0, payload: header + csd)
        }

        // VideoToolbox emits AVCC (4-byte big-endian lengths); the phone's
        // decoder wants Annex-B start codes, same as the Mac receives from it.
        guard let block = CMSampleBufferGetDataBuffer(sb) else { return }
        var total = 0
        var base: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &total, dataPointerOut: &base) == noErr,
              let base else { return }

        var annexB = Data(capacity: total + 16)
        var offset = 0
        base.withMemoryRebound(to: UInt8.self, capacity: total) { bytes in
            while offset + 4 <= total {
                let len = (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16)
                        | (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
                offset += 4
                guard len > 0, offset + len <= total else { break }
                annexB.append(contentsOf: [0, 0, 0, 1])
                annexB.append(bytes + offset, count: len)
                offset += len
            }
        }

        // Chunked like the phone's sender, so input from the phone never waits
        // behind a whole keyframe.
        let chunk = 8 * 1024
        var sent = 0
        var first = true
        inFlightLock.lock(); inFlight += 1; inFlightLock.unlock()
        while sent < annexB.count {
            let n = min(chunk, annexB.count - sent)
            let last = sent + n >= annexB.count
            var flags: UInt8 = 0
            if isKey { flags |= 0x01 }
            if !first { flags |= 0x02 }
            if last { flags |= 0x04 }
            let ok = CommandServer.shared.sendFrame(
                type: 0x02, flags: flags, payload: annexB.subdata(in: sent..<(sent + n)),
                onSent: last ? { [weak self] in self?.sendCompleted() } : nil)
            if !ok { sendCompleted(); return }
            sent += n
            first = false
        }
    }

    /// The phone dropped a frame or just (re)built its decoder.
    func requestKeyframe() { forceKey = true }

    func sendCompleted() {
        inFlightLock.lock(); inFlight = max(0, inFlight - 1); inFlightLock.unlock()
    }

    // MARK: - Input from the phone

    /// A fraction of the picture (0…1) → this display's global coordinates.
    func point(fx: Double, fy: Double) -> CGPoint {
        let b = CGDisplayBounds(displayID)
        return CGPoint(x: b.minX + CGFloat(max(0, min(1, fx))) * b.width,
                       y: b.minY + CGFloat(max(0, min(1, fy))) * b.height)
    }

    func tap(fx: Double, fy: Double, right: Bool = false) {
        let p = point(fx: fx, fy: fy)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        let (down, up): (CGEventType, CGEventType) =
            right ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
        for t in [down, up] {
            CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p,
                    mouseButton: right ? .right : .left)?.post(tap: .cghidEventTap)
        }
    }

    private var dragging = false

    func press(fx: Double, fy: Double) {
        let p = point(fx: fx, fy: fy)
        dragging = true
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    func drag(fx: Double, fy: Double) {
        let p = point(fx: fx, fy: fy)
        CGEvent(mouseEventSource: nil, mouseType: dragging ? .leftMouseDragged : .mouseMoved,
                mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    func release(fx: Double, fy: Double) {
        let p = point(fx: fx, fy: fy)
        dragging = false
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
}
