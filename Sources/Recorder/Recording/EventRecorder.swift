import AppKit
import CoreGraphics
import CoreMedia
import CryptoKit
import Darwin
import Dispatch
import RecorderCore
import ScreenCaptureKit

/// Records mouse/keyboard/cursor activity during a recording (SPEC §4.8) into normalised source
/// coordinates, on the same "seconds since first screen frame" clock as the media writers (T-110).
/// Privacy: typed text is never logged — see `recordKey`. Do not relax that rule.
final class EventRecorder {
    private let target: CaptureTarget
    private let cursorsDir: URL

    private var t0Seconds: Double = 0
    private var pausedSoFar: Double = 0
    private var pauseStartSeconds: Double?

    private let lock = NSLock()
    private var events: [InputEvent] = []
    private var lastMoveT = -Double.infinity
    private var knownCursorIDs = Set<String>()
    private var lastCursorID: String?
    private var currentTargetFrame: CGRect

    private var tapThread: Thread?
    private var eventTap: CFMachPort?
    private var tapRunLoop: CFRunLoop?

    private var cursorTimer: DispatchSourceTimer?
    private var windowFrameTimer: DispatchSourceTimer?

    init(target: CaptureTarget, cursorsDir: URL) {
        self.target = target
        self.cursorsDir = cursorsDir
        self.currentTargetFrame = target.frameInScreenPoints
        try? FileManager.default.createDirectory(at: cursorsDir, withIntermediateDirectories: true)
    }

    /// Call when the first screen frame arrives. `t0HostTime` is that frame's PTS, on the host-time
    /// clock (`CMClockGetHostTimeClock()`), the same clock `mach_absolute_time()` uses — so it and
    /// every event/cursor timestamp below share one origin.
    func start(t0HostTime: CMTime) {
        t0Seconds = CMTimeGetSeconds(t0HostTime)
        startEventTap()
        startCursorTimer()
        if case .window = target { startWindowFrameTimer() }
    }

    func pause() { pauseStartSeconds = EventRecorder.hostSeconds() }

    func resume() {
        guard let started = pauseStartSeconds else { return }
        pausedSoFar += EventRecorder.hostSeconds() - started
        pauseStartSeconds = nil
    }

    func stop() -> EventLog {
        if let runLoop = tapRunLoop { CFRunLoopStop(runLoop) }
        tapThread = nil
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        eventTap = nil
        tapRunLoop = nil
        cursorTimer?.cancel(); cursorTimer = nil
        windowFrameTimer?.cancel(); windowFrameTimer = nil
        lock.lock(); defer { lock.unlock() }
        return EventLog(events: events.sorted { $0.t < $1.t })
    }

    // MARK: - Clock

