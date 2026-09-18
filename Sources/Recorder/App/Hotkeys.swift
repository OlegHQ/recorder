import AppKit

/// One entry per global default in SPEC §4.7. `keyCode`/`modifiers` are `NSEvent`'s (virtual key code,
/// device-independent modifier flags); `title` doubles as the label a future rebinding UI (T-609) would
/// show. `alwaysActive` marks the two hotkeys AC-APP-4 keeps live even mid-recording (⌃⌥⌘R, ⌃⌥⌘P) —
/// every other one is ignored while recording.
struct Hotkey {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
    let title: String
    let alwaysActive: Bool
    let action: @MainActor () -> Void
}

/// Global keyboard shortcuts (SPEC §4.7, AC-APP-4): works while another app is frontmost
/// (`NSEvent.addGlobalMonitorForEvents`) and while Recorder itself is frontmost (a local monitor —
/// the global one never fires for events targeting our own app). Does not reuse `EventRecorder`'s
/// `CGEventTap`: that one only lives while a recording is in progress.
@MainActor enum Hotkeys {
    // ponytail: fixed bindings; rebinding UI is T-609.
    static let table: [Hotkey] = [
        Hotkey(keyCode: KeyCode.r, modifiers: [.control, .option, .command], title: "Start/Finish Recording",
               alwaysActive: true, action: toggleRecording),
        Hotkey(keyCode: KeyCode.p, modifiers: [.control, .option, .command], title: "Pause/Resume",
               alwaysActive: true, action: togglePause),
        Hotkey(keyCode: KeyCode.returnKey, modifiers: [.control, .command], title: "New Recording",
               alwaysActive: false, action: { ToolbarController.shared.show() }),
        Hotkey(keyCode: KeyCode.three, modifiers: [.option, .command], title: "Record Display",
               alwaysActive: false, action: { showAndSelect(.display) }),
        Hotkey(keyCode: KeyCode.four, modifiers: [.option, .command], title: "Record Window",
               alwaysActive: false, action: { showAndSelect(.window) }),
        Hotkey(keyCode: KeyCode.five, modifiers: [.option, .command], title: "Record Area",
               alwaysActive: false, action: { showAndSelect(.area) }),
        // No-op until T-207b wires "Open Last Project" (needs the newest-package lookup that task adds).
        Hotkey(keyCode: KeyCode.z, modifiers: [.option, .command], title: "Open Last Project",
               alwaysActive: false, action: {}),
    ]

    private static func showAndSelect(_ mode: RecordingSettings.Mode) {
        ToolbarController.shared.show()
        ToolbarController.shared.selectMode(mode)
    }

    private static func toggleRecording() {
        switch RecordingController.shared.state {
        case .idle: ToolbarController.shared.show()
        case .recording, .paused: RecordingController.shared.finish()
        default: break
        }
    }

    private static func togglePause() {
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

    private static func handle(_ event: NSEvent) {
        guard let hotkey = match(event) else { return }
        fire(hotkey)
    }

    private static func fire(_ hotkey: Hotkey) {
        let recording = RecordingController.shared.state == .recording || RecordingController.shared.state == .paused
        guard !recording || hotkey.alwaysActive else { return } // AC-APP-4
        hotkey.action()
    }

    private static func match(_ event: NSEvent) -> Hotkey? {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return table.first { $0.keyCode == event.keyCode && $0.modifiers == mods }
    }
}

/// Virtual key codes (`Carbon.HIToolbox`'s `kVK_*` constants, spelled out so this file needs no Carbon
/// import) for the keys SPEC §4.7's table names.
private enum KeyCode {
    static let r: UInt16 = 15
    static let p: UInt16 = 35
    static let z: UInt16 = 6
    static let returnKey: UInt16 = 36
    static let three: UInt16 = 20
    static let four: UInt16 = 21
    static let five: UInt16 = 23
}
