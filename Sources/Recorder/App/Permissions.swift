import ApplicationServices
import AVFoundation
import CoreGraphics
import AppKit

enum Permissions {
    // Never enumerate SCShareableContent to check permission: it can prompt, including
    // when a Settings toggle still belongs to an older ad-hoc signature.
    static var screen: Bool { CGPreflightScreenCaptureAccess() }
    static var accessibility: Bool { AXIsProcessTrusted() }
    static var allGranted: Bool { screen && accessibility }

    @MainActor private static var screenRequested = false
    @MainActor private static var accessibilityRequested = false

    // Explicit user actions only, at most once per process. Set the latch BEFORE
    // requesting, since a system consent dialog can re-enter the app's event loop.
    @MainActor static func requestScreen(granted: () -> Bool = { screen },
                                         request: () -> Bool = { CGRequestScreenCaptureAccess() }) {
        guard !granted(), !screenRequested else { return }
        screenRequested = true
        _ = request()
    }

    @MainActor static func requestAccessibility(granted: () -> Bool = { accessibility },
                                                request: () -> Bool = {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }) {
        guard !granted(), !accessibilityRequested else { return }
        accessibilityRequested = true
        _ = request()
    }

    /// Only called after the user confirms the scope in onboarding. Never reset All
    /// or another application's grants, and never edit TCC's database directly.
    static func resetAccess(run: ([String]) throws -> Void = runTCCReset) throws {
        for service in ["ScreenCapture", "Accessibility"] {
            try run(["reset", service, "sh.nexo.recorder"])
        }
    }

    private static func runTCCReset(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "Recorder.Permissions", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
        }
    }

    static func openSettings(accessibility: Bool) {
        let pane = accessibility ? "Privacy_Accessibility" : "Privacy_ScreenCapture"
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    // T-610: camera/mic TCC are their own authorization (SPEC §4.1/§4.6), read-only here for the
    // state snapshot — `CameraCapture.request(deviceID:)` is the one place that actually prompts.
    static var camera: String { describe(AVCaptureDevice.authorizationStatus(for: .video)) }
    static var mic: String { describe(AVCaptureDevice.authorizationStatus(for: .audio)) }

    private static func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }
}
