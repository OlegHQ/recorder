import AppKit

/// One entry per global default in SPEC §4.7. `keyCode`/`modifiers`/`character` are the DEFAULT binding
/// (`NSEvent`'s virtual key code, device-independent modifier flags, and the character `NSMenuItem`
/// would use as its `keyEquivalent`); `title` is both the label the Settings ▸ Shortcuts pane shows and
/// the stable key `Hotkeys.overrides`/`HotkeyOverrides` persists a rebinding under. `alwaysActive` marks
/// the two hotkeys AC-APP-4 keeps live even mid-recording (⌃⌥⌘R, ⌃⌥⌘P) — every other one is ignored
/// while recording.
struct Hotkey {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
    let character: String
    let title: String
    let alwaysActive: Bool
    let action: @MainActor () -> Void
}

/// Global keyboard shortcuts (SPEC §4.7, AC-APP-4): works while another app is frontmost
/// (`NSEvent.addGlobalMonitorForEvents`) and while Recorder itself is frontmost (a local monitor —
/// the global one never fires for events targeting our own app). Does not reuse `EventRecorder`'s
/// `CGEventTap`: that one only lives while a recording is in progress.
// Not `@MainActor` on the type itself (like `AppDelegate`/`ToolbarController`, see T-104's log): only
// the handful of members below that actually touch MainActor-isolated state (`RecordingController`,
// the `@MainActor` hotkey actions) are marked so — `table`/`overrides`/`currentBinding`/`rebind`/etc.
// are plain data, read directly from `AppDelegate`'s nonisolated status-menu builders and from
// `SettingsView`'s Shortcuts pane without hopping actors.
enum Hotkeys {
    static let table: [Hotkey] = [
        Hotkey(keyCode: KeyCode.r, modifiers: [.control, .option, .command], character: "r", title: "Start/Finish Recording",
               alwaysActive: true, action: toggleRecording),
        Hotkey(keyCode: KeyCode.p, modifiers: [.control, .option, .command], character: "p", title: "Pause/Resume",
               alwaysActive: true, action: togglePause),
        // T-610: like ⌃⌥⌘R/⌃⌥⌘P, allowed WHILE RECORDING — the whole point is grabbing state when
        // the UI is misbehaving mid-recording.
        Hotkey(keyCode: KeyCode.s, modifiers: [.control, .option, .command], character: "s", title: "Copy State Snapshot",
               alwaysActive: true, action: { StateSnapshot.dump() }),
        Hotkey(keyCode: KeyCode.returnKey, modifiers: [.control, .command], character: "\r", title: "New Recording",
               alwaysActive: false, action: { ToolbarController.shared.show() }),
        Hotkey(keyCode: KeyCode.three, modifiers: [.option, .command], character: "3", title: "Record Display",
               alwaysActive: false, action: { showAndSelect(.display) }),
        Hotkey(keyCode: KeyCode.four, modifiers: [.option, .command], character: "4", title: "Record Window",
               alwaysActive: false, action: { showAndSelect(.window) }),
        Hotkey(keyCode: KeyCode.five, modifiers: [.option, .command], character: "5", title: "Record Area",
               alwaysActive: false, action: { showAndSelect(.area) }),
        Hotkey(keyCode: KeyCode.z, modifiers: [.option, .command], character: "z", title: "Open Last Project",
               alwaysActive: false, action: { AppDelegate.openLastProject() }),
    ]

    // MARK: - Rebinding (T-609) — persisted overrides on top of the fixed defaults above.

    private(set) static var overrides: [String: HotkeyBinding] = HotkeyOverrides.load()

    /// Reloads `overrides` from `defaults` — the Settings ▸ Shortcuts pane doesn't need this (it only
    /// ever writes through `rebind`/`resetToDefaults`, which keep the cache in sync themselves); it
    /// exists for the `hotkeys` selftest to point at a throwaway `UserDefaults` suite.
    static func reload(from defaults: UserDefaults = .standard) {
        overrides = HotkeyOverrides.load(from: defaults)
    }

