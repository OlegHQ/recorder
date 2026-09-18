import SwiftUI
import AppKit

/// SPEC §4.1: shown by AppDelegate in a 660×470 non-resizable window whenever `!Permissions.allGranted`.
struct OnboardingView: View {
    var onContinue: () -> Void

    @State private var screenGranted = Permissions.screen
    @State private var accessibilityGranted = Permissions.accessibility
    @State private var screenRequestedAt: Date?
    @State private var showRelaunch = false

    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)

            Text("Welcome to Recorder!")
                .font(Font(Theme.titleFont))
                .foregroundStyle(Theme.textPrimaryColor)

            Text("Before you can start recording, we need a few permissions.")
                .font(Font(Theme.bodyFont))
                .foregroundStyle(Theme.textSecondaryColor)

            VStack(spacing: 16) {
                row(title: "Screen Recording",
                    detail: "Needed to capture your screen.\nYou may need to restart the app.",
                    granted: screenGranted,
                    buttonTitle: "Allow Screen Recording") {
                    Permissions.requestScreen()
                    screenRequestedAt = Date()
                }

                row(title: "Accessibility",
                    detail: "Needed to capture mouse movement\nand shortcut keystrokes.",
                    granted: accessibilityGranted,
                    buttonTitle: "Allow Accessibility") {
                    Permissions.requestAccessibility()
                }
            }

            if showRelaunch {
                Button("Relaunch", action: relaunch)
                    .foregroundStyle(Theme.accentTextColor)
            }

            Button("Continue", action: onContinue)
                .keyboardShortcut(.defaultAction)
                .disabled(!(screenGranted && accessibilityGranted))
        }
        .padding(32)
        .frame(width: 660, height: 470)
        .background(Theme.bgWindowColor)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            screenGranted = Permissions.screen
            accessibilityGranted = Permissions.accessibility
            if let requestedAt = screenRequestedAt, !screenGranted,
               Date().timeIntervalSince(requestedAt) > 5 {
                showRelaunch = true
            }
        }
    }

    private func row(title: String, detail: String, granted: Bool, buttonTitle: String,
                      request: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Font(Theme.bodyFont))
                    .foregroundStyle(Theme.textPrimaryColor)
                Text(detail)
                    .font(Font(Theme.captionFont))
                    .foregroundStyle(Theme.textSecondaryColor)
            }
            Spacer()
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button(buttonTitle, action: request)
            }
        }
        .padding(12)
        .background(Theme.bgPanelColor)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
}
