import Foundation
import Observation

/// Recording toolbar settings (SPEC §4.2). Persisted to `UserDefaults`, one key each, so selections
/// survive relaunch (AC-TB-3). `@Observable` so `ToolbarView` and the toolbar's `NSMenu`s stay in sync.
@Observable final class RecordingSettings {
    enum Mode: String { case display, window, area }
    enum SystemAudio: Codable, Equatable { case off, all, apps([String]) } // bundle ids

    static let shared = RecordingSettings()

    var mode: Mode { didSet { UserDefaults.standard.set(mode.rawValue, forKey: Keys.mode) } }
    var cameraID: String? { didSet { UserDefaults.standard.set(cameraID, forKey: Keys.cameraID) } }
    var micID: String? { didSet { UserDefaults.standard.set(micID, forKey: Keys.micID) } }
    var systemAudio: SystemAudio {
        didSet {
            if let data = try? JSONEncoder().encode(systemAudio) {
                UserDefaults.standard.set(data, forKey: Keys.systemAudio)
            }
        }
    }
    var denoise: Bool { didSet { UserDefaults.standard.set(denoise, forKey: Keys.denoise) } }
    var disableAGC: Bool { didSet { UserDefaults.standard.set(disableAGC, forKey: Keys.disableAGC) } }
    var hideDesktopIcons: Bool { didSet { UserDefaults.standard.set(hideDesktopIcons, forKey: Keys.hideDesktopIcons) } }
    var hideDockIcon: Bool { didSet { UserDefaults.standard.set(hideDockIcon, forKey: Keys.hideDockIcon) } }
    var highlightArea: Bool { didSet { UserDefaults.standard.set(highlightArea, forKey: Keys.highlightArea) } }
    var countdown: Int { didSet { UserDefaults.standard.set(countdown, forKey: Keys.countdown) } } // 0,3,5,10

    private enum Keys {
        static let mode = "recording.mode"
        static let cameraID = "recording.cameraID"
        static let micID = "recording.micID"
        static let systemAudio = "recording.systemAudio"
        static let denoise = "recording.denoise"
        static let disableAGC = "recording.disableAGC"
        static let hideDesktopIcons = "recording.hideDesktopIcons"
        static let hideDockIcon = "recording.hideDockIcon"
        static let highlightArea = "recording.highlightArea"
        static let countdown = "recording.countdown"
    }

    private init() {
        let d = UserDefaults.standard
        mode = Mode(rawValue: d.string(forKey: Keys.mode) ?? "") ?? .display
        cameraID = d.string(forKey: Keys.cameraID)
        micID = d.string(forKey: Keys.micID)
        if let data = d.data(forKey: Keys.systemAudio), let v = try? JSONDecoder().decode(SystemAudio.self, from: data) {
            systemAudio = v
        } else {
            systemAudio = .off
        }
        denoise = d.object(forKey: Keys.denoise) as? Bool ?? false
        disableAGC = d.object(forKey: Keys.disableAGC) as? Bool ?? false
        hideDesktopIcons = d.object(forKey: Keys.hideDesktopIcons) as? Bool ?? false
        hideDockIcon = d.object(forKey: Keys.hideDockIcon) as? Bool ?? true
        highlightArea = d.object(forKey: Keys.highlightArea) as? Bool ?? true
        countdown = d.object(forKey: Keys.countdown) != nil ? d.integer(forKey: Keys.countdown) : 0
    }
}
