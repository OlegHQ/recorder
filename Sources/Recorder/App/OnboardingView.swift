import SwiftUI
import AppKit

/// SPEC §4.1: shown by AppDelegate in a 660×470 non-resizable window whenever `!Permissions.allGranted`.
struct OnboardingView: View {
    var onContinue: () -> Void

    @State private var screenGranted = Permissions.screen
    @State private var accessibilityGranted = Permissions.accessibility
    @State private var checking = false
    @State private var checkError: String?
    @State private var requested = false

    init(onContinue: @escaping () -> Void, screenGranted: Bool = Permissions.screen,
         accessibilityGranted: Bool = Permissions.accessibility, requested: Bool = false) {
        self.onContinue = onContinue
        _screenGranted = State(initialValue: screenGranted)
        _accessibilityGranted = State(initialValue: accessibilityGranted)
        _requested = State(initialValue: requested)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recorder").font(Font(Theme.titleFont))
                    Text("Capture permissions")
                        .font(Font(Theme.captionFont))
                        .foregroundStyle(Theme.textTertiaryColor)
                }
                Spacer()
                Text("\((screenGranted ? 1 : 0) + (accessibilityGranted ? 1 : 0)) / 2 granted")
                    .font(Font(Theme.timecodeFont(11)))
                    .foregroundStyle(Theme.textSecondaryColor)
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            .background(Theme.bgPanelColor)
            Rectangle().fill(Theme.strokeColor).frame(height: 1)

            HStack(alignment: .top, spacing: 30) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Allow capture")
                        .font(Font(Theme.headingFont(30)))
                    Text("Enable Recorder in both macOS permission lists, then check access.")
                        .font(Font(Theme.bodyFont))
                        .foregroundStyle(Theme.textSecondaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Already enabled? Quit other copies of Recorder. In Settings, remove the old entry with −, then add this app again with +.")
                        .font(Font(Theme.captionFont))
                        .foregroundStyle(Theme.textSecondaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(Bundle.main.bundlePath)
                        .font(Font(Theme.captionFont))
                        .foregroundStyle(Theme.textTertiaryColor)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .help(Bundle.main.bundlePath)
                }
                .frame(width: 220, alignment: .leading)

                VStack(spacing: 22) {
                    row(index: "01", title: "Screen Recording",
                    detail: "Allows display, window and area capture. If macOS asks you to quit and reopen, do that after enabling access.",
                    granted: screenGranted,
                    buttonTitle: "Open Settings") {
                    requested = true
                    Permissions.requestScreen()
                    Permissions.openSettings(accessibility: false)
                }

                    row(index: "02", title: "Accessibility",
                    detail: "Preserves pointer movement and shortcut keystrokes in the recording.",
                    granted: accessibilityGranted,
                    buttonTitle: "Open Settings") {
                    requested = true
                    Permissions.requestAccessibility()
                    Permissions.openSettings(accessibility: true)
                }
            }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Rectangle().fill(Theme.strokeColor).frame(height: 1)
            HStack {
                Text(screenGranted && accessibilityGranted ? "Setup complete" : (checkError == nil ? "Enable access, then check again" : "Access unavailable · check Settings or relaunch"))
                    .font(Font(Theme.captionFont))
                    .foregroundStyle(Theme.textSecondaryColor)
                    .help(checkError ?? "")
                Spacer()
                if requested && !(screenGranted && accessibilityGranted) {
                    Button("Relaunch", action: relaunch)
                        .buttonStyle(TechButtonStyle(kind: .secondary))
                }
                Button(checking ? "Checking…" : "Check again", action: checkAccess)
                    .buttonStyle(TechButtonStyle(kind: .secondary))
                    .disabled(checking)
                Button("Continue", action: onContinue)
                    .buttonStyle(TechButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!(screenGranted && accessibilityGranted))
            }
            .padding(.horizontal, 24).frame(height: 62)
            .background(Theme.bgPanelColor)
        }
        .frame(width: 660, height: 470)
        .background(Theme.bgWindowColor)
        .signalWindow()
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            screenGranted = Permissions.screen
            accessibilityGranted = Permissions.accessibility
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if requested { checkAccess() }
        }
    }

    private func row(index: String, title: String, detail: String, granted: Bool, buttonTitle: String,
                      request: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TechSectionLabel(index: index, title: title)
            Text(detail)
                .font(Font(Theme.captionFont))
                .foregroundStyle(Theme.textSecondaryColor)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TechStatus(title: granted ? "Granted" : "Required",
                           color: granted ? Theme.layoutColor : Theme.warningColor)
                Spacer()
                if !granted {
                    Button(buttonTitle, action: request)
                        .buttonStyle(TechButtonStyle(kind: .secondary, compact: true))
                }
            }
        }
        .padding(14)
        .background(Theme.bgPanelColor)
        .overlay(Rectangle().stroke(Theme.strokeColor))
    }

    private func checkAccess() {
        guard !checking else { return }
        checking = true
        requested = true
        Task { @MainActor in
            checkError = await Permissions.checkScreen()
            screenGranted = Permissions.screen
            accessibilityGranted = Permissions.accessibility
            checking = false
        }
    }

    private func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error { checkError = error.localizedDescription }
                else { NSApp.terminate(nil) }
            }
        }
    }
}
