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
        VStack(spacing: 0) {
            Rectangle().fill(Theme.accentColor).frame(height: 2)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recorder").font(Font(Theme.titleFont))
                    Text("Capture permissions")
                        .font(Font(Theme.captionFont))
                        .foregroundStyle(Theme.textTertiaryColor)
                }
                Spacer()
                Text(screenGranted && accessibilityGranted ? "02 granted" : "02 required")
                    .font(Font(Theme.timecodeFont(11)))
                    .foregroundStyle(Theme.textSecondaryColor)
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            .background(Theme.bgPanelColor)
            Rectangle().fill(Theme.strokeColor).frame(height: 1)

            HStack(alignment: .top, spacing: 30) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Ready your capture workspace")
                        .font(Font(Theme.headingFont(30)))
                    Text("Recorder needs two macOS permissions before it can capture the screen and preserve pointer or shortcut activity.")
                        .font(Font(Theme.bodyFont))
                        .foregroundStyle(Theme.textSecondaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 220, alignment: .leading)

                VStack(spacing: 22) {
                    row(index: "01", title: "Screen Recording",
                    detail: "Captures the selected display, window or area. macOS may require an app relaunch after approval.",
                    granted: screenGranted,
                    buttonTitle: "Allow Screen Recording") {
                    Permissions.requestScreen()
                    screenRequestedAt = Date()
                }

                    row(index: "02", title: "Accessibility",
                    detail: "Preserves pointer movement and shortcut keystrokes in the recording.",
                    granted: accessibilityGranted,
                    buttonTitle: "Allow Accessibility") {
                    Permissions.requestAccessibility()
                }
            }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Rectangle().fill(Theme.strokeColor).frame(height: 1)
            HStack {
                Text(screenGranted && accessibilityGranted ? "Setup complete" : "Complete both permissions to continue")
                    .font(Font(Theme.captionFont))
                    .foregroundStyle(Theme.textSecondaryColor)
                Spacer()
                if showRelaunch {
                    Button("Relaunch", action: relaunch)
                        .buttonStyle(TechButtonStyle(kind: .secondary))
                }
                Button("Continue", action: onContinue)
                    .buttonStyle(TechButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!(screenGranted && accessibilityGranted))
            }
            .padding(.horizontal, 24).frame(height: 62)
            .background(Theme.bgPanelColor)
        }
        .frame(width: 660, height: 470)
        .background { ZStack { Theme.bgWindowColor; TechGridBackground(step: 40).opacity(0.3) } }
        .signalWindow()
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            screenGranted = Permissions.screen
            accessibilityGranted = Permissions.accessibility
            if let requestedAt = screenRequestedAt, !screenGranted,
               Date().timeIntervalSince(requestedAt) > 5 {
                showRelaunch = true
            }
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

    private func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
}
