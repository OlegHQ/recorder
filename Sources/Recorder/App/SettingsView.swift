import SwiftUI
import AppKit

/// SPEC §8: minimal Settings window — General (projects folder) + Recording (fps, countdown, the
/// three toggles from §4.2) bound to `RecordingSettings.shared`, and Shortcuts (T-609) — rebind the
/// `Hotkeys.table` global hotkeys.
/// One reusable native titled `NSWindow` opened by `⌘,` (AppDelegate) and the toolbar gear menu's
/// "Settings…" item (ToolbarController).
enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
        } else {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            window = w
            w.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
    }
}

struct SettingsView: View {
    @Bindable private var settings = RecordingSettings.shared

    var body: some View {
        Form {
            Section("General") {
                HStack {
                    Text(settings.projectsFolder.path)
                        .foregroundStyle(Theme.textSecondaryColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…", action: chooseProjectsFolder)
                }
            }

            Section("Recording") {
                Picker("Frame rate", selection: $settings.fps) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Picker("Countdown", selection: $settings.countdown) {
                    Text("Off").tag(0)
                    Text("3 s").tag(3)
                    Text("5 s").tag(5)
                    Text("10 s").tag(10)
                }
                Toggle("Hide desktop icons in recorded video", isOn: $settings.hideDesktopIcons)
                Toggle("Hide Recorder dock icon while recording", isOn: $settings.hideDockIcon)
                Toggle("Highlight recorded area during recording", isOn: $settings.highlightArea)
            }

            Section("Shortcuts") {
                ShortcutsPane()
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func chooseProjectsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.projectsFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.projectsFolder = url
    }
}

// MARK: - Shortcuts pane (T-609, SPEC §8 "Shortcuts (M6) — rebind the global hotkeys (§4.7)")

/// One row per `Hotkeys.table` entry (title + its current combo, rebindable), plus "Reset to defaults".
/// `revision` is bumped after every rebind/reset so the rows re-read `Hotkeys.currentBinding` — the
/// table itself isn't `@Observable`, it's a plain persisted cache (`RecordingSettings.HotkeyOverrides`).
private struct ShortcutsPane: View {
    @State private var revision = 0

    var body: some View {
        ForEach(Hotkeys.table, id: \.title) { hotkey in
            HotkeyRow(hotkey: hotkey, revision: $revision)
        }
        Button("Reset to Defaults") {
            Hotkeys.resetToDefaults()
            revision += 1
        }
    }
}

private struct HotkeyRow: View {
    let hotkey: Hotkey
    @Binding var revision: Int
    @State private var conflict = false

    var body: some View {
        HStack {
            Text(hotkey.title)
            Spacer()
            if conflict {
                Text("Already in use").font(.caption).foregroundStyle(.red)
            }
            HotkeyRecorderField(label: Self.label(for: hotkey)) { keyCode, modifiers, character in
                if Hotkeys.rebind(hotkey, keyCode: keyCode, modifiers: modifiers, character: character) {
                    conflict = false
                    revision += 1
                } else {
                    conflict = true
                }
            }
        }
    }

    private static func label(for hotkey: Hotkey) -> String {
        let b = Hotkeys.currentBinding(for: hotkey)
        let mods = NSEvent.ModifierFlags(rawValue: b.modifiers)
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        switch b.character {
        case "\r": s += "↩"
        case "\u{8}": s += "⌫"
        default: s += b.character.uppercased()
        }
        return s
    }
}

/// A single click-to-record field (SPEC §8: "a simple recorder field per row: click, press combo, Esc
/// cancels"). SwiftUI has no key-capture primitive, so this wraps a tiny `NSButton` subclass that
/// becomes first responder on click and swallows the next key event as the new combo via a local
/// `NSEvent` monitor — the same mechanism `Hotkeys.install()` uses for the hotkeys themselves, just
/// scoped to one button's click instead of the whole app's lifetime.
private struct HotkeyRecorderField: NSViewRepresentable {
    let label: String
    let onCapture: (UInt16, NSEvent.ModifierFlags, String) -> Void

    func makeNSView(context: Context) -> HotkeyCaptureButton {
        let button = HotkeyCaptureButton()
        button.onCapture = onCapture
        return button
    }

    func updateNSView(_ button: HotkeyCaptureButton, context: Context) {
        button.idleTitle = label
        if !button.isRecording { button.title = label }
    }
}

private final class HotkeyCaptureButton: NSButton {
    var onCapture: ((UInt16, NSEvent.ModifierFlags, String) -> Void)?
    var idleTitle = "" { didSet { if !isRecording { title = idleTitle } } }
    private(set) var isRecording = false
    private var monitor: Any?

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(startRecording)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    @objc private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        title = "Press keys…"
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording else { return event }
            self.stopRecording()
            guard event.keyCode != 53 else { return nil } // Esc cancels, no capture
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            self.onCapture?(event.keyCode, mods, event.charactersIgnoringModifiers ?? "")
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        title = idleTitle
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
