import AppKit
import CoreGraphics
import CoreVideo
import ScreenCaptureKit

/// What SCStream captures. SPEC §4.8 (normative capture configuration).
enum CaptureTarget {
    case display(SCDisplay)
    case window(SCWindow)
    case area(SCDisplay, CGRect) // display points, top-left origin
}

extension CaptureTarget {
    /// `SCContentFilter` for this target: excludes every recording-flow window (`FloatingPanel.allWindowIDs`)
    /// and, when requested, the Finder desktop-icons window (SPEC open question 3).
    func filter(content: SCShareableContent, settings: RecordingSettings) -> SCContentFilter {
        switch self {
        case .display(let display), .area(let display, _):
            var excluded = content.windows.filter { FloatingPanel.allWindowIDs.contains($0.windowID) }
            if settings.hideDesktopIcons {
                // ponytail: SPEC §9 open question 3 ("which Finder windows must be excluded to hide desktop
                // icons on macOS 26?") isn't verifiable without Screen Recording permission on this machine.
                // Best-known heuristic: Finder's desktop-icons window sits at kCGDesktopIconWindowLevel.
                // Upgrade path: confirm against a live SCShareableContent listing once permission is granted,
                // record the answer in SPEC §9.
                let desktopIconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
                excluded += content.windows.filter {
                    $0.owningApplication?.bundleIdentifier == "com.apple.finder" && $0.windowLayer == desktopIconLevel
                }
            }
            return SCContentFilter(display: display, excludingWindows: excluded)
        case .window(let window):
            return SCContentFilter(desktopIndependentWindow: window)
        }
    }

    /// `SCStreamConfiguration` for this target, exactly per SPEC §4.8.
    func configuration(settings: RecordingSettings) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.queueDepth = 6
        let size = pixelSize
        config.width = Int(size.width)
        config.height = Int(size.height)
        if case .area(_, let rect) = self { config.sourceRect = rect }
        config.capturesAudio = settings.systemAudio != .off
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = settings.micID != nil
        config.microphoneCaptureDeviceID = settings.micID
        config.sampleRate = 48_000
        config.channelCount = 2
        return config
    }

    /// Even-rounded output pixel size (source points × `scale`).
    var pixelSize: CGSize {
        let points: CGSize
        switch self {
        case .display(let display): points = CGSize(width: display.width, height: display.height)
        case .window(let window): points = window.frame.size
        case .area(_, let rect): points = rect.size
        }
        func evenRound(_ v: CGFloat) -> CGFloat { (v * scale / 2).rounded() * 2 }
        return CGSize(width: evenRound(points.width), height: evenRound(points.height))
    }

    /// Points → pixels scale factor of the screen backing this target.
    var scale: CGFloat {
        switch self {
        case .display(let display), .area(let display, _):
            return CaptureTarget.screen(displayID: display.displayID)?.backingScaleFactor ?? 2
        case .window:
            // ponytail: a window's own display isn't exposed by SCWindow; main-screen scale covers the
            // common single/matched-scale-monitor case. Upgrade path: match by frame.intersects once needed.
            return NSScreen.main?.backingScaleFactor ?? 2
        }
    }

    /// Target rect in global screen points (top-left origin), for normalising `EventRecorder` coordinates.
    var frameInScreenPoints: CGRect {
        switch self {
        case .display(let display): return display.frame
        case .window(let window): return window.frame
        case .area(_, let rect): return rect
        }
    }

    /// T-610: a short human-readable description of what's being recorded, for the state snapshot
    /// (`StateSnapshot.swift`) — not a `CustomStringConvertible` conformance, just a debugging accessor.
    var targetDescription: String {
        switch self {
        case .display(let display): return "display \(display.displayID) \(Int(display.width))x\(Int(display.height))"
        case .window(let window):
            return "window \"\(window.title ?? "")\" (\(window.owningApplication?.applicationName ?? "unknown app"))"
        case .area(let display, let rect):
            return "area \(Int(rect.width))x\(Int(rect.height)) on display \(display.displayID)"
        }
    }

    private static func screen(displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }
}
