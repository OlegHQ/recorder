import ApplicationServices
import AVFoundation
import CoreGraphics
import ScreenCaptureKit
import AppKit

enum Permissions {
    // CoreGraphics can report a stale denial after a grant. All capture entry points
    // also accept a successful check through the API we actually record with.
    private static var captureAccess = false
    static var screen: Bool { CGPreflightScreenCaptureAccess() || captureAccess }
    static var accessibility: Bool { AXIsProcessTrusted() }
    static func requestScreen() { CGRequestScreenCaptureAccess() }
    static func requestAccessibility() { AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) }
    static var allGranted: Bool { screen && accessibility }

    /// Called explicitly by onboarding; enumerating content can show the macOS consent prompt.
    @MainActor static func checkScreen(probe: () async throws -> Void = {
        _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    }) async -> String? {
        do {
            try await probe()
            captureAccess = true
            return nil
        } catch {
            captureAccess = false
            return error.localizedDescription
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