    /// The binding actually in effect for `hotkey`: its override if one was saved, else its default.
    static func currentBinding(for hotkey: Hotkey) -> HotkeyBinding {
        overrides[hotkey.title] ?? HotkeyBinding(keyCode: hotkey.keyCode, modifiers: hotkey.modifiers.rawValue, character: hotkey.character)
    }

    /// Same, looked up by `Hotkey.title` — for call sites (status-menu construction) that only have
    /// the title string, not the `Hotkey` value itself.
    static func currentBinding(titled title: String) -> HotkeyBinding {
        guard let hotkey = table.first(where: { $0.title == title }) else {
            return HotkeyBinding(keyCode: 0, modifiers: 0, character: "")
        }
        return currentBinding(for: hotkey)
    }

    /// Rebinds `hotkey` to a captured combo. Rejects it (returns `false`, nothing changes) when any
    /// OTHER hotkey's current binding already uses that exact key code + modifiers.
    @discardableResult
    static func rebind(_ hotkey: Hotkey, keyCode: UInt16, modifiers: NSEvent.ModifierFlags, character: String,
                        defaults: UserDefaults = .standard) -> Bool {
        let mods = modifiers.intersection(.deviceIndependentFlagsMask)
        let isDuplicate = table.contains { other in
            guard other.title != hotkey.title else { return false }
            let b = currentBinding(for: other)
            return b.keyCode == keyCode && b.modifiers == mods.rawValue
        }
        guard !isDuplicate else { return false }
        overrides[hotkey.title] = HotkeyBinding(keyCode: keyCode, modifiers: mods.rawValue, character: character)
        HotkeyOverrides.save(overrides, to: defaults)
        return true
    }

    static func resetToDefaults(defaults: UserDefaults = .standard) {
        overrides = [:]
        HotkeyOverrides.save(overrides, to: defaults)
    }

    @MainActor private static func showAndSelect(_ mode: RecordingSettings.Mode) {
        ToolbarController.shared.show()
        ToolbarController.shared.selectMode(mode)
    }

    @MainActor private static func toggleRecording() {
        switch RecordingController.shared.state {
        case .idle: ToolbarController.shared.show()
        case .recording, .paused: RecordingController.shared.finish()
        default: break
        }
    }

    @MainActor private static func togglePause() {
        switch RecordingController.shared.state {
        case .recording: RecordingController.shared.pause()
        case .paused: RecordingController.shared.resume()
        default: break
        }
    }

    private static var globalMonitor: Any?
    private static var localMonitor: Any?

    static func install() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            Task { @MainActor in handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let matched = match(event)
            if let matched { Task { @MainActor in fire(matched) } }
            return matched == nil ? event : nil // swallow the event once it's handled as a hotkey
        }
    }

    @MainActor private static func handle(_ event: NSEvent) {
        guard let hotkey = match(event) else { return }
        fire(hotkey)
    }

    @MainActor private static func fire(_ hotkey: Hotkey) {
        let recording = RecordingController.shared.state == .recording || RecordingController.shared.state == .paused
        guard !recording || hotkey.alwaysActive else { return } // AC-APP-4
        hotkey.action()
    }

    private static func match(_ event: NSEvent) -> Hotkey? {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return table.first { hotkey in
            let b = currentBinding(for: hotkey)
            return b.keyCode == event.keyCode && b.modifiers == mods.rawValue
        }
    }
}

/// Virtual key codes (`Carbon.HIToolbox`'s `kVK_*` constants, spelled out so this file needs no Carbon
/// import) for the keys SPEC §4.7's table names.
private enum KeyCode {
    static let r: UInt16 = 15
    static let p: UInt16 = 35
    static let s: UInt16 = 1
    static let z: UInt16 = 6
    static let returnKey: UInt16 = 36
    static let three: UInt16 = 20
    static let four: UInt16 = 21
    static let five: UInt16 = 23
}
