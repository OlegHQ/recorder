import SwiftUI
import AppKit

/// SPEC §4.1: shown by AppDelegate in a 660×470 non-resizable window whenever `!Permissions.allGranted`.
struct OnboardingView: View {
    var onContinue: () -> Void

    @State private var screenGranted = Permissions.screen
    @State private var accessibilityGranted = Permissions.accessibility
    @State private var checkError: String?

    init(onContinue: @escaping () -> Void, screenGranted: Bool = Permissions.screen,
         accessibilityGranted: Bool = Permissions.accessibility) {
        self.onContinue = onContinue
        _screenGranted = State(initialValue: screenGranted)
        _accessibilityGranted = State(initialValue: accessibilityGranted)
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
                    Text("Already enabled after an update? The grant may belong to the old build. Repair access below, then enable this copy and relaunch.")
                        .font(Font(Theme.captionFont))
                        .foregroundStyle(Theme.textSecondaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(Bundle.main.bundlePath)
                        .font(Font(Theme.captionFont))
                        .foregroundStyle(Theme.textTertiaryColor)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .help(Bundle.main.bundlePath)
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")")
                        .font(Font(Theme.captionFont))
                        .foregroundStyle(Theme.textTertiaryColor)
                    Button("Repair access…", action: repairAccess)
                        .buttonStyle(TechButtonStyle(kind: .secondary, compact: true))
                }
                .frame(width: 220, alignment: .leading)

                VStack(spacing: 22) {
                    row(index: "01", title: "Screen Recording",
                    detail: "Allows display, window and area capture. If macOS asks you to quit and reopen, do that after enabling access.",
                    granted: screenGranted,
                    buttonTitle: "Allow…") {
                    Permissions.requestScreen()
                    Permissions.openSettings(accessibility: false)
                }

                    row(index: "02", title: "Accessibility",
                    detail: "Preserves pointer movement and shortcut keystrokes in the recording.",
                    granted: accessibilityGranted,
                    buttonTitle: "Allow…") {
                    Permissions.requestAccessibility()
                    Permissions.openSettings(accessibility: true)
                }
            }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Rectangle().fill(Theme.strokeColor).frame(height: 1)
            HStack {
                Text(screenGranted && accessibilityGranted ? "Setup complete" : "Enable access, then relaunch")
                    .font(Font(Theme.captionFont))
                    .foregroundStyle(Theme.textSecondaryColor)
                    .help(checkError ?? "")
                Spacer()
                if !(screenGranted && accessibilityGranted) {
                    Button("Relaunch", action: relaunch)
                        .buttonStyle(TechButtonStyle(kind: .secondary))
                }
                Button("Check again", action: checkAccess)
                    .buttonStyle(TechButtonStyle(kind: .secondary))
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
            checkAccess()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkAccess()
        }
        .alert("Permission recovery", isPresented: Binding(get: { checkError != nil }, set: { if !$0 { checkError = nil } })) {
            Button("OK", role: .cancel) { checkError = nil }
        } message: { Text(checkError ?? "") }
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
        // This is also called on activation and by the timer. It MUST NOT prompt.
        screenGranted = Permissions.screen
        accessibilityGranted = Permissions.accessibility
    }

    private func repairAccess() {
        let bundle = Bundle.main.bundleURL
        if bundle.path.contains("/AppTranslocation/") ||
            (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true {
            checkError = "Install Recorder in Applications first, eject the DMG, and launch that copy before repairing access. This copy is running from a temporary or read-only location:\n\(bundle.path)"
            return
        }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "sh.nexo.recorder")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard others.isEmpty else {
            checkError = "Quit the other running copies of Recorder before repairing access:\n" +
                others.map { "\($0.bundleURL?.path ?? "Unknown location") (PID \($0.processIdentifier))" }.joined(separator: "\n")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Reset Recorder’s old permission grants?"
        alert.informativeText = "This removes only Recorder’s Screen Recording and Accessibility grants, including grants for older copies. Other apps and your recordings are untouched. Recorder will quit and reopen; then use Allow to grant access to this version.\n\n\(Bundle.main.bundlePath)\n\nAd-hoc releases may need this again after an update."
        alert.addButton(withTitle: "Reset and Relaunch")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try Permissions.resetAccess()
            relaunch()
        } catch {
            checkAccess()
            checkError = "Could not finish resetting access: \(error.localizedDescription)\nRemove Recorder from both permission lists in System Settings, add this app again, and relaunch."
        }
    }

    private func relaunch() {
        // A new process must not overlap the old permission-denied process. Pass
        // the path as an argument, never interpolate it into shell source.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "attempt=0; while /bin/kill -0 \"$1\" 2>/dev/null; do attempt=$((attempt + 1)); [ \"$attempt\" -lt 100 ] || exit 1; /bin/sleep 0.1; done; exec /usr/bin/open -n \"$2\"", "Recorder relaunch",
                             String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            checkError = "Could not relaunch Recorder: \(error.localizedDescription)"
        }
    }
}
