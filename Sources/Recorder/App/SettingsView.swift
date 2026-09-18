import SwiftUI
import AppKit

/// SPEC §8: minimal Settings window — General (projects folder) + Recording (fps, countdown, the
/// three toggles from §4.2), bound to `RecordingSettings.shared`. Shortcuts pane is M6.
/// One reusable native titled `NSWindow` opened by `⌘,` (AppDelegate) and the toolbar gear menu's
/// "Settings…" item (ToolbarController).
enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
        } else {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
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
