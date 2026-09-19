import Foundation
import Observation

/// Recording toolbar settings (SPEC §4.2). Persisted to `UserDefaults`, one key each, so selections
/// survive relaunch (AC-TB-3). `@Observable` so `ToolbarView` and the toolbar's `NSMenu`s stay in sync.
@Observable final class RecordingSettings {
    enum Mode: String { case display, window, area }
    enum SystemAudio: Codable, Equatable { case off, all, apps([String]) } // bundle ids

    static let shared = RecordingSettings()

    var recordAllKeys: Bool { didSet { UserDefaults.standard.set(recordAllKeys, forKey: "recording.allKeys") } }
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
    var fps: Int { didSet { UserDefaults.standard.set(fps, forKey: Keys.fps) } } // 30,60 (SPEC §8)
    var projectsFolder: URL { didSet { UserDefaults.standard.set(projectsFolder, forKey: Keys.projectsFolder) } }

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
        static let fps = "recording.fps"
        static let projectsFolder = "recording.projectsFolder"
    }

    private init() {
        let d = UserDefaults.standard
        recordAllKeys = d.bool(forKey: "recording.allKeys")
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
        fps = d.object(forKey: Keys.fps) as? Int ?? 60
        projectsFolder = d.url(forKey: Keys.projectsFolder)
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Recorder", isDirectory: true)
    }
}

/// T-609: a single global-hotkey rebinding, as `Hotkeys.rebind`/`currentBinding` (`App/Hotkeys.swift`)
/// produce and consume it. `modifiers` is `NSEvent.ModifierFlags.rawValue` (device-independent bits
/// only) rather than the type itself so this file — the persisted-settings one — needs no AppKit import.
struct HotkeyBinding: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt
    var character: String // `NSMenuItem` keyEquivalent for this binding
}

/// One JSON-encoded `UserDefaults` key holds every hotkey rebinding override, keyed by the
/// `Hotkey.title` it overrides. A free-standing Codable store rather than a `RecordingSettings`
/// property, so the Shortcuts pane and its selftest can inject a throwaway `UserDefaults` suite
/// instead of the user's real one — every call here takes `defaults` explicitly (default `.standard`),
/// the same seam `ExportSheetModel` uses for its own persistence.
enum HotkeyOverrides {
    private static let key = "recording.hotkeyOverrides"

    static func load(from defaults: UserDefaults = .standard) -> [String: HotkeyBinding] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: HotkeyBinding].self, from: data) else { return [:] }
        return decoded
    }

    static func save(_ overrides: [String: HotkeyBinding], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        defaults.set(data, forKey: key)
    }
}