    /// `mach_absolute_time()` converted to seconds via `mach_timebase_info` — the same base as
    /// `t0HostTime` (host-time clock).
    private static func hostSeconds(_ ticks: UInt64 = mach_absolute_time()) -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(ticks) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }

    private func outputTime(_ hostSeconds: Double) -> Double { hostSeconds - t0Seconds - pausedSoFar }

    private func record(_ event: InputEvent) { lock.lock(); events.append(event); lock.unlock() }

    // MARK: - CGEventTap (mouse + key events)

    private static let interestMask: CGEventMask = {
        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .scrollWheel, .keyDown, .flagsChanged,
        ]
        return types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
    }()

    /// `CGEvent.tapCreate` on a dedicated thread's run loop (SPEC §4.8). If Accessibility/Input
    /// Monitoring isn't granted, `tapCreate` returns nil; this degrades to cursor-only recording
    /// rather than throwing, so a recording never hard-fails on a missing TCC grant here.
    private func startEventTap() {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let self else { ready.signal(); return }
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                               eventsOfInterest: EventRecorder.interestMask,
                                               callback: EventRecorder.tapCallback, userInfo: refcon) else {
                ready.signal()
                return
            }
            self.eventTap = tap
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            self.tapRunLoop = CFRunLoopGetCurrent()
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "EventRecorder.tap"
        thread.start()
        tapThread = thread
        _ = ready.wait(timeout: .now() + 2)
    }

    private static let tapCallback: CGEventTapCallBack = { _, type, cgEvent, refcon in
        if let refcon {
            Unmanaged<EventRecorder>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: cgEvent)
        }
        return Unmanaged.passUnretained(cgEvent)
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // `CGEvent.timestamp` is already nanoseconds (not mach ticks): on Apple Silicon the 125/3
        // timebase would inflate it ~41.7× and push every event past the end of the recording.
        let t = outputTime(Double(event.timestamp) / 1_000_000_000)
        guard t >= 0 else { return } // pre-t0 stragglers
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard t - lastMoveT >= 1.0 / 240 else { return } // coalesce moves closer than 1/240 s
            lastMoveT = t
            let p = normalized(event.location)
            record(InputEvent(t: t, k: type == .mouseMoved ? .move : .drag, x: p.x, y: p.y))
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let p = normalized(event.location)
            record(InputEvent(t: t, k: .down, x: p.x, y: p.y, b: buttonNumber(type)))
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            let p = normalized(event.location)
            record(InputEvent(t: t, k: .up, x: p.x, y: p.y, b: buttonNumber(type)))
        case .scrollWheel:
            let p = normalized(event.location)
            record(InputEvent(t: t, k: .scroll, x: p.x, y: p.y))
        case .keyDown, .flagsChanged:
            recordKey(t: t, event: event)
        default:
            break
        }
    }

    private func buttonNumber(_ type: CGEventType) -> Int {
        switch type {
        case .leftMouseDown, .leftMouseUp: return 0
        case .rightMouseDown, .rightMouseUp: return 1
        default: return 2
        }
    }

    /// Privacy rule (SPEC §4.8, CLAUDE.md): store `.key` (with `keyCode` + modifiers) only when a
    /// ⌘/⌃/⌥ modifier is held or the key is non-printing (arrows, return, esc, tab, delete, F-keys).
    /// Every other keystroke is logged as a timestamp-only `.typing` row with **no keyCode** — typed
    /// text is never recoverable from `events.json`. Do not relax this.
    private func recordKey(t: Double, event: CGEvent) {
        let flags = event.flags
        let hasModifier = flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate)
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if hasModifier || EventRecorder.nonPrintingKeyCodes.contains(keyCode) {
            record(InputEvent(t: t, k: .key, keyCode: keyCode, mods: UInt(flags.rawValue)))
        } else {
            record(InputEvent(t: t, k: .typing))
        }
    }

    // Virtual keycodes (Carbon `HIToolbox/Events.h`) for arrows, return, esc, tab, delete, F-keys.
    private static let nonPrintingKeyCodes: Set<Int> = [
        36, 48, 51, 53, 76,                          // return, tab, delete, esc, keypadEnter
        123, 124, 125, 126,                          // left, right, down, up
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, // F1–F10
        103, 111,                                      // F11, F12
    ]

    // MARK: - Position

    /// `event.location` (global, top-left origin) → normalised 0…1 of the captured target rect.
    private func normalized(_ globalPoint: CGPoint) -> (x: Double, y: Double) {
        let frame = currentFrame()
        guard frame.width > 0, frame.height > 0 else { return (0, 0) }
        return (Double((globalPoint.x - frame.minX) / frame.width), Double((globalPoint.y - frame.minY) / frame.height))
    }

    private func currentFrame() -> CGRect { lock.lock(); defer { lock.unlock() }; return currentTargetFrame }

    /// Window capture: the window can move while recording, so re-read its frame at 10 Hz (SPEC §4.8)
    /// via Quartz's window list (no extra TCC grant beyond what capture itself already needs).
    private func startWindowFrameTimer() {
        guard case .window(let window) = target else { return }
        let windowID = window.windowID
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: 0.1)
        timer.setEventHandler { [weak self] in
            guard let self,
                  let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
                  let boundsDict = info.first?[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { return }
            self.lock.lock(); self.currentTargetFrame = rect; self.lock.unlock()
        }
        timer.resume()
        windowFrameTimer = timer
    }

    // MARK: - Cursor image

    // ponytail: `NSCursor.currentSystem` is deprecated but functional (SPEC §4.8); replace if Apple
    // removes it — the CGEventTap/CGWindowList mechanics above are unaffected either way.
    private func startCursorTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: 1.0 / 60)
        timer.setEventHandler { [weak self] in self?.sampleCursor() }
        timer.resume()
        cursorTimer = timer
    }

    private func sampleCursor() {
        guard let cursor = NSCursor.currentSystem, let tiff = cursor.image.tiffRepresentation else { return }
        let id = EventRecorder.cursorID(for: tiff)
        guard id != lastCursorID else { return } // only log on change
        lastCursorID = id

        let isNew: Bool = { lock.lock(); defer { lock.unlock() }
            let n = !knownCursorIDs.contains(id); if n { knownCursorIDs.insert(id) }; return n
        }()
        if isNew { writeCursorImage(cursor, id: id) }

        let t = outputTime(EventRecorder.hostSeconds())
        guard t >= 0 else { return }
        record(InputEvent(t: t, k: .cursor, id: id))
    }

    private static func cursorID(for tiff: Data) -> String {
        SHA256.hash(data: tiff).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private func writeCursorImage(_ cursor: NSCursor, id: String) {
        guard let rep = cursor.image.representations.compactMap({ $0 as? NSBitmapImageRep }).max(by: { $0.pixelsWide < $1.pixelsWide }),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let scale = cursor.image.size.width > 0 ? Double(rep.pixelsWide) / Double(cursor.image.size.width) : 1
        let json: [String: Double] = ["hotX": cursor.hotSpot.x * scale, "hotY": cursor.hotSpot.y * scale, "scale": scale]
        try? png.write(to: cursorsDir.appendingPathComponent("\(id).png"))
        try? (try? JSONSerialization.data(withJSONObject: json))?.write(to: cursorsDir.appendingPathComponent("\(id).json"))
    }
}
